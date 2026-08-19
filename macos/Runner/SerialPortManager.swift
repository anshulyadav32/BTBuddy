import Foundation
import Darwin
import FlutterMacOS

final class SerialPortManager: NSObject, FlutterStreamHandler {
    private var fd: Int32 = -1
    private var eventSink: FlutterEventSink?
    private let queue = DispatchQueue(label: "com.btbuddy.serial")
    private var connectedPath = ""

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
        eventSink?(["type": "connected", "data": path])

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
            eventSink?(["type": "disconnected", "data": connectedPath])
        }
        connectedPath = ""
    }

    func command(_ command: String) throws -> String {
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

        eventSink?(["type": "tx", "data": command])

        return try readResponse(timeout: 3.0)
    }

    private func readResponse(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer[0..<count])
                if let text = String(data: output, encoding: .utf8) {
                    if text.contains("\r\nOK\r\n") ||
                       text.contains("\r\nERROR\r\n") ||
                       text.hasSuffix("OK\r\n") ||
                       text.hasSuffix("ERROR\r\n") {
                        eventSink?(["type": "rx", "data": text])
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
            eventSink?(["type": "rx", "data": text])
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
                    let data = Data(buffer[0..<count])
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if !text.isEmpty {
                        DispatchQueue.main.async {
                            self.eventSink?(["type": "rx_async", "data": text])
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
