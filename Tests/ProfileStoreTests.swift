import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.assertion(message) }
}

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "com.appletvremoterebinder.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure.assertion("Could not create isolated UserDefaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

private func encodedFutureDocument(version: Int, profiles: [RemoteProfile]) throws -> Data {
    let profilesData = try JSONEncoder().encode(profiles)
    let profilesObject = try JSONSerialization.jsonObject(with: profilesData)
    return try JSONSerialization.data(withJSONObject: [
        "schemaVersion": version,
        "profiles": profilesObject,
    ])
}

private func testFirstRunCreatesVersionedDocument() throws {
    try withDefaults { defaults in
        let store = ProfileStore(defaults: defaults)
        try expect(store.profiles.count == 2, "First run should create Default and HTPC profiles")
        try expect(store.activeProfile.name == "Default", "First run should activate the neutral Default profile")
        guard let firstRunData = defaults.data(forKey: "remoteProfiles.v1") else {
            throw TestFailure.assertion("First run should persist profiles")
        }
        try expect((try? JSONDecoder().decode([RemoteProfile].self, from: firstRunData)) != nil,
                   "Primary profile storage must retain the rollback-compatible array format")
        try expect(defaults.integer(forKey: "remoteProfiles.schemaVersion") == 1, "First run should persist schema version 1")

        let originalData = defaults.data(forKey: "remoteProfiles.v1")
        defaults.set(UUID().uuidString, forKey: "remoteProfiles.activeProfileID")
        let reloaded = ProfileStore(defaults: defaults)
        try expect(reloaded.activeProfileID == reloaded.profiles[0].id, "Invalid active profile ID was not repaired")
        try expect(defaults.data(forKey: "remoteProfiles.v1") == originalData, "Reloading current data should not rewrite the profile document")
    }
}

private func testLegacyMigrationPreservesMappingsAndActiveProfile() throws {
    try withDefaults { defaults in
        let chrome = "/Applications/Google Chrome.app"
        let profileID = UUID(uuidString: "9A7A31E0-6C58-4A32-A1D7-3C9C14958522")!
        var profile = RemoteProfile(id: profileID, name: "Living Room")
        profile.setAction(.toggleApplicationsV2(
            first: ApplicationTarget(path: "/Applications/Kodi.app", launchIfNeeded: true, fullscreen: true),
            second: ApplicationTarget(path: chrome, launchIfNeeded: true, fullscreen: false)
        ), for: "tv", trigger: .double)
        profile.setAction(.toggleApplications(
            firstPath: "/Applications/Kodi.app",
            secondPath: chrome,
            fullscreen: true
        ), for: "menu", trigger: .single)
        profile.setAction(.keyStroke(keyCode: 48, flags: 0x180000, display: "Command+Option+Tab"),
                          for: "playPause", trigger: .double)

        // Captured from the pre-envelope [RemoteProfile] encoder. Keep this literal so an
        // accidental wire-format change cannot update the fixture along with the implementation.
        let legacyFixtureBase64 = """
        W3siaWQiOiI5QTdBMzFFMC02QzU4LTRBMzItQTFENy0zQzlDMTQ5NTg1MjIiLCJuYW1lIjoiTGl2aW5nIFJvb20i
        LCJiaW5kaW5ncyI6eyJtZW51Ijp7InNpbmdsZSI6eyJ0b2dnbGVBcHBsaWNhdGlvbnMiOnsic2Vjb25kUGF0aCI6
        IlwvQXBwbGljYXRpb25zXC9Hb29nbGUgQ2hyb21lLmFwcCIsImZpcnN0UGF0aCI6IlwvQXBwbGljYXRpb25zXC9L
        b2RpLmFwcCIsImZ1bGxzY3JlZW4iOnRydWV9fX0sInR2Ijp7ImRvdWJsZSI6eyJ0b2dnbGVBcHBsaWNhdGlvbnNW
        MiI6eyJzZWNvbmQiOnsicGF0aCI6IlwvQXBwbGljYXRpb25zXC9Hb29nbGUgQ2hyb21lLmFwcCIsImxhdW5jaElm
        TmVlZGVkIjp0cnVlLCJmdWxsc2NyZWVuIjpmYWxzZX0sImZpcnN0Ijp7InBhdGgiOiJcL0FwcGxpY2F0aW9uc1wv
        S29kaS5hcHAiLCJsYXVuY2hJZk5lZWRlZCI6dHJ1ZSwiZnVsbHNjcmVlbiI6dHJ1ZX19fX0sInBsYXlQYXVzZSI6
        eyJkb3VibGUiOnsia2V5U3Ryb2tlIjp7ImRpc3BsYXkiOiJDb21tYW5kK09wdGlvbitUYWIiLCJrZXlDb2RlIjo0
        OCwiZmxhZ3MiOjE1NzI4NjR9fX19fV0=
        """
        guard let legacyData = Data(base64Encoded: legacyFixtureBase64, options: .ignoreUnknownCharacters) else {
            throw TestFailure.assertion("Historical profile fixture is invalid")
        }
        defaults.set(legacyData, forKey: "remoteProfiles.v1")
        defaults.set(profile.id.uuidString, forKey: "remoteProfiles.activeProfileID")
        defaults.set(Data("stale-migration-backup".utf8), forKey: "remoteProfiles.v1.migrationBackup")

        let migrated = ProfileStore(defaults: defaults)
        try expect(migrated.profiles == [profile], "Legacy migration changed profile contents")
        try expect(migrated.activeProfileID == profile.id, "Legacy migration lost the active profile")
        let expectedAction = RemoteAction.toggleApplicationsV2(
            first: ApplicationTarget(path: "/Applications/Kodi.app", launchIfNeeded: true, fullscreen: true),
            second: ApplicationTarget(path: chrome, launchIfNeeded: true, fullscreen: false)
        )
        try expect(migrated.action(for: "tv", trigger: .double) == expectedAction, "Legacy migration changed the selected Chrome path or per-app policy")
        try expect(migrated.action(for: "menu", trigger: .single) == .toggleApplications(
            firstPath: "/Applications/Kodi.app", secondPath: chrome, fullscreen: true
        ), "Legacy migration lost the original Toggle Applications action")
        try expect(migrated.action(for: "playPause", trigger: .double) == .keyStroke(
            keyCode: 48, flags: 0x180000, display: "Command+Option+Tab"
        ), "Legacy migration changed a manually built keyboard shortcut")
        try expect(defaults.data(forKey: "remoteProfiles.v1.migrationBackup") == legacyData, "Legacy payload should be backed up before migration")
        try expect(defaults.data(forKey: "remoteProfiles.v1") == legacyData, "Schema stamping should not rewrite historical profile bytes")

        let reloaded = ProfileStore(defaults: defaults)
        try expect(reloaded.profiles == [profile], "Versioned document did not reload after migration")
        try expect(reloaded.storageWarning == nil, "Valid migrated data produced a storage warning")
    }
}

