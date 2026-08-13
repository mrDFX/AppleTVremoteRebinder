//
//  RemoteDetector.swift
//  AppleTVremoteRebinder
//
//  Detects Siri Remote via IOKit HID
//

import Foundation
import IOKit
import IOKit.hid

enum RemoteDetectorEvent {
    case interfaceAdded(IOHIDDevice, startsSession: Bool)
    case interfaceRemoved(IOHIDDevice, endsSession: Bool)
    case statusChanged(RemoteStatus)
    case stopped
}

/// Append diagnostic line to /tmp/appletvremoterebinder.log (unified-log redacts NSLog under hardened runtime).
func rmDebug(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/appletvremoterebinder.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

class RemoteDetector {
    private var manager: IOHIDManager?
    private var eventCallback: ((RemoteDetectorEvent) -> Bool)?
    private var interfaceRegistry = RemoteInterfaceRegistry<InterfaceIdentifier>()
    private var devices: [InterfaceIdentifier: IOHIDDevice] = [:]
    private var isDetecting = false
    private var sessionProductName: String?
    private var lastBatteryPercent: Int?
    private var lastBatterySampleUptime: TimeInterval = 0
    private var lastPublishedStatus = RemoteStatus.disconnected
    private var delayedBatteryRefresh: DispatchWorkItem?
    private let batteryProbe = BluetoothBatteryProbe()

    private let appleVendorID: Int = 0x004C

    // Known Siri Remote / Apple TV Remote product IDs
    private let knownProductIDs: [Int] = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x0269, 0x026D,
        0x0C4E, 0x0C4F, 0x030D, 0x030E
    ]
    
    private enum InterfaceIdentifier: Hashable {
        case registryEntry(UInt64)
        case object(ObjectIdentifier)
    }

    init(eventCallback: @escaping (RemoteDetectorEvent) -> Bool) {
        self.eventCallback = eventCallback
    }
    
    func startDetection() {
        guard !isDetecting else { return }
        rmDebug(String(format: "🛰 starting HID detection (vendor=0x%X)", appleVendorID))
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else {
            rmDebug("⚠️ IOHIDManagerCreate returned nil")
            return
        }

        // SiriMote uses IOHIDManagerSetDeviceMatchingMultiple with per-interface dicts.
        // The Siri Remote A1513 exposes 3 HID interfaces (consumer, game controls, vendor),
        // and the singular variant with vendor-only matching does not enumerate them on
        // recent macOS BLE HID stacks.
        let matchingDicts: [[String: Any]] = [
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0C],   // Consumer Page
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0D],   // Digitizer / Game Controls
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00], // Apple vendor-defined
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x01],   // Generic Desktop (kept for keyboards/trackpads)
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x06],   // Generic Device Controls (battery)
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x85],   // Battery System
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, Unmanaged.passUnretained(self).toOpaque())

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            rmDebug(String(format: "⚠️ IOHIDManagerOpen failed (IOReturn=0x%X)", openResult))
            self.manager = nil
            return
        }
        isDetecting = true
        rmDebug("🛰 IOHIDManagerOpen success")

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enumerateAllDevices()
        }
    }
    
    func stopDetection() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { [weak self] in self?.stopDetection() }
            return
        }

        let shouldPublishStop = isDetecting || interfaceRegistry.isConnected
        isDetecting = false
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        interfaceRegistry.reset()
        devices.removeAll()
        delayedBatteryRefresh?.cancel()
        delayedBatteryRefresh = nil
        sessionProductName = nil
        lastBatteryPercent = nil
        lastBatterySampleUptime = 0
        lastPublishedStatus = .disconnected
        if shouldPublishStop { _ = eventCallback?(.stopped) }
    }
    
    private func enumerateAllDevices() {
        guard isDetecting, let manager = manager,
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            rmDebug("🛰 IOHIDManagerCopyDevices returned nil/empty (TCC block or matching mismatch)")
            return
        }
        rmDebug("🛰 enumeration found \(deviceSet.count) HID device(s) matching filter")
        for device in deviceSet {
            let v = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let p = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let n = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let pup = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let pu  = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            rmDebug(String(format: "🛰 candidate vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X name=%@",
                           v, p, pup, pu, n))
            if isSiriRemote(device) {
                handleDeviceAdded(device)
            }
        }
    }
    
    private func isSiriRemote(_ device: IOHIDDevice) -> Bool {
        guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
              vendorID == appleVendorID else { return false }
        
        if let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
           knownProductIDs.contains(productID) {
            return true
        }
        
        if let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            let name = productName.lowercased()
            return name.contains("remote") || name.contains("siri") || name.contains("apple tv")
        }
        
        return false
    }
    
    func handleDeviceAdded(_ device: IOHIDDevice) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handleDeviceAdded(device) }
            return
        }
        guard isDetecting else { return }
        guard isSiriRemote(device) else { return }
        
        // Get device properties (safe to read from any thread)
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        
        let identifier = interfaceIdentifier(for: device)
        guard case .added(let startsSession) = interfaceRegistry.add(identifier) else { return }

        if startsSession {
            lastBatteryPercent = nil
            lastBatterySampleUptime = 0
            sessionProductName = nil
        }
        devices[identifier] = device

        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Siri Remote"
        sessionProductName = sessionProductName ?? productName
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        rmDebug(String(format: "🛰 interface added id=%@ usagePage=0x%X usage=0x%X active=%d",
                       String(describing: identifier), usagePage, usage, interfaceRegistry.count))

        if startsSession {
            print("✅ Siri Remote connected: \(productName) (Vendor: 0x\(String(vendorID, radix: 16, uppercase: true)), Product: 0x\(String(productID, radix: 16, uppercase: true)))")
        }

        guard eventCallback?(.interfaceAdded(device, startsSession: startsSession)) == true else {
            _ = interfaceRegistry.remove(identifier)
            devices.removeValue(forKey: identifier)
            if !interfaceRegistry.isConnected {
                sessionProductName = nil
                lastBatteryPercent = nil
                lastBatterySampleUptime = 0
            }
            rmDebug("⚠️ HID interface registration failed id=\(identifier)")
            publishStatus(forceBatteryRead: false)
            return
        }
        publishStatus(forceBatteryRead: true)
        if startsSession {
            delayedBatteryRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.interfaceRegistry.isConnected else { return }
                self.delayedBatteryRefresh = nil
                self.publishStatus(forceBatteryRead: true)
            }
            delayedBatteryRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }
    
    func handleDeviceRemoved(_ device: IOHIDDevice) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handleDeviceRemoved(device) }
            return
        }
        guard isDetecting else { return }
        guard isSiriRemote(device) else { return }

        let identifier = interfaceIdentifier(for: device)
        guard case .removed(let endsSession) = interfaceRegistry.remove(identifier) else { return }
        let registeredDevice = devices.removeValue(forKey: identifier) ?? device
        rmDebug("🛰 interface removed id=\(identifier) active=\(interfaceRegistry.count)")
        _ = eventCallback?(.interfaceRemoved(registeredDevice, endsSession: endsSession))

        if endsSession {
            print("❌ Siri Remote disconnected: \(sessionProductName ?? "Siri Remote")")
            delayedBatteryRefresh?.cancel()
            delayedBatteryRefresh = nil
            sessionProductName = nil
            lastBatteryPercent = nil
            lastBatterySampleUptime = 0
        }
        publishStatus(forceBatteryRead: false)
    }

    func refreshBatteryIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refreshBatteryIfNeeded() }
            return
        }
        guard isDetecting, interfaceRegistry.isConnected else { return }
        publishStatus(forceBatteryRead: false)
    }

    private func publishStatus(forceBatteryRead: Bool) {
        let status: RemoteStatus
        if interfaceRegistry.isConnected {
            let now = ProcessInfo.processInfo.systemUptime
            let retryInterval: TimeInterval = lastBatteryPercent == nil ? 5 : 60
            if forceBatteryRead || now - lastBatterySampleUptime >= retryInterval {
                lastBatterySampleUptime = now
                if let battery = RemoteBatteryReader.batteryPercent(from: Array(devices.values)) {
                    lastBatteryPercent = battery
                    rmDebug("🔋 Siri Remote battery: \(battery)%")
                } else {
                    requestBluetoothBatteryProbe(force: forceBatteryRead)
                }
            }
            status = RemoteStatus(
                isConnected: true,
                productName: sessionProductName,
                batteryPercent: lastBatteryPercent,
                interfaceCount: interfaceRegistry.count
            )
        } else {
            status = .disconnected
        }

        guard status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        _ = eventCallback?(.statusChanged(status))
    }

    private func requestBluetoothBatteryProbe(force: Bool) {
        let identity = currentBluetoothIdentity()
        guard !identity.isEmpty else { return }
        batteryProbe.readBatteryPercent(matching: identity, force: force) { [weak self] percent in
            DispatchQueue.main.async {
                guard let self, self.interfaceRegistry.isConnected, let percent else { return }
                self.lastBatteryPercent = percent
                self.lastBatterySampleUptime = ProcessInfo.processInfo.systemUptime
                self.publishStatus(forceBatteryRead: false)
            }
        }
    }

    private func currentBluetoothIdentity() -> BluetoothBatteryIdentity {
        var vendorID: Int?
        var productID: Int?
        var serial: String?
        var names: Set<String> = []
        for device in devices.values {
            if vendorID == nil {
                vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
            }
            if productID == nil {
                productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            }
            if serial == nil {
                serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
            }
            if let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
                names.insert(name)
            }
        }
        if let sessionProductName { names.insert(sessionProductName) }
        return BluetoothBatteryIdentity(
            vendorID: vendorID,
            productID: productID,
            serial: serial,
            nameHints: Array(names)
        )
    }

    private func interfaceIdentifier(for device: IOHIDDevice) -> InterfaceIdentifier {
        let service = IOHIDDeviceGetService(device)
        if service != 0 {
            var identifier: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS {
                return .registryEntry(identifier)
            }
        }
        return .object(ObjectIdentifier(device))
    }
}

// C callbacks
private func deviceAddedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceAdded(device)
}

private func deviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceRemoved(device)
}
