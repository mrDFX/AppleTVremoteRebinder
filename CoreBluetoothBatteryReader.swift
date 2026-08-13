import Foundation
import CoreBluetooth

/// Reads the standard BLE Battery Service (0x180F) characteristic Battery
/// Level (0x2A19) from a Siri Remote that macOS has already connected as an
/// HID peripheral. This is the same source the System Settings → Bluetooth
/// pane reads: for some Siri Remote firmware (notably A2540 / product 0x026D)
/// macOS never publishes battery through IOKit or SPBluetooth, but does keep
/// the GATT session alive so a second CoreBluetooth client can read it.
///
/// The reader is idempotent and cached. Callers pass a set of name substrings
/// (e.g. "Siri Remote", "AppleTV Remote") and, optionally, a known peripheral
/// identifier (from a prior successful match). Completion runs on an arbitrary
/// queue.
final class CoreBluetoothBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelCharUUID = CBUUID(string: "2A19")
    static let hidServiceUUID = CBUUID(string: "1812")

    private let central: CBCentralManager
    private let workQueue = DispatchQueue(label: "com.appletvremoterebinder.cbbattery", qos: .utility)

    private struct PendingRequest {
        let nameHints: [String]
        let knownIdentifier: UUID?
        let completion: (Int?) -> Void
        let deadline: Date
    }

    private var isPoweredOn = false
    private var pendingRequests: [PendingRequest] = []
    private var activePeripherals: [UUID: CBPeripheral] = [:]
    private var completionsByPeripheral: [UUID: [(Int?) -> Void]] = [:]
    private var lastResolvedIdentifier: UUID?
    private var lastCachedPercent: Int?
    private var lastCachedAt: Date = .distantPast
    private let cacheTTL: TimeInterval

    /// Set after a successful read so `RemoteDetector` can persist and reuse it.
    var lastMatchedIdentifier: UUID? { lastResolvedIdentifier }

    init(cacheTTL: TimeInterval = 300) {
        self.cacheTTL = cacheTTL
        self.central = CBCentralManager(delegate: nil, queue: workQueue, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
        super.init()
        self.central.delegate = self
    }

    func readBatteryPercent(
        nameHints: [String],
        knownIdentifier: UUID?,
        timeout: TimeInterval = 8,
        completion: @escaping (Int?) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { completion(nil); return }

            if let cached = self.lastCachedPercent,
               Date().timeIntervalSince(self.lastCachedAt) < self.cacheTTL {
                completion(cached)
                return
            }

            let request = PendingRequest(
                nameHints: nameHints,
                knownIdentifier: knownIdentifier,
                completion: completion,
                deadline: Date().addingTimeInterval(timeout)
            )
            self.pendingRequests.append(request)

            self.workQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expireDeadlines()
            }

            self.pumpIfReady()
        }
    }

    // MARK: - Delegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            isPoweredOn = true
            pumpIfReady()
        } else if central.state == .unauthorized || central.state == .unsupported {
            rmDebug("🔋 corebluetooth state=\(central.state.rawValue) — battery source unavailable")
            drainAll(with: nil)
        }
    }

    // MARK: - Peripheral discovery

    private func pumpIfReady() {
        guard isPoweredOn, !pendingRequests.isEmpty else { return }

        let peripheralsWithHID = central.retrieveConnectedPeripherals(withServices: [Self.hidServiceUUID])
        let peripheralsWithBattery = central.retrieveConnectedPeripherals(withServices: [Self.batteryServiceUUID])
        let all = Array(Set(peripheralsWithHID + peripheralsWithBattery))

        // Snapshot pending because match() may drain requests.
        let requests = pendingRequests
        pendingRequests.removeAll(keepingCapacity: true)

        for request in requests {
            guard let peripheral = firstMatch(in: all, for: request) else {
                // Try again once BT reports state changes, but drop by deadline.
                if Date() < request.deadline {
                    pendingRequests.append(request)
                } else {
                    rmDebug("🔋 corebluetooth no matching peripheral for \(request.nameHints)")
                    request.completion(nil)
                }
                continue
            }

            let id = peripheral.identifier
            completionsByPeripheral[id, default: []].append(request.completion)

            switch peripheral.state {
            case .connected:
                connect(peripheral)  // start GATT discovery
            case .disconnected:
                central.connect(peripheral, options: nil)
                activePeripherals[id] = peripheral
            default:
                activePeripherals[id] = peripheral
            }
        }
    }

    private func firstMatch(in peripherals: [CBPeripheral], for request: PendingRequest) -> CBPeripheral? {
        if let known = request.knownIdentifier,
           let hit = peripherals.first(where: { $0.identifier == known }) {
            return hit
        }
        let lowered = request.nameHints.map { $0.lowercased() }.filter { !$0.isEmpty }
        return peripherals.first { peripheral in
            let name = (peripheral.name ?? "").lowercased()
            guard !name.isEmpty else { return false }
            return lowered.contains { name.contains($0) }
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        activePeripherals[id] = peripheral
        peripheral.delegate = self

        if let existing = peripheral.services?.first(where: { $0.uuid == Self.batteryServiceUUID }) {
            if let char = existing.characteristics?.first(where: { $0.uuid == Self.batteryLevelCharUUID }) {
                if let cached = char.value, let percent = decodePercent(from: cached) {
                    finish(peripheral, percent: percent)
                    return
                }
                peripheral.readValue(for: char)
                return
            }
            peripheral.discoverCharacteristics([Self.batteryLevelCharUUID], for: existing)
            return
        }
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            rmDebug("🔋 corebluetooth discoverServices err=\(error.localizedDescription)")
            finish(peripheral, percent: nil)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryServiceUUID }) else {
            rmDebug("🔋 corebluetooth peripheral has no 0x180F service")
            finish(peripheral, percent: nil)
            return
        }
        peripheral.discoverCharacteristics([Self.batteryLevelCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            rmDebug("🔋 corebluetooth discoverChars err=\(error.localizedDescription)")
            finish(peripheral, percent: nil)
            return
        }
        guard let char = service.characteristics?.first(where: { $0.uuid == Self.batteryLevelCharUUID }) else {
            rmDebug("🔋 corebluetooth service 0x180F has no 0x2A19")
            finish(peripheral, percent: nil)
            return
        }
        peripheral.readValue(for: char)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            rmDebug("🔋 corebluetooth readValue err=\(error.localizedDescription)")
            finish(peripheral, percent: nil)
            return
        }
        guard characteristic.uuid == Self.batteryLevelCharUUID else { return }
        finish(peripheral, percent: characteristic.value.flatMap(decodePercent))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        rmDebug("🔋 corebluetooth failedToConnect err=\(error?.localizedDescription ?? "?")")
        finish(peripheral, percent: nil)
    }

    // MARK: - Helpers

    private func decodePercent(from data: Data) -> Int? {
        guard let byte = data.first else { return nil }
        return min(100, max(0, Int(byte)))
    }

    private func finish(_ peripheral: CBPeripheral, percent: Int?) {
        let id = peripheral.identifier
        let waiters = completionsByPeripheral.removeValue(forKey: id) ?? []
        activePeripherals.removeValue(forKey: id)
        // Disconnect our virtual connection to avoid holding the peripheral open.
        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        }
        if let percent {
            lastCachedPercent = percent
            lastCachedAt = Date()
            lastResolvedIdentifier = id
            rmDebug("🔋 corebluetooth BatteryPercent=\(percent) peripheral=\(id.uuidString)")
        }
        for waiter in waiters { waiter(percent) }
    }

    private func drainAll(with percent: Int?) {
        let requests = pendingRequests
        pendingRequests.removeAll(keepingCapacity: false)
        for request in requests { request.completion(percent) }
        let ids = Array(activePeripherals.keys)
        for id in ids {
            let waiters = completionsByPeripheral.removeValue(forKey: id) ?? []
            for waiter in waiters { waiter(percent) }
        }
        activePeripherals.removeAll()
    }

    private func expireDeadlines() {
        let now = Date()
        let expired = pendingRequests.filter { $0.deadline <= now }
        pendingRequests.removeAll { $0.deadline <= now }
        for request in expired {
            rmDebug("🔋 corebluetooth request timed out for \(request.nameHints)")
            request.completion(nil)
        }
    }
}