private func testCorruptPayloadIsNotOverwritten() throws {
    try withDefaults { defaults in
        let corruptData = Data("{not-json".utf8)
        defaults.set(corruptData, forKey: "remoteProfiles.v1")

        let store = ProfileStore(defaults: defaults)
        try expect(store.storageWarning == .unreadableData, "Corrupt data should produce an unreadable-data warning")
        try expect(store.activeProfile.name == "Default", "Corrupt storage should use the neutral Default profile at runtime")
        try expect(store.action(for: "menu", trigger: .single) == .none, "Profile actions should fail closed while recovery is unresolved")
        try expect(defaults.data(forKey: "remoteProfiles.v1") == corruptData, "Corrupt primary payload was overwritten")
        try expect(defaults.data(forKey: "remoteProfiles.v1.recovery") == corruptData, "Corrupt payload did not get a recovery copy")

        let originalProfiles = store.profiles
        let originalActiveProfileID = store.activeProfileID
        store.renameProfile(store.activeProfileID, to: "Should Not Save")
        store.setAction(.system(.mute), profileID: store.activeProfileID, button: "menu", trigger: .single)
        _ = store.addProfile(named: "Should Not Save")
        store.setActiveProfile(store.profiles[1].id)
        store.removeProfile(store.profiles[1].id)
        try expect(store.profiles == originalProfiles, "Profile mutations should be blocked while recovery is unresolved")
        try expect(store.activeProfileID == originalActiveProfileID, "Active profile changed while recovery was unresolved")
        try expect(defaults.data(forKey: "remoteProfiles.v1") == corruptData, "A blocked mutation overwrote corrupt primary data")

        store.replaceStoredProfilesWithDefaults()
        try expect(store.storageWarning == nil, "Explicit replacement should clear the storage warning")
        try expect(defaults.data(forKey: "remoteProfiles.v1") != corruptData, "Explicit replacement did not write fresh defaults")
        try expect(defaults.data(forKey: "remoteProfiles.v1.recovery") == corruptData, "Explicit replacement removed the recovery payload")
        try expect(ProfileStore(defaults: defaults).activeProfile.name == "Default", "Explicit replacement did not create reloadable defaults")
    }
}

