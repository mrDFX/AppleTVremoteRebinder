import Foundation
import IOKit
import IOKit.hid

enum RemoteBatteryReader {
    static func batteryPercent(from devices: [IOHIDDevice]) -> Int? {
        let perDevice = devices.compactMap(batteryPercent(from:))
        if let value = perDevice.min() { return value }

        let identities = Set(devices.compactMap(identity(of:)))
        guard !identities.isEmpty else { return nil }
        if let value = scanServicesForBattery(matching: identities) { return value }

        rmDebug("🔋 no battery source resolved for \(identities.count) identity/ies")
        return nil
    }

    private static func batteryPercent(from device: IOHIDDevice) -> Int? {
        if let percent = numericProperty(named: "BatteryPercent", on: device) {
            rmDebug("🔋 hid BatteryPercent=\(percent)")
            return clampedPercent(percent)
        }
        if let percent = batteryElementPercent(on: device) {
            rmDebug("🔋 hid element percent=\(percent)")
            return percent
        }
        if let percent = ancestorRegistryBatteryPercent(on: device) {
            rmDebug("🔋 hid ancestor BatteryPercent=\(percent)")
            return clampedPercent(percent)
        }
        if let percent = descendantRegistryBatteryPercent(on: device) {
            rmDebug("🔋 hid descendant BatteryPercent=\(percent)")
            return clampedPercent(percent)
        }
        return nil
    }

    private static func numericProperty(named key: String, on device: IOHIDDevice) -> Double? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.doubleValue
    }

    private static func ancestorRegistryBatteryPercent(on device: IOHIDDevice) -> Double? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        let raw = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "BatteryPercent" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        return (raw as? NSNumber)?.doubleValue
    }

    private static func descendantRegistryBatteryPercent(on device: IOHIDDevice) -> Double? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        return searchDescendants(of: service, for: "BatteryPercent")
    }

    private static func searchDescendants(of service: io_service_t, for key: String) -> Double? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            if let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let value = (cf as? NSNumber)?.doubleValue {
                return value
            }
        }
        return nil
    }

    private static func batteryElementPercent(on device: IOHIDDevice) -> Int? {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return nil }

        var directReadings: [Int] = []
        var remainingCapacity: Double?
        var fullChargeCapacity: Double?

        for element in elements {
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            guard let rawValue = value(of: element, on: device) else { continue }

            switch (page, usage) {
            case (0x06, 0x20), // Generic Device Controls / Battery Strength
                 (0x0D, 0x3B), // Digitizer / Battery Strength
                 (0x85, 0x64), // Battery System / Relative State of Charge
                 (0x85, 0x65): // Battery System / Absolute State of Charge
                if let percent = BatteryValueNormalizer.percent(
                    value: rawValue,
                    logicalMin: Double(IOHIDElementGetLogicalMin(element)),
                    logicalMax: Double(IOHIDElementGetLogicalMax(element))
                ) {
                    directReadings.append(percent)
                }
            case (0x85, 0x66):
                remainingCapacity = rawValue
            case (0x85, 0x67):
                fullChargeCapacity = rawValue
            default:
                continue
            }
        }

        if let direct = directReadings.min() { return direct }
        if let remainingCapacity, let fullChargeCapacity {
            return BatteryValueNormalizer.percent(remaining: remainingCapacity, full: fullChargeCapacity)
        }
        return nil
    }

    private static func value(of element: IOHIDElement, on device: IOHIDDevice) -> Double? {
        let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { valuePointer.deallocate() }
        guard IOHIDDeviceGetValue(device, element, valuePointer) == kIOReturnSuccess else { return nil }
        let value = valuePointer.pointee.takeUnretainedValue()
        return Double(IOHIDValueGetIntegerValue(value))
    }

    private static func clampedPercent(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0, value <= 100 else { return nil }
        return Int(value.rounded())
    }

    // MARK: - Cross-service scan

    private struct DeviceIdentity: Hashable {
        let vendorID: Int?
        let productID: Int?
        let serial: String?
    }

    private static func identity(of device: IOHIDDevice) -> DeviceIdentity? {
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        guard vendorID != nil || productID != nil || (serial?.isEmpty == false) else { return nil }
        return DeviceIdentity(vendorID: vendorID, productID: productID, serial: serial)
    }

    private static func scanServicesForBattery(matching identities: Set<DeviceIdentity>) -> Int? {
        let candidateClasses = [
            "AppleBluetoothHIDBattery",
            "AppleDeviceManagementHIDEventService",
            "IOHIDDevice"
        ]

        var best: Int?
        for className in candidateClasses {
            guard let matchDict = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            let matched = IOServiceGetMatchingServices(kIOMasterPortDefault, matchDict, &iterator)
            guard matched == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while true {
                let entry = IOIteratorNext(iterator)
                if entry == 0 { break }
                defer { IOObjectRelease(entry) }

                guard let percent = readBatteryPercent(from: entry),
                      let clamped = clampedPercent(percent) else { continue }
                guard matches(entry: entry, identities: identities) else { continue }

                rmDebug("🔋 registry class=\(className) BatteryPercent=\(clamped)")
                if best == nil || clamped < (best ?? 100) { best = clamped }
            }
            if best != nil { return best }
        }
        return best
    }

    private static func readBatteryPercent(from entry: io_registry_entry_t) -> Double? {
        // Prefer the property on the entry itself, then search its ancestors.
        if let cf = IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
           let value = (cf as? NSNumber)?.doubleValue {
            return value
        }
        let inherited = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            "BatteryPercent" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        return (inherited as? NSNumber)?.doubleValue
    }

    private static func matches(entry: io_registry_entry_t, identities: Set<DeviceIdentity>) -> Bool {
        let vendor = firstInt(named: "VendorID", startingAt: entry)
            ?? firstInt(named: "idVendor", startingAt: entry)
        let product = firstInt(named: "ProductID", startingAt: entry)
            ?? firstInt(named: "idProduct", startingAt: entry)
        let serial = firstString(named: "SerialNumber", startingAt: entry)
            ?? firstString(named: "USB Serial Number", startingAt: entry)

        for identity in identities {
            if let s = identity.serial, !s.isEmpty, s == serial { return true }
            if let v = identity.vendorID, let p = identity.productID,
               v == vendor, p == product {
                return true
            }
        }
        return false
    }

    private static func firstInt(named key: String, startingAt entry: io_registry_entry_t) -> Int? {
        let raw = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        return (raw as? NSNumber)?.intValue
    }

    private static func firstString(named key: String, startingAt entry: io_registry_entry_t) -> String? {
        let raw = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        return raw as? String
    }
}
