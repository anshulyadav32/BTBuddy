import Cocoa
import FlutterMacOS
import IOKit
import IOKit.usb
import Foundation

@main
class AppDelegate: FlutterAppDelegate {
    private let serial = SerialPortManager()
    private var channelsConfigured = false

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)
    }

    func configureSerialChannels(for controller: FlutterViewController) {
        guard !channelsConfigured else { return }
        channelsConfigured = true

        let method = FlutterMethodChannel(
            name: "btbuddy/serial",
            binaryMessenger: controller.engine.binaryMessenger
        )

        let events = FlutterEventChannel(
            name: "btbuddy/serial_events",
            binaryMessenger: controller.engine.binaryMessenger
        )

        events.setStreamHandler(serial)

        method.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "NO_SELF", message: "Controller unavailable", details: nil))
                return
            }

            switch call.method {
            case "listUsbDevices":
                result(USBDeviceManager.listUSBSerialDevices())
            case "connect":
                guard let args = call.arguments as? [String: Any],
                      let path = args["path"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil))
                    return
                }
                let baud = args["baud"] as? Int ?? 115200
                do {
                    try self.serial.connect(path: path, baud: baud)
                    result(true)
                } catch {
                    result(FlutterError(code: "SERIAL_CONNECT", message: error.localizedDescription, details: nil))
                }
            case "disconnect":
                self.serial.disconnect()
                result(true)
            case "command":
                guard let args = call.arguments as? [String: Any],
                      let command = args["command"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing command", details: nil))
                    return
                }
                do {
                    let response = try self.serial.command(command)
                    result(response)
                } catch {
                    result(FlutterError(code: "SERIAL_COMMAND", message: error.localizedDescription, details: nil))
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
