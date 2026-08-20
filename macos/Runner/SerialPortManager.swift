import Foundation
import Darwin
import FlutterMacOS

final class SerialPortManager: NSObject, FlutterStreamHandler {
    private var fd: Int32 = -1
    private var eventSink: FlutterEventSink?
    private let queue = DispatchQueue(label: "com.btbuddy.serial.queue", qos: .userInitiated)
    private let commandLock = NSLock()
    private var connectedPath = ""
    private var isRunningReader = false

    // Synchronized command-response mechanism
    private let responseLock = NSLock()
    private var isWaitingForResponse = false
    private var pendingResponseData = Data()
    private var responseSemaphore: DispatchSemaphore?
    private var customStopCheck: ((String) -> Bool)?

    // Telemetry
    private var txBytes: Int64 = 0
    private var rxBytes: Int64 = 0
    private var txPackets: Int64 = 0
    private var rxPackets: Int64 = 0

    func connect(path: String, baud: Int) throws {
        disconnect()

        // 1. Open device (use nonblock during open to avoid hanging on carrier detect)
        let handle = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if handle < 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open \(path): \(String(cString: strerror(errno)))"]
            )
        }

        // 2. Request exclusive access
        _ = ioctl(handle, TIOCEXCL)

        // 3. Configure termios
        var options = termios()
        if tcgetattr(handle, &options) != 0 {
            close(handle)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "tcgetattr failed on \(path)"]
            )
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        options.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CRTSCTS)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | ICRNL | INLCR | IGNCR)
        options.c_oflag &= ~tcflag_t(OPOST | ONLCR | OCRNL)
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)

        withUnsafeMutableBytes(of: &options.c_cc) { controlCharacters in
            controlCharacters[Int(VMIN)] = 0
            controlCharacters[Int(VTIME)] = 1 // 100ms timeout per read
        }

        let speed = speedConstant(baud)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        if tcsetattr(handle, TCSANOW, &options) != 0 {
            close(handle)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "tcsetattr failed on \(path)"]
            )
        }

        // 4. Assert DTR and RTS control lines for modem readiness
        var modemStatus: Int32 = 0
        if ioctl(handle, TIOCMGET, &modemStatus) == 0 {
            modemStatus |= Int32(TIOCM_DTR | TIOCM_RTS)
            _ = ioctl(handle, TIOCMSET, &modemStatus)
        }

        // 5. Clear O_NONBLOCK so reads block with termios VTIME/VMIN
        let currentFlags = fcntl(handle, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(handle, F_SETFL, currentFlags & ~O_NONBLOCK)
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

        // Send initial wake-up AT probe
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            _ = try? self?.command("AT", timeout: 1.5)
        }
    }

    func disconnect() {
        queue.sync {
            isRunningReader = false
            if fd >= 0 {
                _ = ioctl(fd, TIOCNXCL)
                close(fd)
                fd = -1
            }
        }

        responseLock.lock()
        if isWaitingForResponse {
            isWaitingForResponse = false
            responseSemaphore?.signal()
        }
        responseLock.unlock()

        if !connectedPath.isEmpty {
            let oldPath = connectedPath
            connectedPath = ""
            DispatchQueue.main.async {
                self.eventSink?(["type": "disconnected", "data": oldPath])
            }
        }
    }

    func command(_ commandStr: String, timeout: TimeInterval = 4.0, stopCondition: ((String) -> Bool)? = nil) throws -> String {
        commandLock.lock()
        defer { commandLock.unlock() }

        guard fd >= 0 else {
            throw NSError(
                domain: "BTBuddy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Serial device is not connected"]
            )
        }

        let sema = DispatchSemaphore(value: 0)
        responseLock.lock()
        isWaitingForResponse = true
        pendingResponseData = Data()
        responseSemaphore = sema
        customStopCheck = stopCondition
        responseLock.unlock()

        let normalized = commandStr.hasSuffix("\r") ? commandStr : commandStr + "\r"
        let bytes = Array(normalized.utf8)

        let written = bytes.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress, bytes.count)
        }

        if written < 0 {
            responseLock.lock()
            isWaitingForResponse = false
            responseLock.unlock()
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Serial write failed: \(String(cString: strerror(errno)))"]
            )
        }

        txBytes += Int64(written)
        txPackets += 1

        DispatchQueue.main.async {
            self.eventSink?([
                "type": "tx",
                "data": commandStr,
                "txBytes": self.txBytes,
                "txPackets": self.txPackets
            ])
        }

        // Wait for response or timeout
        let result = sema.wait(timeout: .now() + timeout)

        responseLock.lock()
        isWaitingForResponse = false
        customStopCheck = nil
        let responseData = pendingResponseData
        responseLock.unlock()

        let text = String(data: responseData, encoding: .utf8) ??
                   String(data: responseData, encoding: .ascii) ?? ""

        if result == .timedOut && text.isEmpty {
            // Check if still connected
            if fd < 0 {
                throw NSError(domain: "BTBuddy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Connection lost"])
            }
            return ""
        }

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

    func sendUssd(code: String) throws -> String {
        let sanitized = code.replacingOccurrences(of: "\"", with: "")
        let cmd = "AT+CUSD=1,\"\(sanitized)\",15"
        return try command(cmd, timeout: 8.0) { text in
            text.contains("+CUSD:") || text.contains("\r\nOK\r\n") || text.contains("\r\nERROR\r\n")
        }
    }

    func cancelUssd() throws -> String {
        return try command("AT+CUSD=2", timeout: 2.5)
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
        _ = try? executeDirectCommand("AT+CMGF=1\r", timeout: 2.0)
        usleep(100_000)

        // Initiate SMS prompt
        let promptCmd = "AT+CMGS=\"\(number)\"\r"
        let promptResp = try executeDirectCommand(promptCmd, timeout: 3.5) { text in
            text.contains(">") || text.contains("ERROR")
        }

        DispatchQueue.main.async {
            self.eventSink?(["type": "tx", "data": "AT+CMGS=\"\(number)\""])
        }

        usleep(150_000)

        // Write message body + Ctrl+Z
        let bodyPayload = message + "\u{001A}"
        let bodyResp = try executeDirectCommand(bodyPayload, timeout: 10.0) { text in
            text.contains("+CMGS:") || text.contains("OK\r\n") || text.contains("ERROR\r\n")
        }

        DispatchQueue.main.async {
            self.eventSink?(["type": "tx", "data": "\(message) <Ctrl-Z>"])
            self.eventSink?(["type": "rx", "data": bodyResp.isEmpty ? promptResp : bodyResp])
        }

        return bodyResp.isEmpty ? promptResp : bodyResp
    }

    private func executeDirectCommand(_ rawCommand: String, timeout: TimeInterval, stopCondition: ((String) -> Bool)? = nil) throws -> String {
        let sema = DispatchSemaphore(value: 0)
        responseLock.lock()
        isWaitingForResponse = true
        pendingResponseData = Data()
        responseSemaphore = sema
        customStopCheck = stopCondition
        responseLock.unlock()

        let bytes = Array(rawCommand.utf8)
        let written = bytes.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress, bytes.count)
        }

        if written < 0 {
            responseLock.lock()
            isWaitingForResponse = false
            responseLock.unlock()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Serial write error"])
        }

        txBytes += Int64(written)
        txPackets += 1

        _ = sema.wait(timeout: .now() + timeout)

        responseLock.lock()
        isWaitingForResponse = false
        customStopCheck = nil
        let responseData = pendingResponseData
        responseLock.unlock()

        return String(data: responseData, encoding: .utf8) ?? ""
    }

    // -------------------------------------------------------------
    // DEDICATED SINGLE READER THREAD
    // -------------------------------------------------------------
    private func startReader() {
        isRunningReader = true
        queue.async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)

            while self.isRunningReader && self.fd >= 0 {
                let count = Darwin.read(self.fd, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(buffer[0..<count])
                    self.rxBytes += Int64(count)
                    self.rxPackets += 1

                    self.responseLock.lock()
                    if self.isWaitingForResponse {
                        self.pendingResponseData.append(chunk)
                        let currentText = String(data: self.pendingResponseData, encoding: .utf8) ??
                                          String(data: self.pendingResponseData, encoding: .ascii) ?? ""

                        var finished = false
                        if let customCheck = self.customStopCheck {
                            finished = customCheck(currentText)
                        } else {
                            finished = currentText.contains("\r\nOK\r\n") ||
                                       currentText.contains("\r\nERROR\r\n") ||
                                       currentText.hasSuffix("OK\r\n") ||
                                       currentText.hasSuffix("ERROR\r\n") ||
                                       currentText.contains("+CME ERROR:") ||
                                       currentText.contains("+CMS ERROR:") ||
                                       currentText.contains("\r\nBUSY\r\n") ||
                                       currentText.contains("\r\nNO CARRIER\r\n") ||
                                       currentText.contains("\r\nNO ANSWER\r\n")
                        }

                        if finished {
                            self.isWaitingForResponse = false
                            self.responseSemaphore?.signal()
                        }
                    } else {
                        // Asynchronous incoming data stream
                        if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                            DispatchQueue.main.async {
                                self.eventSink?([
                                    "type": "rx_async",
                                    "data": text,
                                    "rxBytes": self.rxBytes,
                                    "rxPackets": self.rxPackets
                                ])
                            }
                        }
                    }
                    self.responseLock.unlock()

                    // Parse URCs
                    if let text = String(data: chunk, encoding: .utf8) {
                        self.processUnsolicitedCodes(in: text)
                    }
                } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    if self.isRunningReader {
                        DispatchQueue.main.async {
                            self.eventSink?(["type": "error", "data": "Serial connection lost (read failed)"])
                        }
                    }
                    break
                }
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
                let components = trimmed.replacingOccurrences(of: "+CLIP:", with: "").trimmingCharacters(in: .whitespaces)
                let number = components.components(separatedBy: ",").first?.replacingOccurrences(of: "\"", with: "") ?? ""
                DispatchQueue.main.async {
                    self.eventSink?(["type": "incoming_clip", "data": number, "raw": trimmed])
                }
            } else if trimmed.hasPrefix("+CMTI:") {
                let components = trimmed.replacingOccurrences(of: "+CMTI:", with: "").trimmingCharacters(in: .whitespaces)
                let parts = components.components(separatedBy: ",")
                let index = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "1"
                DispatchQueue.main.async {
                    self.eventSink?(["type": "incoming_sms", "data": index, "raw": trimmed])
                }
            } else if trimmed.hasPrefix("+CUSD:") {
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
        case 230400: return speed_t(B230400)
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

