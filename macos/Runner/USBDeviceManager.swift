import Foundation
import IOKit
import IOKit.usb
import IOKit.serial
import IOBluetooth
import UserNotifications

enum USBDeviceManager {
    static func listUSBSerialDevices() -> [[String: Any]] {
        var result: [[String: Any]] = []
        var seenPaths = Set<String>()
        let btDevices = fetchBluetoothDeviceInfo()

        // 1. Scan IOKit IOSerialBSDClient devices
        let matching = IOServiceMatching("IOSerialBSDClient")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)

        if kr == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let p = props?.takeRetainedValue() as? [String: Any] else {
                    continue
                }

                let cuPath = p[kIOCalloutDeviceKey] as? String ?? ""
                let ttyPath = p[kIOTTYDeviceKey] as? String ?? ""
                let path = !cuPath.isEmpty ? cuPath : ttyPath
                guard !path.isEmpty else { continue }

                let lower = path.lowercased()
                if lower.contains("debug-console") || lower.contains("wlan-debug") {
                    continue
                }

                var isBluetooth = false
                var isUSB = false
                let rawBaseName = URL(fileURLWithPath: path).lastPathComponent
                    .replacingOccurrences(of: "cu.", with: "")
                    .replacingOccurrences(of: "tty.", with: "")
                var deviceName = rawBaseName
                var manufacturer = ""
                var model = ""
                var vendorId = 0
                var productId = 0
                var btAddress = ""
                var btConnected = false
                var btPaired = false

                // Traverse parent entries in IORegistry to find attached hardware
                var parent: io_registry_entry_t = 0
                var current = service
                IOObjectRetain(current)

                while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
                    var parentProps: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(parent, &parentProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let pp = parentProps?.takeRetainedValue() as? [String: Any] {

                        var className = [CChar](repeating: 0, count: 128)
                        IOObjectGetClass(parent, &className)
                        let cls = String(cString: className)

                        if cls.contains("Bluetooth") || pp["Bluetooth Device Name"] != nil {
                            isBluetooth = true
                            if let bName = pp["Bluetooth Device Name"] as? String, !bName.isEmpty {
                                deviceName = bName
                            }
                        }

                        if cls.contains("USB") || pp["idVendor"] != nil || pp["USB Vendor Name"] != nil || pp["USB Product Name"] != nil {
                            isUSB = true
                            if let vName = pp["USB Vendor Name"] as? String, !vName.isEmpty, manufacturer.isEmpty {
                                manufacturer = vName
                            }
                            if let pName = pp["USB Product Name"] as? String, !pName.isEmpty, model.isEmpty {
                                model = pName
                                deviceName = pName
                            }
                            if let vId = pp["idVendor"] as? Int, vendorId == 0 {
                                vendorId = vId
                            }
                            if let pId = pp["idProduct"] as? Int, productId == 0 {
                                productId = pId
                            }
                        }
                    }
                    IOObjectRelease(current)
                    current = parent
                }
                IOObjectRelease(current)

                // Match with Bluetooth devices known to macOS
                for (btName, status) in btDevices {
                    let sanitizedBtName = btName.replacingOccurrences(of: " ", with: "").lowercased()
                    let sanitizedPath = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                    if sanitizedPath.contains(sanitizedBtName) ||
                       sanitizedBtName.contains(sanitizedPath) ||
                       lower.contains(btName.lowercased()) {
                        isBluetooth = true
                        isUSB = false
                        btConnected = status.connected
                        btPaired = status.paired
                        deviceName = status.realName
                        btAddress = status.address
                        manufacturer = "Bluetooth (" + (status.isPhone ? "Mobile Phone" : "Endpoint") + ")"
                        break
                    }
                }

                if lower.contains("bluetooth-incoming") {
                    isBluetooth = true
                    isUSB = false
                    deviceName = "Bluetooth Incoming Port"
                    manufacturer = "macOS Bluetooth Subsystem"
                }

                if isBluetooth {
                    if manufacturer.isEmpty { manufacturer = "Bluetooth Serial Device" }
                } else if isUSB {
                    if manufacturer.isEmpty { manufacturer = "USB Serial Device" }
                    if deviceName == rawBaseName && lower.contains("usbmodem") {
                        deviceName = "USB Cellular / Modem"
                    }
                } else {
                    if lower.contains("usbmodem") || lower.contains("usbserial") {
                        isUSB = true
                        manufacturer = "USB Serial Device"
                        if deviceName == rawBaseName && lower.contains("usbmodem") {
                            deviceName = "USB Cellular / Modem"
                        }
                    } else {
                        manufacturer = "Serial Device"
                    }
                }