private func testRecoveryCopyTracksLatestIncident() throws {
    try withDefaults { defaults in
        let first = Data("first-corrupt-payload".utf8)
        defaults.set(first, forKey: "remoteProfiles.v1")
        _ = ProfileStore(defaults: defaults)
        try expect(defaults.data(forKey: "remoteProfiles.v1.recovery") == first, "First recovery payload was not saved")
        _ = ProfileStore(defaults: defaults)
        let repeatedHistory = defaults.array(forKey: "remoteProfiles.v1.recoveryHistory") as? [[String: Any]]
        try expect(repeatedHistory?.count == 1, "Restarting with the same incident should not duplicate recovery history")

        let second = Data("second-corrupt-payload".utf8)
        defaults.set(second, forKey: "remoteProfiles.v1")
        _ = ProfileStore(defaults: defaults)
        try expect(defaults.data(forKey: "remoteProfiles.v1.recovery") == second, "Recovery payload did not advance to the latest incident")
        let history = defaults.array(forKey: "remoteProfiles.v1.recoveryHistory") as? [[String: Any]]
        try expect(history?.count == 2, "Recovery history should retain both distinct incidents")
    }
}

private func testProfileChangeCallbacksAreScopedAndOrdered() throws {
    try withDefaults { defaults in
        let store = ProfileStore(defaults: defaults)
        let originalID = store.activeProfileID
        let htpcID = store.profiles.first(where: { $0.name == "HTPC" })!.id
        var events: [String] = []

        store.onProfilesWillChange = {
            events.append("will:\(store.activeProfileID.uuidString)")
        }
        store.onChange = {
            events.append("did:\(store.activeProfileID.uuidString)")
        }

        store.setActiveProfile(htpcID)
        try expect(events == ["will:\(originalID.uuidString)", "did:\(htpcID.uuidString)"],
                   "Profile callbacks did not bracket the in-memory active-profile change")

        events.removeAll()
        store.preventAppleMusicAutoLaunch.toggle()
        try expect(events == ["did:\(htpcID.uuidString)"],
                   "A media preference should not invalidate active input state")

        events.removeAll()
        store.setAction(.system(.mute), profileID: originalID, button: "menu", trigger: .single)
        try expect(events == ["did:\(htpcID.uuidString)"],
                   "Editing an inactive profile should not invalidate active input state")

        events.removeAll()
        store.setAction(.system(.mute), profileID: htpcID, button: "menu", trigger: .single)
        try expect(events == ["will:\(htpcID.uuidString)", "did:\(htpcID.uuidString)"],
                   "Editing the active profile should invalidate input before publishing the change")
    }
}

private func testPressOnlySequenceQuarantine() throws {
    var gate = PressOnlySequenceGate()
    let quietInterval = 0.75

    try expect(gate.shouldAccept(button: "menu", at: 0.00, duplicateInterval: 0.075, quietInterval: quietInterval),
               "Initial Menu press should be accepted")
    try expect(!gate.shouldAccept(button: "menu", at: 0.04, duplicateInterval: 0.075, quietInterval: quietInterval),
               "Mirrored Menu event should be deduplicated")

    gate.quarantineActiveSequences(at: 0.40, quietInterval: quietInterval)
    gate.clearAcceptedEvents()
    try expect(!gate.shouldAccept(button: "menu", at: 0.56, duplicateInterval: 0.075, quietInterval: quietInterval),
               "First inferred-hold repeat from the old profile should be quarantined")
    try expect(!gate.shouldAccept(button: "menu", at: 0.68, duplicateInterval: 0.075, quietInterval: quietInterval),
               "Later repeats should extend the quarantine")
    try expect(gate.shouldAccept(button: "menu", at: 1.44, duplicateInterval: 0.075, quietInterval: quietInterval),
               "A press after a full quiet interval should start a new sequence")

    gate.reset()
    try expect(gate.shouldAccept(button: "tv", at: 2.00, duplicateInterval: 0.075, quietInterval: quietInterval),
               "Reset should clear sequence state")
}

