import Foundation
import IOKit
import IOKit.usb
import IOKit.serial

enum USBDeviceManager {
    static func listUSBSerialDevices() -> [[String: Any]] {
        var result: [[String: Any]] = []
        let paths = serialDevicePaths()

        for path in paths {
            let lower = path.lowercased()

            // Bluetooth and obvious non-USB virtual ports are excluded.
            if lower.contains("bluetooth") ||
               lower.contains("incoming") ||
               lower.contains("debug") {
                continue
            }

            let usb = USBDeviceManager.matchUSBInfo(for: path)

            // Only return ports that can be associated with USB, or well-known
            // USB serial naming. This keeps the UI USB-only.
            let looksUSB = usb != nil ||
                lower.contains("usb") ||
                lower.contains("kechaoda") ||
                lower.contains("modem")

            guard looksUSB else { continue }

            let info = usb ?? [:]
            result.append([
                "name": info["name"] ?? displayName(for: path),
                "manufacturer": info["manufacturer"] ?? "USB",
                "model": info["model"] ?? "",
                "path": path,
                "vendorId": info["vendorId"] ?? 0,
                "productId": info["productId"] ?? 0,
                "usb": true
            ])
        }

        // De-duplicate by path.
        var seen = Set<String>()
        return result.filter {
            guard let path = $0["path"] as? String else { return false }
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }
    }

    private static func serialDevicePaths() -> [String] {
        let fm = FileManager.default
        let dirs = ["/dev"]
        var paths: [String] = []

        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasPrefix("cu.") || entry.hasPrefix("tty.") {
                paths.append("/dev/\(entry)")
            }
        }
        return paths.sorted()
    }

    private static func displayName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name.lowercased().contains("kechaoda") {
            return "KECHAODA"
        }
        return name
    }

    private static func matchUSBInfo(for path: String) -> [String: Any]? {
        // Find all IOUSBHostDevice entries and use their USB descriptors.
        // The serial path itself is retained as the authoritative port.
        let matching = IOServiceMatching("IOUSBHostDevice")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return nil }

        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }

            var rawProperties: Unmanaged<CFMutableDictionary>?
            let propertiesResult = IORegistryEntryCreateCFProperties(
                service,
                &rawProperties,
                kCFAllocatorDefault,
                0
            )
            let props = propertiesResult == KERN_SUCCESS
                ? rawProperties?.takeRetainedValue() as? [String: Any]
                : nil

            if let props {
                let manufacturer = props["USB Vendor Name"] as? String
                let product = props["USB Product Name"] as? String
                let vendorId = props["idVendor"] as? Int ?? 0
                let productId = props["idProduct"] as? Int ?? 0

                let combined = "\(manufacturer ?? "") \(product ?? "") \(path)".lowercased()

                if combined.contains("kechaoda") ||
                   combined.contains("mediatek") ||
                   combined.contains("usb") {
                    return [
                        "name": product ?? manufacturer ?? "USB Serial Device",
                        "manufacturer": manufacturer ?? "USB",
                        "model": product ?? "",
                        "vendorId": vendorId,
                        "productId": productId
                    ]
                }
            }

            service = IOIteratorNext(iterator)
        }

        return nil
    }
}
