import Foundation
import IOKit
import IOKit.hid

enum RemoteBatteryReader {
    static func batteryPercent(from devices: [IOHIDDevice]) -> Int? {
        let readings = devices.compactMap(batteryPercent(from:))
        return readings.min()
    }

    private static func batteryPercent(from device: IOHIDDevice) -> Int? {
        if let percent = numericProperty(named: "BatteryPercent", on: device) {
            return clampedPercent(percent)
        }
        if let percent = batteryElementPercent(on: device) {
            return percent
        }
        if let percent = registryBatteryPercent(on: device) {
            return clampedPercent(percent)
        }
        return nil
    }

    private static func numericProperty(named key: String, on device: IOHIDDevice) -> Double? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.doubleValue
    }

    private static func registryBatteryPercent(on device: IOHIDDevice) -> Double? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0,
              let property = IORegistryEntrySearchCFProperty(
                service,
                kIOServicePlane,
                "BatteryPercent" as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
              ) as? NSNumber else { return nil }
        return property.doubleValue
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
}
