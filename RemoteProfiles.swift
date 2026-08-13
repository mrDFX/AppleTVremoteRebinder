//
//  RemoteProfiles.swift
//  AppleTVremoteRebinder
//
//  Persisted profiles, actions and input preferences.
//

import Foundation

enum RemoteTrigger: String, Codable, CaseIterable {
    case single, double, hold, release

    var title: String {
        switch self {
        case .single: return "Press"
        case .double: return "Double Press"
        case .hold: return "Hold"
        case .release: return "Release"
        }
    }
}

enum RunningApplicationAction: String, Codable, CaseIterable {
    case none, legacy, mediaPlayPause, escape, space

    var title: String {
        switch self {
        case .none: return "Do Nothing"
        case .legacy: return "Current Button Mapping"
        case .mediaPlayPause: return "Media Play/Pause"
        case .escape: return "Escape"
        case .space: return "Space"
        }
    }
}

/// Per-application policy used by Toggle Two Apps. Kept separate so each side can have its own
/// launch/full-screen behaviour (e.g. Kodi launches + fullscreen; Chrome only activates).
struct ApplicationTarget: Codable, Equatable {
    var path: String
    var launchIfNeeded: Bool
    var fullscreen: Bool

    init(path: String, launchIfNeeded: Bool = true, fullscreen: Bool = false) {
        self.path = path
        self.launchIfNeeded = launchIfNeeded
        self.fullscreen = fullscreen
    }

    var name: String { RemoteAction.appName(path) }
}

enum SystemAction: String, Codable, CaseIterable {
    case volumeUp, volumeDown, mute
    case nextTrack, previousTrack
    case escape, returnKey, space
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case tab, appSwitcher
    case rightClick

    var title: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .escape: return "Escape"
        case .returnKey: return "Return"
        case .space: return "Space"
        case .arrowUp: return "Arrow Up"
        case .arrowDown: return "Arrow Down"
        case .arrowLeft: return "Arrow Left"
        case .arrowRight: return "Arrow Right"
        case .tab: return "Tab"
        case .appSwitcher: return "Application Switcher (⌘Tab)"
        case .rightClick: return "Right Click"
        }
    }
}

enum RemoteAction: Codable, Equatable {
    case none
    case legacy
    case mediaPlayPause
    case system(SystemAction)
    case keyStroke(keyCode: Int, flags: UInt64, display: String)
    case launchApplication(path: String, fullscreen: Bool)
    case ensureApplication(path: String, fullscreen: Bool, whenRunning: RunningApplicationAction)
    // v1 compatibility. New UI writes toggleApplicationsV2.
    case toggleApplications(firstPath: String, secondPath: String, fullscreen: Bool)
    case toggleApplicationsV2(first: ApplicationTarget, second: ApplicationTarget)
    case openURL(String)
    case shellCommand(String)
    case voiceInput
    case voiceInputStart
    case voiceInputStop

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .none: return "None"
        case .legacy: return "Current Mapping"
        case .mediaPlayPause: return "Media Play/Pause"
        case .system(let action): return action.title
        case .keyStroke(_, _, let display): return display
        case .launchApplication(let path, let fullscreen):
            return "Open \(Self.appName(path))\(fullscreen ? " · Full Screen" : "")"
        case .ensureApplication(let path, let fullscreen, let whenRunning):
            return "Ensure \(Self.appName(path))\(fullscreen ? " · Full Screen" : "") → \(whenRunning.title)"
        case .toggleApplications(let first, let second, let fullscreen):
            return "\(Self.appName(first)) ⇄ \(Self.appName(second))\(fullscreen ? " · Full Screen" : "")"
        case .toggleApplicationsV2(let first, let second):
            return "\(first.name) ⇄ \(second.name)"
        case .openURL(let value): return "Open URL: \(value)"
        case .shellCommand(let command): return "Shell: \(command)"
        case .voiceInput: return "Siri Remote Voice Input (Toggle)"
        case .voiceInputStart: return "Voice Input — Start"
        case .voiceInputStop: return "Voice Input — Stop"
        }
    }

    static func appName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? path : name
    }
}