                seenPaths.insert(path)
                result.append([
                    "name": deviceName,
                    "manufacturer": manufacturer,
                    "model": model,
                    "path": path,
                    "vendorId": vendorId,
                    "productId": productId,
                    "usb": !isBluetooth,
                    "btConnected": btConnected,
                    "btPaired": btPaired,
                    "btAddress": btAddress
                ])
            }
            IOObjectRelease(iterator)
        }

        // 2. Scan /dev/ for any additional serial endpoints
        let devPaths = serialDevicePathsFromFs()
        for path in devPaths {
            if seenPaths.contains(path) { continue }
            let lower = path.lowercased()
            if lower.contains("debug-console") || lower.contains("wlan-debug") { continue }

            let rawName = URL(fileURLWithPath: path).lastPathComponent
                .replacingOccurrences(of: "cu.", with: "")
                .replacingOccurrences(of: "tty.", with: "")
            var isBt = lower.contains("bluetooth") || lower.contains("bt") || lower.contains("kechaoda")
            var isUsb = lower.contains("usb") || lower.contains("slab") || lower.contains("wch")
            var dName = rawName
            var manufacturer = isBt ? "Bluetooth Serial Device" : (isUsb ? "USB Serial Device" : "Serial Device")
            var btConn = false
            var btPair = false
            var btAddr = ""

            for (btName, status) in btDevices {
                let sanitizedBtName = btName.replacingOccurrences(of: " ", with: "").lowercased()
                let sanitizedPath = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                if sanitizedPath.contains(sanitizedBtName) || sanitizedBtName.contains(sanitizedPath) || lower.contains(btName.lowercased()) || (lower.contains("kechaoda") && btName.lowercased().contains("kechaoda")) {
                    isBt = true
                    isUsb = false
                    dName = status.realName.isEmpty ? "KECHAODA Phone" : status.realName
                    btConn = status.connected
                    btPair = status.paired
                    btAddr = status.address
                    manufacturer = "Bluetooth (" + (status.isPhone ? "Mobile Phone" : "Endpoint") + ")"
                    break
                }
            }

            if lower.contains("kechaoda") && dName == rawName {
                isBt = true
                isUsb = false
                dName = "KECHAODA Phone (Bluetooth SPP)"
                manufacturer = "Bluetooth Mobile Phone"
            }

            if lower.contains("bluetooth-incoming") {
                isBt = true
                isUsb = false
                dName = "Bluetooth Incoming Port"
                manufacturer = "macOS Bluetooth Subsystem"
            }

            if dName == rawName && lower.contains("usbmodem") {
                dName = "USB Cellular / Modem"
            }

            result.append([
                "name": dName,
                "manufacturer": manufacturer,
                "model": "",
                "path": path,
                "vendorId": 0,
                "productId": 0,
                "usb": !isBt,
                "btConnected": btConn,
                "btPaired": btPair,
                "btAddress": btAddr
            ])
            seenPaths.insert(path)
        }

        // Include paired/connected Bluetooth devices without dedicated /dev/cu.* node so they are easily accessible
        var seenBtAddrs = Set(result.compactMap { ($0["btAddress"] as? String)?.uppercased() })
        for (_, status) in btDevices {
            let addr = status.address.uppercased()
            guard !addr.isEmpty, !seenBtAddrs.contains(addr) else { continue }
            seenBtAddrs.insert(addr)

            let btPath = "bt://\(status.address)"
            if seenPaths.contains(btPath) { continue }
            seenPaths.insert(btPath)

            result.append([
                "name": status.realName,
                "manufacturer": "Bluetooth (" + (status.isPhone ? "Mobile Phone" : "Paired Device") + ")",
                "model": "",
                "path": btPath,
                "vendorId": 0,
                "productId": 0,
                "usb": false,
                "btConnected": status.connected,
                "btPaired": status.paired,
                "btAddress": status.address
            ])
        }

        // Sort: USB devices first, then Bluetooth devices, alphabetically by name
        return result.sorted {
            let lhsConn = ($0["btConnected"] as? Bool ?? false)
            let rhsConn = ($1["btConnected"] as? Bool ?? false)
            if lhsConn != rhsConn { return lhsConn && !rhsConn }
            let lhsUSB = $0["usb"] as? Bool ?? false
            let rhsUSB = $1["usb"] as? Bool ?? false
            if lhsUSB != rhsUSB { return lhsUSB && !rhsUSB }
            return ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
        }
    }

    static func listBluetoothDevices() -> [[String: Any]] {
        var list: [[String: Any]] = []
        var seen = Set<String>()

        func addDevice(_ device: IOBluetoothDevice) {
            let address = device.addressString ?? ""
            guard !address.isEmpty, !seen.contains(address) else { return }
            seen.insert(address)

            let name = device.name ?? device.nameOrAddress ?? "Bluetooth Device"
            let connected = device.isConnected()
            let isPaired = device.isPaired()
            let isFavorite = device.isFavorite()
            let deviceClass = Int(device.classOfDevice)
            let rssi = connected ? Int(device.rawRSSI()) : 0

            list.append([
                "name": name,
                "address": address,
                "connected": connected,
                "paired": isPaired,
                "favorite": isFavorite,
                "deviceClass": deviceClass,
                "rssi": rssi
            ])
        }

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired { addDevice(device) }
        }
        if let favs = IOBluetoothDevice.favoriteDevices() as? [IOBluetoothDevice] {
            for device in favs { addDevice(device) }
        }
        if let recent = IOBluetoothDevice.recentDevices(20) as? [IOBluetoothDevice] {
            for device in recent { addDevice(device) }
        }

        return list.sorted {
            let lhsConn = $0["connected"] as? Bool ?? false
            let rhsConn = $1["connected"] as? Bool ?? false
            if lhsConn != rhsConn { return lhsConn && !rhsConn }
            return ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
        }
    }

    static func connectBluetoothDevice(address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        let kr = device.openConnection()
        return kr == kIOReturnSuccess
    }

    static func disconnectBluetoothDevice(address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        let kr = device.closeConnection()
        return kr == kIOReturnSuccess
    }

    static func ejectBluetoothDevice(address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        let kr = device.closeConnection()
        return kr == kIOReturnSuccess || !device.isConnected()
    }

    static func showNativeNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound.default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }

    private static func fetchBluetoothDeviceInfo() -> [String: (connected: Bool, paired: Bool, realName: String, address: String, isPhone: Bool)] {
        var map: [String: (connected: Bool, paired: Bool, realName: String, address: String, isPhone: Bool)] = [:]
        var allDevices: [IOBluetoothDevice] = []
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            allDevices.append(contentsOf: paired)
        }
        if let recent = IOBluetoothDevice.recentDevices(100) as? [IOBluetoothDevice] {
            allDevices.append(contentsOf: recent)
        }
        if let favs = IOBluetoothDevice.favoriteDevices() as? [IOBluetoothDevice] {
            allDevices.append(contentsOf: favs)
        }

        for device in allDevices {
            let name = device.name ?? device.nameOrAddress ?? ""
            let connected = device.isConnected()
            let paired = device.isPaired()
            let addr = device.addressString ?? ""
            let devClass = Int(device.classOfDevice)
            let isPhone = devClass == 512 || name.lowercased().contains("phone") || name.lowercased().contains("kechaoda") || name.lowercased().contains("mobile") || name.lowercased().contains("gsm")
            if !name.isEmpty {
                map[name] = (connected, paired, device.name ?? name, addr, isPhone)
                map[name.lowercased()] = (connected, paired, device.name ?? name, addr, isPhone)
            }
            if !addr.isEmpty {
                map[addr] = (connected, paired, device.name ?? name, addr, isPhone)
                map[addr.lowercased()] = (connected, paired, device.name ?? name, addr, isPhone)
            }
        }
        return map
    }

    private static func serialDevicePathsFromFs() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        var cuPaths: [String] = []
        var ttyPaths: [String] = []

        for entry in entries {
            if entry.hasPrefix("cu.") {
                cuPaths.append("/dev/\(entry)")
            } else if entry.hasPrefix("tty.") {
                ttyPaths.append("/dev/\(entry)")
            }
        }

        // Deduplicate: if cu.XYZ exists, prefer it over tty.XYZ; if only tty.XYZ exists, include it
        var finalPaths: [String] = cuPaths
        let cuSuffixes = Set(cuPaths.map { $0.replacingOccurrences(of: "/dev/cu.", with: "") })
        for ttyPath in ttyPaths {
            let suffix = ttyPath.replacingOccurrences(of: "/dev/tty.", with: "")
            if !cuSuffixes.contains(suffix) {
                finalPaths.append(ttyPath)
            }
        }

        return finalPaths.sorted()
    }
}
