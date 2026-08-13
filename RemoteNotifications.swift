import Foundation
import UserNotifications

enum RemoteNotificationPreferences {
    private static let connectionKey = "notifications.remoteConnection"
    private static let lowBatteryKey = "notifications.lowBattery"
    private static let lowBatteryThresholdKey = "notifications.lowBatteryThreshold"

    static var connectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: connectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: connectionKey) }
    }

    static var lowBatteryEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: lowBatteryKey) }
        set { UserDefaults.standard.set(newValue, forKey: lowBatteryKey) }
    }

    static var lowBatteryThreshold: Int {
        get {
            guard UserDefaults.standard.object(forKey: lowBatteryThresholdKey) != nil else { return 20 }
            return min(30, max(5, UserDefaults.standard.integer(forKey: lowBatteryThresholdKey)))
        }
        set { UserDefaults.standard.set(min(30, max(5, newValue)), forKey: lowBatteryThresholdKey) }
    }

    static var anyEnabled: Bool { connectionEnabled || lowBatteryEnabled }
}

final class RemoteNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private static let lastLowBatteryNotificationKey = "notifications.lastLowBatteryDate"

    private let center: UNUserNotificationCenter
    private var currentStatus = RemoteStatus.disconnected
    private var connectionPolicy = RemoteConnectionAlertPolicy()
    private var pendingDisconnect: DispatchWorkItem?
    private var lowBatteryPolicy = LowBatteryAlertPolicy()

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func start(currentStatus: RemoteStatus) {
        self.currentStatus = currentStatus
        connectionPolicy = RemoteConnectionAlertPolicy(isConnected: currentStatus.isConnected)
        if RemoteNotificationPreferences.anyEnabled {
            requestAuthorization()
        }
        evaluateLowBattery(currentStatus)
    }

    func update(_ status: RemoteStatus) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.update(status) }
            return
        }

        currentStatus = status
        updateConnectionState(status)
        evaluateLowBattery(status)
    }

    func preferencesDidChange() {
        lowBatteryPolicy = LowBatteryAlertPolicy()
        guard RemoteNotificationPreferences.anyEnabled else { return }
        requestAuthorization { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.evaluateLowBattery(self.currentStatus)
            }
        }
    }

    func stop() {
        pendingDisconnect?.cancel()
        pendingDisconnect = nil
    }

    private func updateConnectionState(_ status: RemoteStatus) {
        applyConnectionEffects(connectionPolicy.observe(isConnected: status.isConnected), status: status)
    }

    private func applyConnectionEffects(
        _ effects: [RemoteConnectionAlertPolicy.Effect],
        status: RemoteStatus
    ) {
        for effect in effects {
            switch effect {
            case .notifyConnected:
                guard RemoteNotificationPreferences.connectionEnabled else { continue }
                var body = "Siri Remote is ready."
                if let battery = status.batteryPercent { body += " Battery: \(battery)%." }
                post(identifier: "remote.connection.connected", title: "Siri Remote Connected", body: body)
            case .scheduleDisconnect:
                pendingDisconnect?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingDisconnect = nil
                    let effects = self.connectionPolicy.disconnectDelayElapsed(
                        isStillDisconnected: !self.currentStatus.isConnected
                    )
                    self.applyConnectionEffects(effects, status: self.currentStatus)
                }
                pendingDisconnect = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            case .cancelDisconnect:
                pendingDisconnect?.cancel()
                pendingDisconnect = nil
            case .notifyDisconnected:
                guard RemoteNotificationPreferences.connectionEnabled else { continue }
                post(
                    identifier: "remote.connection.disconnected",
                    title: "Siri Remote Disconnected",
                    body: "AppleTVremoteRebinder is waiting for the remote to reconnect."
                )
            }
        }
    }

    private func evaluateLowBattery(_ status: RemoteStatus) {
        guard RemoteNotificationPreferences.lowBatteryEnabled,
              status.isConnected,
              let battery = status.batteryPercent else { return }

        let now = Date()
        let lastDate = UserDefaults.standard.object(
            forKey: Self.lastLowBatteryNotificationKey
        ) as? Date
        guard lowBatteryPolicy.shouldNotify(
            percent: battery,
            threshold: RemoteNotificationPreferences.lowBatteryThreshold,
            now: now,
            lastNotificationDate: lastDate
        ) else { return }

        post(
            identifier: "remote.battery.low",
            title: "Siri Remote Battery Low",
            body: "Battery is at \(battery)%. Charge the remote soon."
        ) { delivered in
            if delivered {
                UserDefaults.standard.set(now, forKey: Self.lastLowBatteryNotificationKey)
            }
        }
    }

    private func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error { rmDebug("Notification authorization failed: \(error.localizedDescription)") }
            completion?(granted)
        }
    }

    private func post(
        identifier: String,
        title: String,
        body: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.deliver(identifier: identifier, title: title, body: body, completion: completion)
            case .notDetermined:
                self.requestAuthorization { [weak self] granted in
                    if granted {
                        self?.deliver(identifier: identifier, title: title, body: body, completion: completion)
                    } else {
                        completion?(false)
                    }
                }
            case .denied:
                rmDebug("Notification skipped because permission is denied")
                completion?(false)
            @unknown default:
                rmDebug("Notification skipped because authorization status is unknown")
                completion?(false)
            }
        }
    }

    private func deliver(
        identifier: String,
        title: String,
        body: String,
        completion: ((Bool) -> Void)?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { rmDebug("Notification delivery failed: \(error.localizedDescription)") }
            completion?(error == nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