struct RemoteProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var bindings: [String: [String: RemoteAction]]

    init(id: UUID = UUID(), name: String, bindings: [String: [String: RemoteAction]] = [:]) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }

    func action(for button: String, trigger: RemoteTrigger) -> RemoteAction {
        bindings[button]?[trigger.rawValue] ?? (trigger == .single ? .legacy : .none)
    }

    mutating func setAction(_ action: RemoteAction, for button: String, trigger: RemoteTrigger) {
        var perButton = bindings[button] ?? [:]
        perButton[trigger.rawValue] = action
        bindings[button] = perButton
    }

    static func standardProfile() -> RemoteProfile { RemoteProfile(name: "Default") }

    static func htpcProfile() -> RemoteProfile {
        let kodi = "/Applications/Kodi.app"
        let chrome = "/Applications/Google Chrome.app"
        var profile = RemoteProfile(name: "HTPC")

        profile.setAction(.ensureApplication(path: kodi, fullscreen: true, whenRunning: .legacy),
                          for: "menu", trigger: .single)
        profile.setAction(.ensureApplication(path: kodi, fullscreen: true, whenRunning: .none),
                          for: "tv", trigger: .single)
        profile.setAction(.ensureApplication(path: kodi, fullscreen: true, whenRunning: .mediaPlayPause),
                          for: "playPause", trigger: .single)
        // Push-to-talk semantics: hold toggles dictation on, release toggles it back off.
        profile.setAction(.none, for: "siri", trigger: .single)
        profile.setAction(.voiceInputStart, for: "siri", trigger: .hold)
        profile.setAction(.voiceInputStop, for: "siri", trigger: .release)
        profile.setAction(.toggleApplicationsV2(
            first: ApplicationTarget(path: kodi, launchIfNeeded: true, fullscreen: true),
            second: ApplicationTarget(path: chrome, launchIfNeeded: true, fullscreen: false)
        ), for: "tv", trigger: .double)
        return profile
    }
}

enum InputTiming {
    private static let doubleKey = "inputTiming.doubleClickInterval"
    private static let holdKey = "inputTiming.holdThreshold"
    private static let dragKey = "inputTiming.dragThreshold"

    static var doubleClickInterval: Double {
        get { value(for: doubleKey, defaultValue: 0.32) }
        set { UserDefaults.standard.set(clamp(newValue, 0.15, 0.80), forKey: doubleKey) }
    }
    static var holdThreshold: Double {
        get { value(for: holdKey, defaultValue: 0.55) }
        set { UserDefaults.standard.set(clamp(newValue, 0.20, 1.50), forKey: holdKey) }
    }
    static var dragThreshold: Double {
        get { value(for: dragKey, defaultValue: 0.42) }
        set { UserDefaults.standard.set(clamp(newValue, 0.15, 1.20), forKey: dragKey) }
    }

    private static func value(for key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.double(forKey: key)
    }
    private static func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        max(minValue, min(maxValue, value))
    }
}

/// Trackpad tuning is intentionally independent from profiles: it represents the physical remote.
enum TrackpadPreferences {
    private static let sensitivityKey = "trackpad.sensitivity"
    private static let smoothingKey = "trackpad.smoothing"
    private static let deadZoneKey = "trackpad.deadZone"
    private static let tapKey = "trackpad.tapToClick"
    private static let clickLockKey = "trackpad.clickLock"
    private static let naturalScrollKey = "trackpad.naturalScroll"

