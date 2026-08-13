import Foundation

private enum InputTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw InputTestFailure.assertion(message) }
}

private func testInterfaceRegistryTracksEveryInterface() throws {
    var registry = RemoteInterfaceRegistry<String>()

    try expect(registry.add("consumer") == .added(isFirst: true), "First interface should connect the remote")
    try expect(registry.add("digitizer") == .added(isFirst: false), "Second interface should not reconnect the remote")
    try expect(registry.add("vendor") == .added(isFirst: false), "Third interface should not reconnect the remote")
    try expect(registry.add("consumer") == .duplicate, "Duplicate enumeration should be ignored")
    try expect(registry.count == 3, "Duplicate enumeration changed the interface count")

    try expect(registry.remove("digitizer") == .removed(isLast: false), "Partial removal disconnected the remote")
    try expect(registry.remove("unknown") == .unknown, "Unknown removal should be ignored")
    try expect(registry.remove("consumer") == .removed(isLast: false), "Second partial removal disconnected the remote")
    try expect(registry.remove("vendor") == .removed(isLast: true), "Last interface did not disconnect the remote")
    try expect(registry.remove("vendor") == .unknown, "Duplicate removal should be ignored")
    try expect(registry.count == 0, "Registry count underflowed after duplicate removal")

    try expect(registry.add("reconnected") == .added(isFirst: true), "Reconnect should begin a fresh session")
    try expect(registry.isConnected, "Reconnected interface was not retained")
    try expect(registry.reset(), "Reset should report an active connection")
    try expect(!registry.reset(), "Second reset should report no active connection")
}

private func testPhysicalClickQuickReleaseCancelsStaleThreshold() throws {
    var session = PhysicalClickSession()
    try expect(session.press() == [.begin(token: 1)], "Press should begin click session 1")
    try expect(session.release() == [.finishClick], "Quick release should finish exactly one click")
    try expect(session.dragThresholdReached(token: 1).isEmpty, "Released session accepted a stale drag timer")
    try expect(session.release().isEmpty, "Duplicate release should be ignored")
}

private func testPhysicalClickTimersAreBoundToTheirPress() throws {
    var session = PhysicalClickSession()
    _ = session.press()
    _ = session.release()
    try expect(session.press() == [.begin(token: 2)], "Second press should use a new generation token")
    try expect(session.dragThresholdReached(token: 1).isEmpty, "First timer started drag during second press")
    try expect(session.dragThresholdReached(token: 2) == [.startDrag], "Current timer did not start drag")
    try expect(session.release() == [.finishDrag], "Drag release should produce one balanced finish")
}

private func testPhysicalClickDisconnectIsIdempotent() throws {
    var pending = PhysicalClickSession()
    _ = pending.press()
    try expect(pending.cancel() == [.cancelPending], "Disconnect before threshold should cancel without clicking")
    try expect(pending.cancel().isEmpty, "Repeated pending cancellation should be ignored")
    try expect(pending.dragThresholdReached(token: 1).isEmpty, "Cancelled timer started drag after disconnect")

    var dragging = PhysicalClickSession()
    _ = dragging.press()
    _ = dragging.dragThresholdReached(token: 1)
    try expect(dragging.cancel() == [.cancelDrag], "Disconnect during drag should request a balancing mouse-up")
    try expect(dragging.cancel().isEmpty, "Repeated drag cancellation should not request a second mouse-up")
}

private func testBatteryNormalization() throws {
    try expect(BatteryValueNormalizer.percent(value: 128, logicalMin: 0, logicalMax: 255) == 50,
               "HID logical range did not normalize to percent")
    try expect(BatteryValueNormalizer.percent(value: 75, logicalMin: 0, logicalMax: 100) == 75,
               "Native percent range changed the value")
    try expect(BatteryValueNormalizer.percent(remaining: 205, full: 410) == 50,
               "Capacity ratio did not normalize to percent")
    try expect(BatteryValueNormalizer.percent(value: 101, logicalMin: 0, logicalMax: 100) == nil,
               "Out-of-range HID value should be rejected")
    try expect(BatteryValueNormalizer.percent(remaining: 1, full: 0) == nil,
               "Invalid full capacity should be rejected")
}

private func testConnectionNotificationPolicyDebouncesInterfaceFlapping() throws {
    var policy = RemoteConnectionAlertPolicy()
    try expect(policy.observe(isConnected: true) == [.notifyConnected],
               "First connection should notify once")
    try expect(policy.observe(isConnected: true).isEmpty,
               "Additional HID interfaces should not duplicate connection notifications")
    try expect(policy.observe(isConnected: false) == [.scheduleDisconnect],
               "Disconnect should wait for the debounce window")
    try expect(policy.observe(isConnected: true) == [.cancelDisconnect],
               "Fast reconnect should cancel the pending disconnect")
    try expect(policy.disconnectDelayElapsed(isStillDisconnected: false).isEmpty,
               "Cancelled disconnect timer should not notify")
    try expect(policy.observe(isConnected: false) == [.scheduleDisconnect],
               "Later real disconnect should schedule again")
    try expect(policy.disconnectDelayElapsed(isStillDisconnected: true) == [.notifyDisconnected],
               "Stable disconnect should notify once")
    try expect(policy.disconnectDelayElapsed(isStillDisconnected: true).isEmpty,
               "Expired disconnect timer should be idempotent")
    try expect(policy.observe(isConnected: true) == [.notifyConnected],
               "Reconnect after a real disconnect should notify")
}

private func testLowBatteryPolicyDeduplicatesAndRearms() throws {
    var policy = LowBatteryAlertPolicy()
    let start = Date(timeIntervalSince1970: 1_000_000)

    try expect(!policy.shouldNotify(percent: 21, threshold: 20, now: start, lastNotificationDate: nil),
               "Battery above threshold should not alert")
    try expect(policy.shouldNotify(percent: 20, threshold: 20, now: start, lastNotificationDate: nil),
               "Threshold crossing should alert")
    try expect(!policy.shouldNotify(percent: 18, threshold: 20, now: start.addingTimeInterval(60), lastNotificationDate: nil),
               "Repeated low readings should be deduplicated")
    try expect(!policy.shouldNotify(percent: 24, threshold: 20, now: start.addingTimeInterval(120), lastNotificationDate: nil),
               "Hysteresis band should not rearm the alert")
    try expect(!policy.shouldNotify(percent: 25, threshold: 20, now: start.addingTimeInterval(180), lastNotificationDate: nil),
               "Charging above hysteresis should only rearm")
    try expect(policy.shouldNotify(percent: 19, threshold: 20, now: start.addingTimeInterval(240), lastNotificationDate: nil),
               "A new low crossing after recharge should alert")

    var cooldownPolicy = LowBatteryAlertPolicy()
    let recent = start.addingTimeInterval(-60)
    try expect(!cooldownPolicy.shouldNotify(percent: 10, threshold: 20, now: start, lastNotificationDate: recent),
               "Recent persisted notification should suppress a launch-time duplicate")
}

@main
private enum InputLifecycleTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("interface registry", testInterfaceRegistryTracksEveryInterface),
            ("quick physical click", testPhysicalClickQuickReleaseCancelsStaleThreshold),
            ("physical click timer generation", testPhysicalClickTimersAreBoundToTheirPress),
            ("physical click disconnect", testPhysicalClickDisconnectIsIdempotent),
            ("connection notification debounce", testConnectionNotificationPolicyDebouncesInterfaceFlapping),
            ("battery normalization", testBatteryNormalization),
            ("low battery alert policy", testLowBatteryPolicyDeduplicatesAndRearms),
        ]

        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
    }
}
