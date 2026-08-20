import Foundation
import Darwin
import FlutterMacOS

final class SerialPortManager: NSObject, FlutterStreamHandler {
    private var fd: Int32 = -1
    private var eventSink: FlutterEventSink?
    private let queue = DispatchQueue(label: "com.btbuddy.serial")
    private let commandLock = NSLock()
    private var connectedPath = ""

    // Telemetry
    private var txBytes: Int64 = 0
    private var rxBytes: Int64 = 0
    private var txPackets: Int64 = 0
    private var rxPackets: Int64 = 0

    func connect(path: String, baud: Int) throws {
        disconnect()

        let handle = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if handle < 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }

        var options = termios()
        if tcgetattr(handle, &options) != 0 {
            close(handle)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "tcgetattr failed"]
            )
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        withUnsafeMutableBytes(of: &options.c_cc) { controlCharacters in
            controlCharacters[Int(VMIN)] = 0
            controlCharacters[Int(VTIME)] = 0
        }

        let speed = speedConstant(baud)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        if tcsetattr(handle, TCSANOW, &options) != 0 {
            close(handle)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "tcsetattr failed"]
            )
        }

        fd = handle
        connectedPath = path
        txBytes = 0
        rxBytes = 0
        txPackets = 0
        rxPackets = 0

        DispatchQueue.main.async {
            self.eventSink?(["type": "connected", "data": path])
        }

        startReader()
    }

    func disconnect() {
        queue.sync {
            if fd >= 0 {
                close(fd)
                fd = -1
            }
        }
        if !connectedPath.isEmpty {
            DispatchQueue.main.async {
                self.eventSink?(["type": "disconnected", "data": self.connectedPath])
            }
        }
        connectedPath = ""
    }

    func command(_ command: String, timeout: TimeInterval = 3.5) throws -> String {
        commandLock.lock()
        defer { commandLock.unlock() }

        guard fd >= 0 else {
            throw NSError(
                domain: "BTBuddy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Serial device is not connected"]
            )
        }

        let normalized = command.hasSuffix("\r") ? command : command + "\r"
        let bytes = Array(normalized.utf8)

        let written = bytes.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress, bytes.count)
        }

        if written < 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Serial write failed"]
            )
        }

        txBytes += Int64(written)
        txPackets += 1

        DispatchQueue.main.async {
            self.eventSink?([
                "type": "tx",
                "data": command,
                "txBytes": self.txBytes,
                "txPackets": self.txPackets
            ])
        }

        return try readResponse(timeout: timeout)
    }

    func sendUssd(code: String) throws -> String {
        // AT+CUSD=1,"<code_or_reply>",15
        let sanitized = code.replacingOccurrences(of: "\"", with: "")
        let cmd = "AT+CUSD=1,\"\(sanitized)\",15"
        return try command(cmd, timeout: 6.0)
    }

    func cancelUssd() throws -> String {
        return try command("AT+CUSD=2", timeout: 2.0)
    }

    func sendSms(number: String, message: String) throws -> String {
        commandLock.lock()
        defer { commandLock.unlock() }

        guard fd >= 0 else {
            throw NSError(
                domain: "BTBuddy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Serial device is not connected"]
            )
        }

        // Set SMS text mode
        let modeCmd = "AT+CMGF=1\r"
        let modeBytes = Array(modeCmd.utf8)
        _ = modeBytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, modeBytes.count) }
        usleep(150_000)

        // Initiate SMS to destination number
        let promptCmd = "AT+CMGS=\"\(number)\"\r"
        let promptBytes = Array(promptCmd.utf8)
        let w1 = promptBytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, promptBytes.count) }
        if w1 < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Write failed"])
        }

        txBytes += Int64(w1)
        txPackets += 1

        DispatchQueue.main.async {
            self.eventSink?(["type": "tx", "data": "AT+CMGS=\"\(number)\""])
        }
        usleep(350_000)

        // Write message body + Ctrl+Z (0x1A)
        let bodyPayload = message + "\u{001A}"
        let bodyBytes = Array(bodyPayload.utf8)
        let w2 = bodyBytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bodyBytes.count) }
        if w2 < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Write message failed"])
        }

        txBytes += Int64(w2)
        txPackets += 1

        DispatchQueue.main.async {
            self.eventSink?(["type": "tx", "data": "\(message) <Ctrl-Z>"])
        }

        return try readResponse(timeout: 8.0)
    }

    private func readResponse(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                rxBytes += Int64(count)
                rxPackets += 1
                output.append(contentsOf: buffer[0..<count])
                if let text = String(data: output, encoding: .utf8) {
                    processUnsolicitedCodes(in: text)
                    if text.contains("\r\nOK\r\n") ||
                       text.contains("\r\nERROR\r\n") ||
                       text.hasSuffix("OK\r\n") ||
                       text.hasSuffix("ERROR\r\n") ||
                       text.contains("+CME ERROR:") ||
                       text.contains("+CMS ERROR:") {
                        DispatchQueue.main.async {
                            self.eventSink?([
                                "type": "rx",
                                "data": text,
                                "rxBytes": self.rxBytes,
                                "rxPackets": self.rxPackets
                            ])
                        }
                        return text
                    }
                }
            } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "Serial read failed"]
                )
            }
            usleep(20_000)
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        if !text.isEmpty {
            processUnsolicitedCodes(in: text)
            DispatchQueue.main.async {
                self.eventSink?([
                    "type": "rx",
                    "data": text,
                    "rxBytes": self.rxBytes,
                    "rxPackets": self.rxPackets
                ])
            }
        }
        return text
    }

    private func startReader() {
        queue.async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                if self.fd < 0 { break }

                let count = Darwin.read(self.fd, &buffer, buffer.count)
                if count > 0 {
                    self.rxBytes += Int64(count)
                    self.rxPackets += 1
                    let data = Data(buffer[0..<count])
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if !text.isEmpty {
                        self.processUnsolicitedCodes(in: text)
                        DispatchQueue.main.async {
                            self.eventSink?([
                                "type": "rx_async",
                                "data": text,
                                "rxBytes": self.rxBytes,
                                "rxPackets": self.rxPackets
                            ])
                        }
                    }
                } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    DispatchQueue.main.async {
                        self.eventSink?(["type": "error", "data": "Serial read error"])
                    }
                    break
                }

                usleep(30_000)
            }
        }
    }

    private func processUnsolicitedCodes(in raw: String) {
        let lines = raw.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed == "RING" {
                DispatchQueue.main.async {
                    self.eventSink?(["type": "incoming_call", "data": "RING"])
                }
            } else if trimmed.hasPrefix("+CLIP:") {
                // Caller ID: +CLIP: "123456789",145,...
                let components = trimmed.replacingOccurrences(of: "+CLIP:", with: "").trimmingCharacters(in: .whitespaces)
                let number = components.components(separatedBy: ",").first?.replacingOccurrences(of: "\"", with: "") ?? ""
                DispatchQueue.main.async {
                    self.eventSink?(["type": "incoming_clip", "data": number, "raw": trimmed])
                }
            } else if trimmed.hasPrefix("+CMTI:") {
                // SMS notification: +CMTI: "SM",1
                let components = trimmed.replacingOccurrences(of: "+CMTI:", with: "").trimmingCharacters(in: .whitespaces)
                let parts = components.components(separatedBy: ",")
                let index = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "1"
                DispatchQueue.main.async {
                    self.eventSink?(["type": "incoming_sms", "data": index, "raw": trimmed])
                }
            } else if trimmed.hasPrefix("+CUSD:") {
                // USSD result: +CUSD: <m>,"<str>",<dcs>
                DispatchQueue.main.async {
                    self.eventSink?(["type": "ussd_event", "data": trimmed])
                }
            }
        }
    }

    private func speedConstant(_ baud: Int) -> speed_t {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        default: return speed_t(B115200)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
