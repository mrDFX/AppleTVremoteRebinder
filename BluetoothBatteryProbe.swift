import Foundation

struct BluetoothBatteryIdentity: Hashable {
    let vendorID: Int?
    let productID: Int?
    let serial: String?
    let nameHints: [String]

    var isEmpty: Bool {
        vendorID == nil && productID == nil && (serial?.isEmpty ?? true) && nameHints.isEmpty
    }
}

/// Reads the last-known battery percent macOS caches for a paired Bluetooth
/// peripheral via `system_profiler SPBluetoothDataType`. This is the same
/// source the Bluetooth settings pane uses for BLE accessories whose battery
/// service is not exposed through IOKit.
final class BluetoothBatteryProbe {
    private let workQueue = DispatchQueue(label: "com.appletvremoterebinder.spbluetooth", qos: .utility)
    private let cacheTTL: TimeInterval
    private let cooldown: TimeInterval

    private var cachedPercent: Int?
    private var cachedAt: TimeInterval = 0
    private var lastAttemptAt: TimeInterval = 0
    private var inFlight = false
    private var pendingCompletions: [(Int?) -> Void] = []

    init(cacheTTL: TimeInterval = 300, cooldown: TimeInterval = 20) {
        self.cacheTTL = cacheTTL
        self.cooldown = cooldown
    }

    func readBatteryPercent(
        matching identity: BluetoothBatteryIdentity,
        force: Bool = false,
        completion: @escaping (Int?) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { completion(nil); return }
            let now = ProcessInfo.processInfo.systemUptime

            if !force, let cached = self.cachedPercent, now - self.cachedAt < self.cacheTTL {
                completion(cached)
                return
            }

            if self.inFlight {
                self.pendingCompletions.append(completion)
                return
            }

            if !force, now - self.lastAttemptAt < self.cooldown {
                completion(self.cachedPercent)
                return
            }

            self.inFlight = true
            self.lastAttemptAt = now
            self.pendingCompletions.append(completion)

            let percent = Self.runSystemProfilerBatteryPercent(matching: identity)

            if let percent {
                self.cachedPercent = percent
                self.cachedAt = ProcessInfo.processInfo.systemUptime
                rmDebug("🔋 spbluetooth BatteryPercent=\(percent)")
            } else {
                rmDebug("🔋 spbluetooth returned no battery for matching device")
            }

            let waiters = self.pendingCompletions
            self.pendingCompletions.removeAll(keepingCapacity: false)
            self.inFlight = false
            for waiter in waiters { waiter(percent) }
        }
    }

    private static func runSystemProfilerBatteryPercent(
        matching identity: BluetoothBatteryIdentity
    ) -> Int? {
        guard let data = runSystemProfiler() else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findBatteryPercent(in: root, matching: identity)
    }

    private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.launchPath = "/usr/sbin/system_profiler"
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            rmDebug("🔋 spbluetooth launch failed: \(error.localizedDescription)")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            rmDebug("🔋 spbluetooth exit=\(process.terminationStatus)")
            return nil
        }
        return data.isEmpty ? nil : data
    }

    private static let batteryKeys: Set<String> = [
        "device_batteryLevelMain",
        "device_batteryLevel",
        "device_BatteryLevelMain",
        "device_BatteryLevel",
        "batt_level_main",
        "battery_level"
    ]

    // Walk the arbitrary SPBluetoothDataType JSON tree, collecting any dictionary
    // that carries device identifying keys, then return the best-matching entry's
    // battery percent.
    private static func findBatteryPercent(
        in node: Any,
        matching identity: BluetoothBatteryIdentity
    ) -> Int? {
        var bestMatch: (score: Int, percent: Int)?
        walkDeviceDictionaries(node) { dict in
            guard let percent = extractPercent(from: dict) else { return }
            let score = matchScore(dict: dict, identity: identity)
            guard score > 0 else { return }
            if bestMatch == nil || score > (bestMatch?.score ?? 0) {
                bestMatch = (score, percent)
            }
        }
        return bestMatch?.percent
    }

    private static func walkDeviceDictionaries(_ node: Any, visit: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            visit(dict)
            for value in dict.values {
                walkDeviceDictionaries(value, visit: visit)
            }
        } else if let array = node as? [Any] {
            for value in array {
                walkDeviceDictionaries(value, visit: visit)
            }
        }
    }

    private static func extractPercent(from dict: [String: Any]) -> Int? {
        for key in batteryKeys {
            guard let raw = dict[key] else { continue }
            if let n = raw as? NSNumber { return clamp(n.intValue) }
            if let s = raw as? String {
                let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
                if let value = Int(trimmed) { return clamp(value) }
            }
        }
        return nil
    }

    private static func matchScore(
        dict: [String: Any],
        identity: BluetoothBatteryIdentity
    ) -> Int {
        var score = 0

        if let serial = identity.serial?.lowercased(), !serial.isEmpty {
            if dict.values.contains(where: { ($0 as? String)?.lowercased() == serial }) {
                score += 10
            }
        }

        let productHex = identity.productID.map { String(format: "0x%04x", $0).lowercased() }
        let vendorHex = identity.vendorID.map { String(format: "0x%04x", $0).lowercased() }
        for (_, value) in dict {
            guard let s = (value as? String)?.lowercased() else { continue }
            if let productHex, s == productHex { score += 4 }
            if let vendorHex, s == vendorHex { score += 2 }
        }

        let joinedNames = dict.reduce(into: "") { partial, entry in
            if let s = entry.value as? String { partial += " " + s.lowercased() }
            partial += " " + entry.key.lowercased()
        }
        for hint in identity.nameHints where !hint.isEmpty {
            if joinedNames.contains(hint.lowercased()) { score += 1 }
        }

        return score
    }

    private static func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}
