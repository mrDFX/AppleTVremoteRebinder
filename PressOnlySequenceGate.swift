import Foundation

/// Separates duplicate/repeat events from a new physical press for buttons whose HID path does
/// not expose a trustworthy release. Quarantine is used when profiles change mid-sequence so an
/// old Menu/TV repeat cannot start an action under the replacement profile.
struct PressOnlySequenceGate {
    private var lastAcceptedEvent: [String: TimeInterval] = [:]
    private var quarantineEvent: [String: TimeInterval] = [:]

    mutating func shouldAccept(
        button: String,
        at timestamp: TimeInterval,
        duplicateInterval: TimeInterval,
        quietInterval: TimeInterval
    ) -> Bool {
        if let last = quarantineEvent[button] {
            if timestamp - last < quietInterval {
                quarantineEvent[button] = timestamp
                return false
            }
            quarantineEvent.removeValue(forKey: button)
        }

        if let last = lastAcceptedEvent[button], timestamp - last < duplicateInterval {
            return false
        }
        lastAcceptedEvent[button] = timestamp
        return true
    }

    mutating func quarantineActiveSequences(at timestamp: TimeInterval, quietInterval: TimeInterval) {
        for (button, last) in lastAcceptedEvent where timestamp - last < quietInterval {
            quarantineEvent[button] = timestamp
        }
    }

    mutating func clearAcceptedEvents() {
        lastAcceptedEvent.removeAll()
    }

    mutating func reset() {
        lastAcceptedEvent.removeAll()
        quarantineEvent.removeAll()
    }
}