    static var sensitivity: Double {
        get { value(sensitivityKey, 1.0) }
        set { UserDefaults.standard.set(max(0.45, min(2.20, newValue)), forKey: sensitivityKey) }
    }
    static var smoothing: Double {
        get { value(smoothingKey, 0.38) }
        set { UserDefaults.standard.set(max(0.0, min(0.85, newValue)), forKey: smoothingKey) }
    }
    static var deadZone: Double {
        get { value(deadZoneKey, 0.0015) }
        set { UserDefaults.standard.set(max(0.0, min(0.010, newValue)), forKey: deadZoneKey) }
    }
    static var tapToClick: Bool {
        get { bool(tapKey, true) }
        set { UserDefaults.standard.set(newValue, forKey: tapKey) }
    }
    static var clickLock: Bool {
        get { bool(clickLockKey, true) }
        set { UserDefaults.standard.set(newValue, forKey: clickLockKey) }
    }
    static var naturalScroll: Bool {
        get { bool(naturalScrollKey, true) }
        set { UserDefaults.standard.set(newValue, forKey: naturalScrollKey) }
    }

    private static func value(_ key: String, _ defaultValue: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? defaultValue : UserDefaults.standard.double(forKey: key)
    }
    private static func bool(_ key: String, _ defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? defaultValue : UserDefaults.standard.bool(forKey: key)
    }
}

enum VoicePreferences {
    private static let enabledKey = "voice.enabled"
    private static let autoStartKey = "voice.autoStartBridge"
    private static let commandKey = "voice.bridgeCommand"
    private static let dictationKeyCodeKey = "voice.dictationKeyCode"
    private static let dictationFlagsKey = "voice.dictationFlags"
    private static let dictationDisplayKey = "voice.dictationDisplay"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var autoStartBridge: Bool {
        get { UserDefaults.standard.bool(forKey: autoStartKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoStartKey) }
    }
    static var bridgeCommand: String {
        get { UserDefaults.standard.string(forKey: commandKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: commandKey) }
    }
    static var dictationKeyCode: Int {
        get { UserDefaults.standard.object(forKey: dictationKeyCodeKey) == nil ? 49 : UserDefaults.standard.integer(forKey: dictationKeyCodeKey) }
        set { UserDefaults.standard.set(newValue, forKey: dictationKeyCodeKey) }
    }
    static var dictationFlags: UInt64 {
        get { UInt64(UserDefaults.standard.string(forKey: dictationFlagsKey) ?? "0", radix: 16) ?? 0 }
        set { UserDefaults.standard.set(String(newValue, radix: 16), forKey: dictationFlagsKey) }
    }
    static var dictationDisplay: String {
        get { UserDefaults.standard.string(forKey: dictationDisplayKey) ?? "Space" }
        set { UserDefaults.standard.set(newValue, forKey: dictationDisplayKey) }
    }
}

enum ProfileStorageWarning: Equatable {
    case unreadableData
    case unsupportedSchema(Int)
    case newerSchema(Int)

    var message: String {
        switch self {
        case .unreadableData:
            return "The saved profiles could not be read. Temporary defaults are shown, but the original data has not been replaced."
        case .unsupportedSchema(let version):
            return "The saved profiles use unsupported schema version \(version). Temporary defaults are shown, but the original data has not been replaced."
        case .newerSchema(let version):
            return "The saved profiles use schema version \(version), which is newer than this app supports. Temporary defaults are shown, but the original data has not been replaced."
        }
    }
}

private struct ProfileDocument: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profiles: [RemoteProfile]
}

private struct ProfileDocumentVersion: Decodable {
    var schemaVersion: Int
}

final class ProfileStore {
    // Keep this key and its bare [RemoteProfile] JSON representation stable. The schema version
    // lives beside it so rolling back to a previous build cannot destroy otherwise valid profiles.
    private let profilesKey = "remoteProfiles.v1"
    private let activeProfileKey = "remoteProfiles.activeProfileID"
    private let schemaVersionKey = "remoteProfiles.schemaVersion"
    private let recoveryPayloadKey = "remoteProfiles.v1.recovery"
    private let recoveryReasonKey = "remoteProfiles.v1.recoveryReason"
    private let recoveryDateKey = "remoteProfiles.v1.recoveryDate"
    private let recoverySchemaVersionKey = "remoteProfiles.v1.recoverySchemaVersion"
    private let recoveryActiveProfileKey = "remoteProfiles.v1.recoveryActiveProfileID"
    private let recoveryHistoryKey = "remoteProfiles.v1.recoveryHistory"
    private let migrationBackupKey = "remoteProfiles.v1.migrationBackup"
    private let preventMusicKey = "preventAppleMusicAutoLaunch"
    private let defaults: UserDefaults

