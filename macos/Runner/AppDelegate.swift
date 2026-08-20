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
        if let icon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
        }
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

            case "listBluetoothDevices":
                result(USBDeviceManager.listBluetoothDevices())

            case "connectBluetoothDevice":
                guard let args = call.arguments as? [String: Any],
                      let address = args["address"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing Bluetooth address", details: nil))
                    return
                }
                let success = USBDeviceManager.connectBluetoothDevice(address: address)
                result(success)

            case "disconnectBluetoothDevice":
                guard let args = call.arguments as? [String: Any],
                      let address = args["address"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing Bluetooth address", details: nil))
                    return
                }
                let success = USBDeviceManager.disconnectBluetoothDevice(address: address)
                result(success)

            case "ejectBluetoothDevice":
                guard let args = call.arguments as? [String: Any],
                      let address = args["address"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing Bluetooth address", details: nil))
                    return
                }
                let success = USBDeviceManager.ejectBluetoothDevice(address: address)
                result(success)

            case "showNativeNotification":
                guard let args = call.arguments as? [String: Any],
                      let title = args["title"] as? String,
                      let body = args["body"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing notification title or body", details: nil))
                    return
                }
                USBDeviceManager.showNativeNotification(title: title, body: body)
                result(true)

            case "connect":
                guard let args = call.arguments as? [String: Any],
                      let path = args["path"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil))
                    return
                }
                let baud = args["baud"] as? Int ?? 115200
                if path.hasPrefix("bt://") {
                    let address = path.replacingOccurrences(of: "bt://", with: "")
                    let success = USBDeviceManager.connectBluetoothDevice(address: address)
                    if success {
                        result(true)
                    } else {
                        result(FlutterError(code: "BT_CONNECT", message: "Could not open connection to Bluetooth device \(address)", details: nil))
                    }
                    return
                }
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

            case "sendSms":
                guard let args = call.arguments as? [String: Any],
                      let number = args["number"] as? String,
                      let message = args["message"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing number or message", details: nil))
                    return
                }
                do {
                    let response = try self.serial.sendSms(number: number, message: message)
                    result(response)
                } catch {
                    result(FlutterError(code: "SERIAL_SMS", message: error.localizedDescription, details: nil))
                }

            case "sendUssd":
                guard let args = call.arguments as? [String: Any],
                      let code = args["code"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing USSD code", details: nil))
                    return
                }
                do {
                    let response = try self.serial.sendUssd(code: code)
                    result(response)
                } catch {
                    result(FlutterError(code: "SERIAL_USSD", message: error.localizedDescription, details: nil))
                }

            case "cancelUssd":
                do {
                    let response = try self.serial.cancelUssd()
                    result(response)
                } catch {
                    result(FlutterError(code: "SERIAL_USSD_CANCEL", message: error.localizedDescription, details: nil))
                }

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
