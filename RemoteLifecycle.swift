import Foundation

struct RemoteStatus: Equatable {
    var isConnected: Bool
    var productName: String?
    var batteryPercent: Int?
    var interfaceCount: Int

    static let disconnected = RemoteStatus(
        isConnected: false,
        productName: nil,
        batteryPercent: nil,
        interfaceCount: 0
    )
}

enum RemoteInterfaceAddResult: Equatable {
    case duplicate
    case added(isFirst: Bool)
}

enum RemoteInterfaceRemoveResult: Equatable {
    case unknown
    case removed(isLast: Bool)
}

struct RemoteInterfaceRegistry<Identifier: Hashable> {
    private var identifiers: Set<Identifier> = []

    var count: Int { identifiers.count }
    var isConnected: Bool { !identifiers.isEmpty }

    mutating func add(_ identifier: Identifier) -> RemoteInterfaceAddResult {
        let wasEmpty = identifiers.isEmpty
        guard identifiers.insert(identifier).inserted else { return .duplicate }
        return .added(isFirst: wasEmpty)
    }

    mutating func remove(_ identifier: Identifier) -> RemoteInterfaceRemoveResult {
        guard identifiers.remove(identifier) != nil else { return .unknown }
        return .removed(isLast: identifiers.isEmpty)
    }

    @discardableResult
    mutating func reset() -> Bool {
        let wasConnected = !identifiers.isEmpty
        identifiers.removeAll()
        return wasConnected
    }
}

struct PhysicalClickSession {
    enum Phase: Equatable {
        case idle
        case pressed(token: UInt64)
        case dragging(token: UInt64)
    }

    enum Effect: Equatable {
        case begin(token: UInt64)
        case startDrag
        case finishClick
        case finishDrag
        case cancelPending
        case cancelDrag
    }

    private(set) var phase: Phase = .idle
    private var nextToken: UInt64 = 0

    mutating func press() -> [Effect] {
        guard phase == .idle else { return [] }
        nextToken &+= 1
        phase = .pressed(token: nextToken)
        return [.begin(token: nextToken)]
    }

    mutating func dragThresholdReached(token: UInt64) -> [Effect] {
        guard phase == .pressed(token: token) else { return [] }
        phase = .dragging(token: token)
        return [.startDrag]
    }

    mutating func release() -> [Effect] {
        switch phase {
        case .idle:
            return []
        case .pressed:
            phase = .idle
            return [.finishClick]
        case .dragging:
            phase = .idle
            return [.finishDrag]
        }
    }

    mutating func cancel() -> [Effect] {
        switch phase {
        case .idle:
            return []
        case .pressed:
            phase = .idle
            return [.cancelPending]
        case .dragging:
            phase = .idle
            return [.cancelDrag]
        }
    }
}

struct RemoteConnectionAlertPolicy {
    enum Effect: Equatable {
        case notifyConnected
        case scheduleDisconnect
        case cancelDisconnect
        case notifyDisconnected
    }

    private var effectiveConnected: Bool
    private var disconnectPending = false

    init(isConnected: Bool = false) {
        effectiveConnected = isConnected
    }

    mutating func observe(isConnected: Bool) -> [Effect] {
        if isConnected {
            var effects: [Effect] = []
            if disconnectPending {
                disconnectPending = false
                effects.append(.cancelDisconnect)
            }
            if !effectiveConnected {
                effectiveConnected = true
                effects.append(.notifyConnected)
            }
            return effects
        }

        guard effectiveConnected, !disconnectPending else { return [] }
        disconnectPending = true
        return [.scheduleDisconnect]
    }

    mutating func disconnectDelayElapsed(isStillDisconnected: Bool) -> [Effect] {
        guard disconnectPending else { return [] }
        disconnectPending = false
        guard isStillDisconnected else { return [] }
        effectiveConnected = false
        return [.notifyDisconnected]
    }
}

enum BatteryValueNormalizer {
    static func percent(value: Double, logicalMin: Double, logicalMax: Double) -> Int? {
        guard value.isFinite, logicalMin.isFinite, logicalMax.isFinite,
              logicalMax > logicalMin,
              value >= logicalMin,
              value <= logicalMax else { return nil }
        let normalized = (value - logicalMin) / (logicalMax - logicalMin)
        return min(100, max(0, Int((normalized * 100).rounded())))
    }

    static func percent(remaining: Double, full: Double) -> Int? {
        guard remaining.isFinite, full.isFinite, full > 0, remaining >= 0 else { return nil }
        return min(100, max(0, Int((remaining / full * 100).rounded())))
    }
}

struct LowBatteryAlertPolicy {
    private var wasLow = false

    mutating func shouldNotify(
        percent: Int,
        threshold: Int,
        now: Date,
        lastNotificationDate: Date?,
        cooldown: TimeInterval = 24 * 60 * 60
    ) -> Bool {
        let clampedThreshold = min(100, max(1, threshold))
        if percent >= min(100, clampedThreshold + 5) {
            wasLow = false
            return false
        }
        guard percent <= clampedThreshold else { return false }

        let crossedThreshold = !wasLow
        wasLow = true
        guard crossedThreshold else { return false }
        guard let lastNotificationDate else { return true }
        return now.timeIntervalSince(lastNotificationDate) >= cooldown
    }
}