    private(set) var profiles: [RemoteProfile] = []
    private(set) var activeProfileID: UUID
    private(set) var storageWarning: ProfileStorageWarning?
    var onProfilesWillChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onPreventMusicAutoLaunchChanged: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storageWarning = nil

        let storedValue = defaults.object(forKey: profilesKey)
        var loadedProfiles: [RemoteProfile]?
        let needsInitialSave = storedValue == nil
        var needsPrimaryRewrite = false
        var needsSchemaStamp = false

        if storedValue != nil, let rawVersion = defaults.object(forKey: schemaVersionKey) {
            if let number = rawVersion as? NSNumber {
                if number.intValue > ProfileDocument.currentSchemaVersion {
                    storageWarning = .newerSchema(number.intValue)
                } else if number.intValue < ProfileDocument.currentSchemaVersion {
                    storageWarning = .unsupportedSchema(number.intValue)
                }
            } else {
                storageWarning = .unreadableData
            }
        } else {
            needsSchemaStamp = storedValue != nil
        }

        if storageWarning == nil, let data = storedValue as? Data {
            do {
                let result = try Self.decodeProfiles(from: data)
                loadedProfiles = result.profiles
                needsPrimaryRewrite = result.needsPrimaryRewrite
            } catch ProfileDecodingError.newerSchema(let version) {
                storageWarning = .newerSchema(version)
            } catch ProfileDecodingError.unsupportedSchema(let version) {
                storageWarning = .unsupportedSchema(version)
            } catch {
                storageWarning = .unreadableData
            }
        } else if storageWarning == nil, storedValue != nil {
            storageWarning = .unreadableData
        }