private func testFuturePayloadIsNotDowngraded() throws {
    try withDefaults { defaults in
        let futureProfile = RemoteProfile.standardProfile()
        let futureData = try JSONEncoder().encode([futureProfile])
        defaults.set(futureData, forKey: "remoteProfiles.v1")
        defaults.set(99, forKey: "remoteProfiles.schemaVersion")
        defaults.set(futureProfile.id.uuidString, forKey: "remoteProfiles.activeProfileID")

        let store = ProfileStore(defaults: defaults)
        try expect(store.storageWarning == .newerSchema(99), "Future schema should produce a newer-schema warning")
        try expect(defaults.data(forKey: "remoteProfiles.v1") == futureData, "Future payload was overwritten by this build")
        try expect(defaults.data(forKey: "remoteProfiles.v1.recovery") == futureData, "Future payload did not get a recovery copy")
        try expect(defaults.integer(forKey: "remoteProfiles.v1.recoverySchemaVersion") == 99,
                   "Future schema metadata was not included in recovery")
        try expect(defaults.string(forKey: "remoteProfiles.v1.recoveryActiveProfileID") == futureProfile.id.uuidString,
                   "Future active-profile metadata was not included in recovery")

        store.setAction(.system(.mute), profileID: store.activeProfileID, button: "menu", trigger: .single)
        try expect(defaults.data(forKey: "remoteProfiles.v1") == futureData, "A profile mutation downgraded future data")
    }
}

private func testUnsupportedOlderDocumentIsNotOverwritten() throws {
    try withDefaults { defaults in
        let olderData = try JSONEncoder().encode([RemoteProfile.standardProfile()])
        defaults.set(olderData, forKey: "remoteProfiles.v1")
        defaults.set(0, forKey: "remoteProfiles.schemaVersion")

        let store = ProfileStore(defaults: defaults)
        try expect(store.storageWarning == .unsupportedSchema(0), "Unknown older schema should require an explicit migration")
        try expect(defaults.data(forKey: "remoteProfiles.v1") == olderData, "Unknown older schema was overwritten")
        try expect(store.action(for: "menu", trigger: .single) == .none, "Unknown older schema should disable profile actions")
    }
}

private func testEnvelopeMigrationRestoresArrayFormat() throws {
    try withDefaults { defaults in
        var profile = RemoteProfile(name: "Envelope Profile")
        profile.setAction(.system(.mute), for: "menu", trigger: .single)
        let envelopeData = try encodedFutureDocument(version: 1, profiles: [profile])
        defaults.set(envelopeData, forKey: "remoteProfiles.v1")
        defaults.set(1, forKey: "remoteProfiles.schemaVersion")
        defaults.set(profile.id.uuidString, forKey: "remoteProfiles.activeProfileID")

        let store = ProfileStore(defaults: defaults)
        try expect(store.storageWarning == nil, "Current envelope should migrate without a warning")
        try expect(store.profiles == [profile], "Envelope migration changed profiles")
        let migratedData = defaults.data(forKey: "remoteProfiles.v1")!
        try expect((try? JSONDecoder().decode([RemoteProfile].self, from: migratedData)) == [profile],
                   "Envelope migration did not restore rollback-compatible array storage")
        try expect(defaults.data(forKey: "remoteProfiles.v1.migrationBackup") == envelopeData,
                   "Envelope migration did not preserve the source payload")
    }
}

private func testEmptyCurrentDocumentIsNotOverwritten() throws {
    try withDefaults { defaults in
        let emptyData = try JSONEncoder().encode([RemoteProfile]())
        defaults.set(emptyData, forKey: "remoteProfiles.v1")
        defaults.set(1, forKey: "remoteProfiles.schemaVersion")

        let store = ProfileStore(defaults: defaults)
        try expect(store.storageWarning == .unreadableData, "An empty current document should require recovery")
        try expect(defaults.data(forKey: "remoteProfiles.v1") == emptyData, "An empty current document was overwritten")
    }
}

@main
private enum ProfileStoreTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("first run", testFirstRunCreatesVersionedDocument),
            ("legacy migration", testLegacyMigrationPreservesMappingsAndActiveProfile),
            ("corrupt payload", testCorruptPayloadIsNotOverwritten),
            ("future payload", testFuturePayloadIsNotDowngraded),
            ("unsupported older payload", testUnsupportedOlderDocumentIsNotOverwritten),
            ("envelope migration", testEnvelopeMigrationRestoresArrayFormat),
            ("empty current payload", testEmptyCurrentDocumentIsNotOverwritten),
            ("recovery history", testRecoveryCopyTracksLatestIncident),
            ("profile change callbacks", testProfileChangeCallbacksAreScopedAndOrdered),
            ("press-only sequence quarantine", testPressOnlySequenceQuarantine),
        ]

        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
    }
}