        profiles = loadedProfiles ?? Self.defaultProfiles()
        if let raw = defaults.string(forKey: activeProfileKey),
           let id = UUID(uuidString: raw), profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        } else {
            activeProfileID = profiles.first?.id ?? UUID()
        }

        if let warning = storageWarning, let storedValue {
            preserveRecoveryCopy(
                storedValue,
                schemaVersion: defaults.object(forKey: schemaVersionKey),
                activeProfileID: defaults.string(forKey: activeProfileKey),
                reason: warning.message
            )
            print("Profile storage warning: \(warning.message)")
        } else if (needsPrimaryRewrite || needsSchemaStamp), let storedValue {
            defaults.set(storedValue, forKey: migrationBackupKey)
            if needsPrimaryRewrite {
                _ = persist(profiles: profiles, activeProfileID: activeProfileID)
            } else {
                defaults.set(ProfileDocument.currentSchemaVersion, forKey: schemaVersionKey)
                defaults.set(activeProfileID.uuidString, forKey: activeProfileKey)
            }
        } else if needsInitialSave {
            _ = persist(profiles: profiles, activeProfileID: activeProfileID)
        } else {
            defaults.set(activeProfileID.uuidString, forKey: activeProfileKey)
        }
    }

    var activeProfile: RemoteProfile { profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0] }

    var preventAppleMusicAutoLaunch: Bool {
        get { defaults.object(forKey: preventMusicKey) == nil ? true : defaults.bool(forKey: preventMusicKey) }
        set {
            defaults.set(newValue, forKey: preventMusicKey)
            onPreventMusicAutoLaunchChanged?(newValue)
            onChange?()
        }
    }

    func action(for button: String, trigger: RemoteTrigger) -> RemoteAction {
        guard storageWarning == nil else { return .none }
        return activeProfile.action(for: button, trigger: trigger)
    }
    func isLegacyPassthrough(_ button: String) -> Bool {
        action(for: button, trigger: .single) == .legacy &&
        action(for: button, trigger: .double).isNone &&
        action(for: button, trigger: .hold).isNone &&
        action(for: button, trigger: .release).isNone
    }
    func setActiveProfile(_ id: UUID) {
        guard storageWarning == nil, id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        guard persist(profiles: profiles, activeProfileID: id) else { return }
        onProfilesWillChange?()
        activeProfileID = id
        onChange?()
    }
    @discardableResult func addProfile(named name: String, duplicating source: RemoteProfile? = nil) -> UUID {
        guard storageWarning == nil else { return activeProfileID }
        var profile = source ?? RemoteProfile.standardProfile()
        profile.id = UUID()
        profile.name = name
        var updatedProfiles = profiles
        updatedProfiles.append(profile)
        guard persist(profiles: updatedProfiles, activeProfileID: activeProfileID) else { return activeProfileID }
        profiles = updatedProfiles
        onChange?()
        return profile.id
    }
    func removeProfile(_ id: UUID) {
        guard storageWarning == nil, profiles.count > 1 else { return }
        let updatedProfiles = profiles.filter { $0.id != id }
        let updatedActiveID = updatedProfiles.contains(where: { $0.id == activeProfileID }) ? activeProfileID : updatedProfiles[0].id
        guard persist(profiles: updatedProfiles, activeProfileID: updatedActiveID) else { return }
        if updatedActiveID != activeProfileID { onProfilesWillChange?() }
        profiles = updatedProfiles
        activeProfileID = updatedActiveID
        onChange?()
    }
    func renameProfile(_ id: UUID, to name: String) {
        guard storageWarning == nil, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var updatedProfiles = profiles
        updatedProfiles[index].name = name
        guard persist(profiles: updatedProfiles, activeProfileID: activeProfileID) else { return }
        profiles = updatedProfiles
        onChange?()
    }
    func setAction(_ action: RemoteAction, profileID: UUID, button: String, trigger: RemoteTrigger) {
        guard storageWarning == nil, let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard profiles[index].action(for: button, trigger: trigger) != action else { return }
        var updatedProfiles = profiles
        updatedProfiles[index].setAction(action, for: button, trigger: trigger)
        guard persist(profiles: updatedProfiles, activeProfileID: activeProfileID) else { return }
        if profileID == activeProfileID { onProfilesWillChange?() }
        profiles = updatedProfiles
        onChange?()
    }
    func profile(with id: UUID) -> RemoteProfile? { profiles.first(where: { $0.id == id }) }

    /// Replaces an unreadable/newer profile document only after explicit user confirmation.
    /// Recovery history remains available for diagnostics or a future migration tool.
    func replaceStoredProfilesWithDefaults() {
        guard storageWarning != nil else { return }
        let replacementProfiles = Self.defaultProfiles()
        let replacementActiveID = replacementProfiles[0].id
        guard persist(profiles: replacementProfiles, activeProfileID: replacementActiveID) else { return }
        onProfilesWillChange?()
        profiles = replacementProfiles
        activeProfileID = replacementActiveID
        storageWarning = nil
        onChange?()
    }

    @discardableResult
    private func persist(profiles: [RemoteProfile], activeProfileID: UUID) -> Bool {
        do {
            // The array representation is intentionally retained for rollback compatibility.
            let data = try JSONEncoder().encode(profiles)
            // Publish the version marker first. During a future schema upgrade, an older build
            // must fail closed even if the process exits before the matching payload is written.
            defaults.set(ProfileDocument.currentSchemaVersion, forKey: schemaVersionKey)
            defaults.set(data, forKey: profilesKey)
            defaults.set(activeProfileID.uuidString, forKey: activeProfileKey)
        } catch {
            print("Profile storage error: could not encode profiles: \(error.localizedDescription)")
            return false
        }
        return true
    }

    private func preserveRecoveryCopy(
        _ storedValue: Any,
        schemaVersion: Any?,
        activeProfileID: String?,
        reason: String
    ) {
        let date = Date()
        defaults.set(storedValue, forKey: recoveryPayloadKey)
        defaults.set(date, forKey: recoveryDateKey)
        defaults.set(reason, forKey: recoveryReasonKey)
        if let schemaVersion {
            defaults.set(schemaVersion, forKey: recoverySchemaVersionKey)
        } else {
            defaults.removeObject(forKey: recoverySchemaVersionKey)
        }
        if let activeProfileID {
            defaults.set(activeProfileID, forKey: recoveryActiveProfileKey)
        } else {
            defaults.removeObject(forKey: recoveryActiveProfileKey)
        }

        var history = defaults.array(forKey: recoveryHistoryKey) as? [[String: Any]] ?? []
        var incident: [String: Any] = [
            "payload": storedValue,
            "reason": reason,
            "date": date,
            "schemaVersionMissing": schemaVersion == nil,
            "activeProfileIDMissing": activeProfileID == nil,
        ]
        if let schemaVersion { incident["schemaVersion"] = schemaVersion }
        if let activeProfileID { incident["activeProfileID"] = activeProfileID }

        let repeatsLatestIncident: Bool
        if let previous = history.last {
            let samePayload = (previous["payload"] as? NSObject)?.isEqual(storedValue) == true
            let sameSchema = (previous["schemaVersion"] as? NSObject)?.isEqual(schemaVersion) == true ||
                (previous["schemaVersionMissing"] as? Bool == true && schemaVersion == nil)
            let sameActiveProfile = (previous["activeProfileID"] as? String) == activeProfileID &&
                (previous["activeProfileIDMissing"] as? Bool == (activeProfileID == nil))
            repeatsLatestIncident = samePayload && sameSchema && sameActiveProfile
        } else {
            repeatsLatestIncident = false
        }
        if !repeatsLatestIncident {
            history.append(incident)
        }
        if history.count > 5 { history.removeFirst(history.count - 5) }
        defaults.set(history, forKey: recoveryHistoryKey)
    }

    private static func defaultProfiles() -> [RemoteProfile] {
        [RemoteProfile.standardProfile(), RemoteProfile.htpcProfile()]
    }

    private enum ProfileDecodingError: Error {
        case emptyProfiles
        case unsupportedSchema(Int)
        case newerSchema(Int)
    }

    private static func decodeProfiles(from data: Data) throws -> (profiles: [RemoteProfile], needsPrimaryRewrite: Bool) {
        let decoder = JSONDecoder()

        if let legacyProfiles = try? decoder.decode([RemoteProfile].self, from: data) {
            guard !legacyProfiles.isEmpty else { throw ProfileDecodingError.emptyProfiles }
            return (legacyProfiles, false)
        }

        // A short-lived development build wrote an envelope. Accept it as a migration source,
        // then restore the rollback-compatible array representation.
        if let version = try? decoder.decode(ProfileDocumentVersion.self, from: data) {
            guard version.schemaVersion <= ProfileDocument.currentSchemaVersion else {
                throw ProfileDecodingError.newerSchema(version.schemaVersion)
            }
            guard version.schemaVersion == ProfileDocument.currentSchemaVersion else {
                throw ProfileDecodingError.unsupportedSchema(version.schemaVersion)
            }
            let document = try decoder.decode(ProfileDocument.self, from: data)
            guard !document.profiles.isEmpty else { throw ProfileDecodingError.emptyProfiles }
            return (document.profiles, true)
        }

        // Preserve the decoder's useful error for diagnostics rather than classifying a valid but
        // unsupported top-level object as an empty profile list.
        _ = try decoder.decode([RemoteProfile].self, from: data)
        throw ProfileDecodingError.emptyProfiles
    }
}
