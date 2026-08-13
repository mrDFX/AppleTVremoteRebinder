//
//  SettingsWindowController.swift
//  AppleTVremoteRebinder
//
//  Native macOS settings UI for profiles, remote mappings, trackpad and voice/media.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

private final class BindingButton: NSButton {
    let buttonKey: String
    let trigger: RemoteTrigger
    init(buttonKey: String, trigger: RemoteTrigger) {
        self.buttonKey = buttonKey; self.trigger = trigger
        super.init(frame: .zero)
        bezelStyle = .rounded
        lineBreakMode = .byTruncatingTail
        alignment = .left
        imagePosition = .imageLeading
        controlSize = .large
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct RemoteButtonDescriptor {
    let key: String
    let title: String
    let symbol: String
    let subtitle: String
    let supportsRelease: Bool
    let inferredHold: Bool
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let profileStore: ProfileStore
    private let keyCapture = KeyCaptureController()
    private let onNotificationPreferencesChanged: () -> Void
    private var remoteStatus: RemoteStatus

    private let sectionControl = NSSegmentedControl(labels: ["Buttons", "Trackpad", "Media & Voice", "General"], trackingMode: .selectOne, target: nil, action: nil)
    private let contentHost = NSView()
    private let profileTable = NSTableView()
    private let profileNameField = NSTextField()
    private let activeBadge = NSTextField(labelWithString: "")
    private let makeActiveButton = NSButton(title: "Make Active", target: nil, action: nil)
    private let bindingsStack = NSStackView()
    private var selectedProfileID: UUID?
    private var toggleChooserTarget: ToggleChooserTarget?
    private var didPresentStorageWarning = false

    private let doubleSlider = NSSlider(value: InputTiming.doubleClickInterval, minValue: 0.15, maxValue: 0.80, target: nil, action: nil)
    private let holdSlider = NSSlider(value: InputTiming.holdThreshold, minValue: 0.20, maxValue: 1.50, target: nil, action: nil)
    private let dragSlider = NSSlider(value: InputTiming.dragThreshold, minValue: 0.15, maxValue: 1.20, target: nil, action: nil)
    private let sensitivitySlider = NSSlider(value: TrackpadPreferences.sensitivity, minValue: 0.45, maxValue: 2.20, target: nil, action: nil)
    private let smoothingSlider = NSSlider(value: TrackpadPreferences.smoothing, minValue: 0.0, maxValue: 0.85, target: nil, action: nil)
    private let tapCheckbox = NSButton(checkboxWithTitle: "Tap to click", target: nil, action: nil)
    private let clickLockCheckbox = NSButton(checkboxWithTitle: "Lock pointer while physically clicking", target: nil, action: nil)
    private let naturalScrollCheckbox = NSButton(checkboxWithTitle: "Natural two-finger scrolling", target: nil, action: nil)

    private let preventMusicCheckbox = NSButton(checkboxWithTitle: "Prevent Apple Music auto-launch from Siri Remote", target: nil, action: nil)
    private let voiceEnabledCheckbox = NSButton(checkboxWithTitle: "Enable Siri Remote microphone integration", target: nil, action: nil)
    private let voiceAutoStartCheckbox = NSButton(checkboxWithTitle: "Start voice bridge automatically", target: nil, action: nil)
    private let voiceCommandField = NSTextField()
    private let voiceShortcutButton = NSButton(title: "Set Dictation Shortcut…", target: nil, action: nil)
    private let remoteConnectionLabel = NSTextField(labelWithString: "Connection: Disconnected")
    private let remoteBatteryLabel = NSTextField(labelWithString: "Battery: —")
    private let remoteInterfacesLabel = NSTextField(labelWithString: "HID interfaces: 0")
    private let connectionNotificationCheckbox = NSButton(checkboxWithTitle: "Notify when the remote connects or disconnects", target: nil, action: nil)
    private let lowBatteryNotificationCheckbox = NSButton(checkboxWithTitle: "Notify when the remote battery is low", target: nil, action: nil)
    private let lowBatteryThresholdSlider = NSSlider(value: Double(RemoteNotificationPreferences.lowBatteryThreshold), minValue: 5, maxValue: 30, target: nil, action: nil)
    private let lowBatteryThresholdDetail = NSTextField(labelWithString: "")

    private let buttons: [RemoteButtonDescriptor] = [
        .init(key: "menu", title: "Menu", symbol: "chevron.backward.circle", subtitle: "Back / menu", supportsRelease: false, inferredHold: true),
        .init(key: "tv", title: "TV", symbol: "tv", subtitle: "TV / Home button", supportsRelease: false, inferredHold: true),
        .init(key: "siri", title: "Microphone", symbol: "mic", subtitle: "Siri / voice button", supportsRelease: true, inferredHold: false),
        .init(key: "playPause", title: "Play / Pause", symbol: "playpause", subtitle: "Media control", supportsRelease: true, inferredHold: false),
        .init(key: "volumeUp", title: "Volume +", symbol: "speaker.plus", subtitle: "Volume up", supportsRelease: true, inferredHold: false),
        .init(key: "volumeDown", title: "Volume −", symbol: "speaker.minus", subtitle: "Volume down", supportsRelease: true, inferredHold: false),
    ]

    init(
        profileStore: ProfileStore,
        remoteStatus: RemoteStatus = .disconnected,
        onNotificationPreferencesChanged: @escaping () -> Void = {}
    ) {
        self.profileStore = profileStore
        self.remoteStatus = remoteStatus
        self.onNotificationPreferencesChanged = onNotificationPreferencesChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "AppleTVremoteRebinder"
        window.subtitle = "Siri Remote"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 620)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        selectedProfileID = profileStore.activeProfileID
        buildChrome()
        reloadProfiles()
        showSection(0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        // The app normally runs as an accessory so it stays out of the Dock. While Settings
        // is open, temporarily become a regular app: this gives the window a Dock presence
        // and makes it reachable with Command-Tab like any other macOS settings window.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        presentStorageWarningIfNeeded()
    }

    private func presentStorageWarningIfNeeded() {
        guard !didPresentStorageWarning, let warning = profileStore.storageWarning, let window else { return }
        didPresentStorageWarning = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Saved Profiles Could Not Be Loaded"
        alert.informativeText = warning.message + " Profile editing is disabled. Keep the stored data for a newer app, or explicitly replace it with fresh defaults."
        alert.addButton(withTitle: "Keep Stored Data")
        let replaceButton = alert.addButton(withTitle: "Replace with Defaults")
        replaceButton.hasDestructiveAction = true
        DispatchQueue.main.async {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, let self else { return }
                self.profileStore.replaceStoredProfilesWithDefaults()
                self.selectedProfileID = self.profileStore.activeProfileID
                self.reloadProfiles()
                self.sectionControl.selectedSegment = 0
                self.showSection(0)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the menu-bar utility behavior once the only regular window is closed.
        if profileStore.storageWarning != nil { didPresentStorageWarning = false }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Layout

    private func buildChrome() {
        guard let root = window?.contentView else { return }
        let header = NSVisualEffectView(); header.material = .headerView; header.blendingMode = .withinWindow
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let title = NSTextField(labelWithString: "AppleTVremoteRebinder")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Siri Remote · profiles, buttons, trackpad and voice")
        subtitle.textColor = .secondaryLabelColor; subtitle.font = .systemFont(ofSize: 11)
        let titles = NSStackView(views: [title, subtitle]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 1
        titles.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(titles)

        sectionControl.selectedSegment = 0; sectionControl.target = self; sectionControl.action = #selector(sectionChanged)
        sectionControl.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(sectionControl)

        contentHost.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(contentHost)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 72),
            titles.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22), titles.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sectionControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22), sectionControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor), contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: header.bottomAnchor), contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    @objc private func sectionChanged() { showSection(sectionControl.selectedSegment) }

    private func showSection(_ index: Int) {
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch index {
        case 0: view = buildButtonsView()
        case 1: view = buildTrackpadView()
        case 2: view = buildMediaVoiceView()
        default: view = buildGeneralView()
        }
        view.translatesAutoresizingMaskIntoConstraints = false; contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor), view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
    }

    private func buildButtonsView() -> NSView {
        let root = NSView()

        // Sidebar: keep profile navigation visually and structurally separate from the editor.
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let sidebarTitle = NSTextField(labelWithString: "PROFILES")
        sidebarTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        sidebarTitle.textColor = .secondaryLabelColor
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarTitle)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        profileTable.headerView = nil
        profileTable.dataSource = self
        profileTable.delegate = self
        profileTable.rowHeight = 34
        profileTable.selectionHighlightStyle = .sourceList
        if profileTable.tableColumns.isEmpty {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
            col.width = 200
            profileTable.addTableColumn(col)
        }
        scroll.documentView = profileTable
        sidebar.addSubview(scroll)

        let add = iconButton("plus", #selector(addProfile), help: "New profile")
        let dup = iconButton("square.on.square", #selector(duplicateProfile), help: "Duplicate profile")
        let del = iconButton("trash", #selector(removeProfile), help: "Delete profile")
        let profileEditingEnabled = profileStore.storageWarning == nil
        add.isEnabled = profileEditingEnabled
        dup.isEnabled = profileEditingEnabled
        del.isEnabled = profileEditingEnabled
        let sidebarButtons = NSStackView(views: [add, dup, del])
        sidebarButtons.orientation = .horizontal
        sidebarButtons.spacing = 6
        sidebarButtons.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarButtons)

        // Detail is a flipped document view. A normal NSView as an NSScrollView document view
        // can anchor Auto Layout content from the bottom; that was the cause of the compressed,
        // overlapping mapping cards seen in the first UI build.
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(detailScroll)

        let detail = FlippedDocumentView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detail

        profileNameField.placeholderString = "Profile name"
        profileNameField.font = .systemFont(ofSize: 22, weight: .semibold)
        profileNameField.isBordered = false
        profileNameField.backgroundColor = .clear
        profileNameField.delegate = self
        profileNameField.isEnabled = profileEditingEnabled
        profileNameField.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(profileNameField)

        activeBadge.font = .systemFont(ofSize: 11, weight: .medium)
        activeBadge.textColor = .systemGreen
        activeBadge.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(activeBadge)

        makeActiveButton.target = self
        makeActiveButton.action = #selector(useSelectedProfile)
        makeActiveButton.bezelStyle = .rounded
        makeActiveButton.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(makeActiveButton)

        let intro = NSTextField(wrappingLabelWithString: "Choose what every physical Siri Remote button does. Each trigger is edited independently, so a single button can have different Press, Double Press, Hold and Release actions.")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 12)
        intro.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(intro)

        bindingsStack.orientation = .vertical
        bindingsStack.alignment = .width
        bindingsStack.distribution = .fill
        bindingsStack.spacing = 12
        bindingsStack.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(bindingsStack)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),

            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: sidebarButtons.topAnchor, constant: -8),
            sidebarButtons.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarButtons.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),

            detailScroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: root.topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Establish an actual scroll-document geometry. Width follows the clip view; height is
            // content-driven but may never be shorter than the visible viewport.
            detail.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detail.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            detail.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detail.heightAnchor.constraint(greaterThanOrEqualTo: detailScroll.contentView.heightAnchor),

            profileNameField.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 28),
            profileNameField.topAnchor.constraint(equalTo: detail.topAnchor, constant: 26),
            profileNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            profileNameField.trailingAnchor.constraint(lessThanOrEqualTo: makeActiveButton.leadingAnchor, constant: -20),

            makeActiveButton.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -28),
            makeActiveButton.centerYAnchor.constraint(equalTo: profileNameField.centerYAnchor),

            activeBadge.leadingAnchor.constraint(equalTo: profileNameField.leadingAnchor),
            activeBadge.topAnchor.constraint(equalTo: profileNameField.bottomAnchor, constant: 3),

            intro.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 28),
            intro.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -28),
            intro.topAnchor.constraint(equalTo: activeBadge.bottomAnchor, constant: 16),

            bindingsStack.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 28),
            bindingsStack.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -28),
            bindingsStack.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 20),
            bindingsStack.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -28),
        ])

        reloadSelectedProfile()
        return root
    }

    private func buildTrackpadView() -> NSView {
        let root = paddedScrollContent()
        let stack = root.stack
        stack.addArrangedSubview(sectionTitle("Trackpad Feel", subtitle: "Tune the Gen-1 touch surface for a TV-sized pointer target."))
        stack.addArrangedSubview(settingSlider("Pointer speed", detail: "Lower for precise UI targets, higher for crossing a TV quickly.", slider: sensitivitySlider, min: "Precise", max: "Fast", action: #selector(trackpadChanged)))
        stack.addArrangedSubview(settingSlider("Motion smoothing", detail: "Filters tiny finger jitter without adding a fixed delay.", slider: smoothingSlider, min: "Direct", max: "Smooth", action: #selector(trackpadChanged)))
        tapCheckbox.state = TrackpadPreferences.tapToClick ? .on : .off; tapCheckbox.target = self; tapCheckbox.action = #selector(trackpadChanged)
        clickLockCheckbox.state = TrackpadPreferences.clickLock ? .on : .off; clickLockCheckbox.target = self; clickLockCheckbox.action = #selector(trackpadChanged)
        naturalScrollCheckbox.state = TrackpadPreferences.naturalScroll ? .on : .off; naturalScrollCheckbox.target = self; naturalScrollCheckbox.action = #selector(trackpadChanged)
        stack.addArrangedSubview(preferenceCard("Clicking", views: [tapCheckbox, clickLockCheckbox, naturalScrollCheckbox], note: "Pointer lock is the important TV-mode fix: physical pressure no longer nudges the pointer off the button you intended to click."))
        stack.addArrangedSubview(sectionTitle("Timing", subtitle: "Shared gesture thresholds."))
        stack.addArrangedSubview(settingSlider("Double press", detail: String(format: "%.0f ms", InputTiming.doubleClickInterval * 1000), slider: doubleSlider, min: "150 ms", max: "800 ms", action: #selector(timingChanged)))
        stack.addArrangedSubview(settingSlider("Hold", detail: String(format: "%.0f ms", InputTiming.holdThreshold * 1000), slider: holdSlider, min: "200 ms", max: "1.5 s", action: #selector(timingChanged)))
        stack.addArrangedSubview(settingSlider("Physical click → drag", detail: String(format: "%.0f ms", InputTiming.dragThreshold * 1000), slider: dragSlider, min: "150 ms", max: "1.2 s", action: #selector(timingChanged)))
        return root.root
    }

    private func buildMediaVoiceView() -> NSView {
        let root = paddedScrollContent(); let stack = root.stack
        stack.addArrangedSubview(sectionTitle("Media", subtitle: "System media handling and Apple Music protection."))
        preventMusicCheckbox.state = profileStore.preventAppleMusicAutoLaunch ? .on : .off; preventMusicCheckbox.target = self; preventMusicCheckbox.action = #selector(preventMusicChanged)
        stack.addArrangedSubview(preferenceCard("Media daemon", views: [preventMusicCheckbox], note: "Remote-origin AVRCP events are suppressed while normal keyboard media keys continue to work."))

        stack.addArrangedSubview(sectionTitle("Siri Remote Microphone", subtitle: "Gen-1 microphone support through an external decoder/virtual-audio bridge."))
        voiceEnabledCheckbox.state = VoicePreferences.enabled ? .on : .off; voiceEnabledCheckbox.target = self; voiceEnabledCheckbox.action = #selector(voiceChanged)
        voiceAutoStartCheckbox.state = VoicePreferences.autoStartBridge ? .on : .off; voiceAutoStartCheckbox.target = self; voiceAutoStartCheckbox.action = #selector(voiceChanged)
        voiceCommandField.placeholderString = "Bridge command (PacketLogger | SiriRemoteVoiceControl …)"; voiceCommandField.stringValue = VoicePreferences.bridgeCommand
        voiceCommandField.target = self; voiceCommandField.action = #selector(voiceChanged)
        voiceShortcutButton.target = self; voiceShortcutButton.action = #selector(setVoiceShortcut)
        let status = NSTextField(wrappingLabelWithString: "Use the “Siri Remote Voice Input” action on the Microphone button. The bridge command is intentionally configurable so PacketLogger/SiriRemoteVoiceControl, BlackHole or another decoder can be swapped without rebuilding this app.")
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(preferenceCard("Voice bridge", views: [voiceEnabledCheckbox, voiceAutoStartCheckbox, voiceCommandField, voiceShortcutButton], note: status.stringValue))
        return root.root
    }

    private func buildGeneralView() -> NSView {
        let root = paddedScrollContent()
        let stack = root.stack
        stack.addArrangedSubview(sectionTitle("Remote Status", subtitle: "Live connection and battery information from the Siri Remote HID interfaces."))
        updateRemoteStatusLabels()
        stack.addArrangedSubview(preferenceCard(
            "Siri Remote",
            views: [remoteConnectionLabel, remoteBatteryLabel, remoteInterfacesLabel],
            note: "Battery is shown when the connected remote exposes a supported HID battery value."
        ))

        stack.addArrangedSubview(sectionTitle("Notifications", subtitle: "Connection alerts are debounced during quick Bluetooth re-enumeration."))
        connectionNotificationCheckbox.state = RemoteNotificationPreferences.connectionEnabled ? .on : .off
        connectionNotificationCheckbox.target = self
        connectionNotificationCheckbox.action = #selector(notificationPreferencesChanged)
        lowBatteryNotificationCheckbox.state = RemoteNotificationPreferences.lowBatteryEnabled ? .on : .off
        lowBatteryNotificationCheckbox.target = self
        lowBatteryNotificationCheckbox.action = #selector(notificationPreferencesChanged)
        stack.addArrangedSubview(preferenceCard(
            "Remote alerts",
            views: [connectionNotificationCheckbox, lowBatteryNotificationCheckbox],
            note: "macOS asks for notification permission when either alert is enabled."
        ))

        lowBatteryThresholdSlider.doubleValue = Double(RemoteNotificationPreferences.lowBatteryThreshold)
        lowBatteryThresholdSlider.isEnabled = RemoteNotificationPreferences.lowBatteryEnabled
        lowBatteryThresholdSlider.numberOfTickMarks = 6
        lowBatteryThresholdSlider.allowsTickMarkValuesOnly = true
        stack.addArrangedSubview(settingSlider(
            "Low battery threshold",
            detail: "Notify at \(RemoteNotificationPreferences.lowBatteryThreshold)% or below.",
            slider: lowBatteryThresholdSlider,
            min: "5%",
            max: "30%",
            action: #selector(notificationPreferencesChanged),
            detailField: lowBatteryThresholdDetail
        ))
        return root.root
    }

    func updateRemoteStatus(_ status: RemoteStatus) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateRemoteStatus(status) }
            return
        }
        remoteStatus = status
        updateRemoteStatusLabels()
    }

    private func updateRemoteStatusLabels() {
        remoteConnectionLabel.stringValue = remoteStatus.isConnected
            ? "Connection: Connected"
            : "Connection: Disconnected"
        if remoteStatus.isConnected, let battery = remoteStatus.batteryPercent {
            remoteBatteryLabel.stringValue = "Battery: \(battery)%"
        } else if remoteStatus.isConnected {
            remoteBatteryLabel.stringValue = "Battery: Unavailable"
        } else {
            remoteBatteryLabel.stringValue = "Battery: —"
        }
        remoteInterfacesLabel.stringValue = "HID interfaces: \(remoteStatus.interfaceCount)"
    }

    // MARK: profile rows

    private func reloadProfiles() {
        profileTable.reloadData()
        if let id = selectedProfileID, let row = profileStore.profiles.firstIndex(where: { $0.id == id }) { profileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    private func reloadSelectedProfile() {
        guard let id = selectedProfileID, let profile = profileStore.profile(with: id) else { return }
        profileNameField.stringValue = profile.name
        let isActive = id == profileStore.activeProfileID
        let profileEditingEnabled = profileStore.storageWarning == nil
        profileNameField.isEnabled = profileEditingEnabled
        activeBadge.stringValue = isActive ? "● Active profile" : ""
        makeActiveButton.title = isActive ? "Active" : "Make Active"
        makeActiveButton.isEnabled = profileEditingEnabled && !isActive
        bindingsStack.arrangedSubviews.forEach { bindingsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for descriptor in buttons { bindingsStack.addArrangedSubview(bindingCard(descriptor, profile: profile)) }
    }

    private func bindingCard(_ descriptor: RemoteButtonDescriptor, profile: RemoteProfile) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: descriptor.symbol, accessibilityDescription: descriptor.title) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: descriptor.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitle = NSTextField(labelWithString: descriptor.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let identity = NSStackView(views: [icon, labels])
        identity.orientation = .horizontal
        identity.spacing = 10
        identity.alignment = .centerY

        let triggerStack = NSStackView()
        triggerStack.orientation = .vertical
        triggerStack.alignment = .leading
        triggerStack.spacing = 7

        for trigger in RemoteTrigger.allCases {
            let triggerTitle: String
            switch trigger {
            case .single: triggerTitle = "Press"
            case .double: triggerTitle = "Double Press"
            case .hold: triggerTitle = descriptor.inferredHold ? "Hold  *" : "Hold"
            case .release: triggerTitle = "Release"
            }

            let triggerLabel = NSTextField(labelWithString: triggerTitle)
            triggerLabel.font = .systemFont(ofSize: 11, weight: .medium)
            triggerLabel.textColor = .secondaryLabelColor
            triggerLabel.alignment = .right
            triggerLabel.translatesAutoresizingMaskIntoConstraints = false
            triggerLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let b = BindingButton(buttonKey: descriptor.key, trigger: trigger)
            b.controlSize = .regular
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
            let action = profile.action(for: descriptor.key, trigger: trigger)
            b.title = action.summary
            b.image = NSImage(systemSymbolName: symbolFor(action), accessibilityDescription: nil)
            b.target = self
            b.action = #selector(editBinding(_:))
            b.isEnabled = profileStore.storageWarning == nil
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            if trigger == .release && !descriptor.supportsRelease {
                b.isEnabled = false
                b.title = "Not exposed by macOS"
                b.image = NSImage(systemSymbolName: "nosign", accessibilityDescription: nil)
            }
            if trigger == .hold && descriptor.inferredHold {
                b.toolTip = "For Menu/TV, Hold is inferred from repeated HID events because macOS may not expose a normal release event."
            }

            let row = NSStackView(views: [triggerLabel, b])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            triggerStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: triggerStack.widthAnchor).isActive = true
        }

        let holdNote: NSTextField?
        if descriptor.inferredHold {
            let note = NSTextField(wrappingLabelWithString: "* Hold on this button is inferred from repeat events and can depend on remote firmware/macOS.")
            note.font = .systemFont(ofSize: 10)
            note.textColor = .tertiaryLabelColor
            holdNote = note
        } else {
            holdNote = nil
        }

        var arranged: [NSView] = [identity, NSBox.separator(), triggerStack]
        if let holdNote { arranged.append(holdNote) }
        let content = NSStackView(views: arranged)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = .init(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            triggerStack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        return card
    }

    private func symbolFor(_ action: RemoteAction) -> String {
        switch action {
        case .none: return "minus.circle"
        case .legacy: return "arrow.uturn.backward"
        case .mediaPlayPause: return "playpause"
        case .system(let s):
            switch s { case .volumeUp: return "speaker.plus"; case .volumeDown: return "speaker.minus"; case .mute: return "speaker.slash"; case .rightClick: return "cursorarrow.click.2"; default: return "command" }
        case .keyStroke: return "keyboard"
        case .launchApplication, .ensureApplication: return "app"
        case .toggleApplications, .toggleApplicationsV2: return "arrow.left.arrow.right"
        case .openURL: return "link"
        case .shellCommand: return "terminal"
        case .voiceInput, .voiceInputStart: return "mic.fill"
        case .voiceInputStop: return "mic.slash"
        }
    }

    // MARK: actions

    @objc private func editBinding(_ sender: BindingButton) {
        guard selectedProfileID != nil else { return }
        let menu = NSMenu()
        addActionItem("None", kind: "none", symbol: "minus.circle", to: menu, sender: sender)
        addActionItem("Current Button Mapping", kind: "legacy", symbol: "arrow.uturn.backward", to: menu, sender: sender)
        menu.addItem(.separator())

        let system = NSMenuItem(title: "System & Media", action: nil, keyEquivalent: ""); system.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        let systemMenu = NSMenu()
        addSystemAction(.volumeUp, to: systemMenu, sender: sender); addSystemAction(.volumeDown, to: systemMenu, sender: sender); addSystemAction(.mute, to: systemMenu, sender: sender)
        systemMenu.addItem(.separator()); addActionItem("Media Play/Pause", kind: "media", symbol: "playpause", to: systemMenu, sender: sender)
        addSystemAction(.nextTrack, to: systemMenu, sender: sender); addSystemAction(.previousTrack, to: systemMenu, sender: sender)
        systemMenu.addItem(.separator()); for a in [SystemAction.escape, .returnKey, .space, .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .appSwitcher, .rightClick] { addSystemAction(a, to: systemMenu, sender: sender) }
        system.submenu = systemMenu; menu.addItem(system)

        let apps = NSMenuItem(title: "Applications", action: nil, keyEquivalent: ""); apps.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        let appMenu = NSMenu(); addActionItem("Open / Activate Application…", kind: "app", symbol: "app", to: appMenu, sender: sender); addActionItem("Ensure Application Running…", kind: "ensure", symbol: "bolt", to: appMenu, sender: sender); addActionItem("Toggle Two Applications…", kind: "toggle", symbol: "arrow.left.arrow.right", to: appMenu, sender: sender); apps.submenu = appMenu; menu.addItem(apps)

        let keyboard = NSMenuItem(title: "Keyboard", action: nil, keyEquivalent: ""); keyboard.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        let keyMenu = NSMenu(); addActionItem("Capture Shortcut…", kind: "key", symbol: "record.circle", to: keyMenu, sender: sender); addActionItem("Build Shortcut…", kind: "manualKey", symbol: "keyboard.badge.ellipsis", to: keyMenu, sender: sender); keyboard.submenu = keyMenu; menu.addItem(keyboard)

        menu.addItem(.separator())
        let voice = NSMenuItem(title: "Voice Input", action: nil, keyEquivalent: ""); voice.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        let voiceMenu = NSMenu(); addActionItem("Toggle Voice Input", kind: "voice", symbol: "mic", to: voiceMenu, sender: sender); addActionItem("Start Voice Input", kind: "voiceStart", symbol: "mic.fill", to: voiceMenu, sender: sender); addActionItem("Stop Voice Input", kind: "voiceStop", symbol: "mic.slash", to: voiceMenu, sender: sender); voice.submenu = voiceMenu; menu.addItem(voice)
        addActionItem("Open URL…", kind: "url", symbol: "link", to: menu, sender: sender)
        addActionItem("Run Shell Command…", kind: "shell", symbol: "terminal", to: menu, sender: sender)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    private func addActionItem(_ title: String, kind: String, symbol: String, to menu: NSMenu, sender: BindingButton) {
        let item = NSMenuItem(title: title, action: #selector(actionMenuSelected(_:)), keyEquivalent: ""); item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.representedObject = ["kind": kind, "button": sender.buttonKey, "trigger": sender.trigger.rawValue]; menu.addItem(item)
    }

    private func addSystemAction(_ action: SystemAction, to menu: NSMenu, sender: BindingButton) {
        let item = NSMenuItem(title: action.title, action: #selector(actionMenuSelected(_:)), keyEquivalent: ""); item.target = self
        item.representedObject = ["kind": "system:\(action.rawValue)", "button": sender.buttonKey, "trigger": sender.trigger.rawValue]; menu.addItem(item)
    }

    @objc private func actionMenuSelected(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String], let kind = payload["kind"], let button = payload["button"], let raw = payload["trigger"], let trigger = RemoteTrigger(rawValue: raw), let profileID = selectedProfileID else { return }
        if kind.hasPrefix("system:"), let sys = SystemAction(rawValue: String(kind.dropFirst(7))) { set(.system(sys), profileID, button, trigger); return }
        switch kind {
        case "none": set(.none, profileID, button, trigger)
        case "legacy": set(.legacy, profileID, button, trigger)
        case "media": set(.mediaPlayPause, profileID, button, trigger)
        case "voice": set(.voiceInput, profileID, button, trigger)
        case "voiceStart": set(.voiceInputStart, profileID, button, trigger)
        case "voiceStop": set(.voiceInputStop, profileID, button, trigger)
        case "app": editApplicationAction(profileID, button, trigger, ensure: false)
        case "ensure": editApplicationAction(profileID, button, trigger, ensure: true)
        case "toggle": editToggleAction(profileID, button, trigger)
        case "key": keyCapture.begin(forButtonLabel: "\(button) · \(trigger.title)") { [weak self] c in guard let self = self, let c = c else { return }; self.set(.keyStroke(keyCode: c.keyCode, flags: c.flags.rawValue, display: c.display), profileID, button, trigger) }
        case "manualKey": if let c = manualShortcut() { set(.keyStroke(keyCode: c.keyCode, flags: c.flags.rawValue, display: c.display), profileID, button, trigger) }
        case "url": if let v = promptText("Open URL", "Enter URL", "https://") { set(.openURL(v), profileID, button, trigger) }
        case "shell": if let v = promptText("Shell Command", "Runs with /bin/zsh -lc", "") { set(.shellCommand(v), profileID, button, trigger) }
        default: break
        }
    }

    private func editApplicationAction(_ profileID: UUID, _ button: String, _ trigger: RemoteTrigger, ensure: Bool) {
        let existing = profileStore.profile(with: profileID)?.action(for: button, trigger: trigger)
        var initialPath = ""
        if case .launchApplication(let p, _) = existing { initialPath = p }
        if case .ensureApplication(let p, _, _) = existing { initialPath = p }
        chooseApplication(initialPath: initialPath) { [weak self] path in
            guard let self = self, let path = path else { return }
            let options = self.applicationOptions(title: ensure ? "Ensure Application" : "Open Application", defaultFullscreen: ensure)
            guard let options = options else { return }
            if ensure { self.set(.ensureApplication(path: path, fullscreen: options.fullscreen, whenRunning: options.whenRunning), profileID, button, trigger) }
            else { self.set(.launchApplication(path: path, fullscreen: options.fullscreen), profileID, button, trigger) }
        }
    }

    private func editToggleAction(_ profileID: UUID, _ button: String, _ trigger: RemoteTrigger) {
        let existing = profileStore.profile(with: profileID)?.action(for: button, trigger: trigger)
        var first = ApplicationTarget(path: "/Applications/Kodi.app", launchIfNeeded: true, fullscreen: true)
        var second = ApplicationTarget(path: "/Applications/Google Chrome.app", launchIfNeeded: true, fullscreen: false)
        if case .toggleApplicationsV2(let a, let b) = existing { first = a; second = b }
        if case .toggleApplications(let a, let b, let fs) = existing { first = .init(path: a, launchIfNeeded: true, fullscreen: fs); second = .init(path: b, launchIfNeeded: true, fullscreen: fs) }
        guard let result = toggleEditor(first: first, second: second) else { return }
        set(.toggleApplicationsV2(first: result.0, second: result.1), profileID, button, trigger)
    }

    private func toggleEditor(first: ApplicationTarget, second: ApplicationTarget) -> (ApplicationTarget, ApplicationTarget)? {
        let alert = NSAlert(); alert.messageText = "Toggle Two Applications"; alert.informativeText = "Each app keeps its own launch and fullscreen policy. Existing paths are preserved until you change them."
        let firstField = NSTextField(string: first.path); let secondField = NSTextField(string: second.path)
        let firstLaunch = NSButton(checkboxWithTitle: "Launch if needed", target: nil, action: nil); firstLaunch.state = first.launchIfNeeded ? .on : .off
        let firstFS = NSButton(checkboxWithTitle: "Full screen", target: nil, action: nil); firstFS.state = first.fullscreen ? .on : .off
        let secondLaunch = NSButton(checkboxWithTitle: "Launch if needed", target: nil, action: nil); secondLaunch.state = second.launchIfNeeded ? .on : .off
        let secondFS = NSButton(checkboxWithTitle: "Full screen", target: nil, action: nil); secondFS.state = second.fullscreen ? .on : .off
        let choose1 = NSButton(title: "Choose…", target: nil, action: nil); let choose2 = NSButton(title: "Choose…", target: nil, action: nil)
        let chooser = ToggleChooserTarget(firstField: firstField, secondField: secondField); toggleChooserTarget = chooser; choose1.target = chooser; choose1.action = #selector(ToggleChooserTarget.chooseFirst); choose2.target = chooser; choose2.action = #selector(ToggleChooserTarget.chooseSecond)
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8
        stack.addArrangedSubview(labeledRow("App A", field: firstField, button: choose1)); stack.addArrangedSubview(NSStackView(views: [firstLaunch, firstFS])); stack.addArrangedSubview(NSBox.separator())
        stack.addArrangedSubview(labeledRow("App B", field: secondField, button: choose2)); stack.addArrangedSubview(NSStackView(views: [secondLaunch, secondFS])); stack.frame.size = NSSize(width: 560, height: 150)
        alert.accessoryView = stack; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { toggleChooserTarget = nil; return nil }
        toggleChooserTarget = nil
        return (.init(path: firstField.stringValue, launchIfNeeded: firstLaunch.state == .on, fullscreen: firstFS.state == .on), .init(path: secondField.stringValue, launchIfNeeded: secondLaunch.state == .on, fullscreen: secondFS.state == .on))
    }

    private func manualShortcut() -> CapturedKey? {
        let alert = NSAlert(); alert.messageText = "Build Keyboard Shortcut"; alert.informativeText = "Useful for shortcuts macOS steals while you try to capture them, such as ⌘⌥Tab."
        let control = NSButton(checkboxWithTitle: "Control ⌃", target: nil, action: nil); let option = NSButton(checkboxWithTitle: "Option ⌥", target: nil, action: nil); let shift = NSButton(checkboxWithTitle: "Shift ⇧", target: nil, action: nil); let command = NSButton(checkboxWithTitle: "Command ⌘", target: nil, action: nil)
        let popup = NSPopUpButton(); let keys: [(String, Int)] = [("Tab", kVK_Tab), ("Space", kVK_Space), ("Return", kVK_Return), ("Escape", kVK_Escape), ("Left", kVK_LeftArrow), ("Right", kVK_RightArrow), ("Up", kVK_UpArrow), ("Down", kVK_DownArrow), ("A", kVK_ANSI_A), ("C", kVK_ANSI_C), ("F", kVK_ANSI_F), ("K", kVK_ANSI_K), ("M", kVK_ANSI_M), ("P", kVK_ANSI_P), ("W", kVK_ANSI_W)]
        keys.forEach { popup.addItem(withTitle: $0.0) }
        let mods = NSStackView(views: [control, option, shift, command]); mods.orientation = .horizontal; mods.spacing = 12
        let stack = NSStackView(views: [mods, popup]); stack.orientation = .vertical; stack.spacing = 10; stack.frame.size = NSSize(width: 430, height: 70); alert.accessoryView = stack
        alert.addButton(withTitle: "Use"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var flags: CGEventFlags = []; var display = ""
        if control.state == .on { flags.insert(.maskControl); display += "⌃" }; if option.state == .on { flags.insert(.maskAlternate); display += "⌥" }; if shift.state == .on { flags.insert(.maskShift); display += "⇧" }; if command.state == .on { flags.insert(.maskCommand); display += "⌘" }
        let idx = max(0, popup.indexOfSelectedItem); display += keys[idx].0
        return CapturedKey(keyCode: keys[idx].1, flags: flags, display: display)
    }

    // MARK: controls / data source

    func numberOfRows(in tableView: NSTableView) -> Int { profileStore.profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = profileStore.profiles[row]; let id = NSUserInterfaceItemIdentifier("profileCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView(); cell.identifier = id
        let label = cell.textField ?? NSTextField(labelWithString: ""); label.stringValue = p.name + (p.id == profileStore.activeProfileID ? "   ✓" : ""); label.font = .systemFont(ofSize: 13); cell.textField = label
        if label.superview == nil { label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]) }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { let r = profileTable.selectedRow; guard r >= 0 && r < profileStore.profiles.count else { return }; selectedProfileID = profileStore.profiles[r].id; reloadSelectedProfile() }
    func controlTextDidEndEditing(_ obj: Notification) { guard let id = selectedProfileID else { return }; let n = profileNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if !n.isEmpty { profileStore.renameProfile(id, to: n); reloadProfiles() } }

    @objc private func addProfile() { selectedProfileID = profileStore.addProfile(named: "New Profile"); reloadProfiles(); reloadSelectedProfile() }
    @objc private func duplicateProfile() { guard let id = selectedProfileID, let p = profileStore.profile(with: id) else { return }; selectedProfileID = profileStore.addProfile(named: p.name + " Copy", duplicating: p); reloadProfiles(); reloadSelectedProfile() }
    @objc private func removeProfile() { guard let id = selectedProfileID else { return }; profileStore.removeProfile(id); selectedProfileID = profileStore.activeProfileID; reloadProfiles(); reloadSelectedProfile() }
    @objc private func useSelectedProfile() { guard let id = selectedProfileID else { return }; profileStore.setActiveProfile(id); reloadProfiles(); reloadSelectedProfile() }

    @objc private func timingChanged(_ sender: NSSlider) { if sender === doubleSlider { InputTiming.doubleClickInterval = sender.doubleValue }; if sender === holdSlider { InputTiming.holdThreshold = sender.doubleValue }; if sender === dragSlider { InputTiming.dragThreshold = sender.doubleValue }; showSection(1) }
    @objc private func trackpadChanged(_ sender: Any) { TrackpadPreferences.sensitivity = sensitivitySlider.doubleValue; TrackpadPreferences.smoothing = smoothingSlider.doubleValue; TrackpadPreferences.tapToClick = tapCheckbox.state == .on; TrackpadPreferences.clickLock = clickLockCheckbox.state == .on; TrackpadPreferences.naturalScroll = naturalScrollCheckbox.state == .on }
    @objc private func preventMusicChanged(_ sender: NSButton) { profileStore.preventAppleMusicAutoLaunch = sender.state == .on }
    @objc private func voiceChanged(_ sender: Any) { VoicePreferences.enabled = voiceEnabledCheckbox.state == .on; VoicePreferences.autoStartBridge = voiceAutoStartCheckbox.state == .on; VoicePreferences.bridgeCommand = voiceCommandField.stringValue }
    @objc private func setVoiceShortcut() { if let c = manualShortcut() { VoicePreferences.dictationKeyCode = c.keyCode; VoicePreferences.dictationFlags = c.flags.rawValue; VoicePreferences.dictationDisplay = c.display; voiceShortcutButton.title = "Dictation: \(c.display)" } }
    @objc private func notificationPreferencesChanged(_ sender: Any) {
        RemoteNotificationPreferences.connectionEnabled = connectionNotificationCheckbox.state == .on
        RemoteNotificationPreferences.lowBatteryEnabled = lowBatteryNotificationCheckbox.state == .on
        RemoteNotificationPreferences.lowBatteryThreshold = Int(lowBatteryThresholdSlider.doubleValue.rounded())
        lowBatteryThresholdSlider.isEnabled = RemoteNotificationPreferences.lowBatteryEnabled
        lowBatteryThresholdDetail.stringValue = "Notify at \(RemoteNotificationPreferences.lowBatteryThreshold)% or below."
        onNotificationPreferencesChanged()
    }

    private func set(_ action: RemoteAction, _ profileID: UUID, _ button: String, _ trigger: RemoteTrigger) { profileStore.setAction(action, profileID: profileID, button: button, trigger: trigger); reloadSelectedProfile() }

    // MARK: UI helpers
    private func iconButton(_ symbol: String, _ action: Selector, help: String) -> NSButton { let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: self, action: action); b.bezelStyle = .texturedRounded; b.toolTip = help; return b }
    private func sectionTitle(_ title: String, subtitle: String) -> NSView { let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 20, weight: .semibold); let s = NSTextField(wrappingLabelWithString: subtitle); s.textColor = .secondaryLabelColor; let v = NSStackView(views: [t,s]); v.orientation = .vertical; v.alignment = .leading; v.spacing = 3; return v }
    private func preferenceCard(_ title: String, views: [NSView], note: String) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 10; box.borderColor = .separatorColor; box.fillColor = .controlBackgroundColor
        let h = NSTextField(labelWithString: title); h.font = .systemFont(ofSize: 13, weight: .semibold)
        let n = NSTextField(wrappingLabelWithString: note); n.textColor = .secondaryLabelColor
        let st = NSStackView(views: [h] + views + [n]); st.orientation = .vertical; st.alignment = .leading; st.spacing = 8; st.edgeInsets = .init(top: 12, left: 14, bottom: 12, right: 14)
        st.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(st)
        NSLayoutConstraint.activate([st.leadingAnchor.constraint(equalTo: box.leadingAnchor), st.trailingAnchor.constraint(equalTo: box.trailingAnchor), st.topAnchor.constraint(equalTo: box.topAnchor), st.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(78 + views.count * 28)).isActive = true
        return box
    }
    private func settingSlider(
        _ title: String,
        detail: String,
        slider: NSSlider,
        min: String,
        max: String,
        action: Selector,
        detailField: NSTextField? = nil
    ) -> NSView {
        slider.target = self; slider.action = action
        let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 13, weight: .medium)
        let d = detailField ?? NSTextField(labelWithString: detail)
        d.stringValue = detail
        d.textColor = .secondaryLabelColor
        let l = NSTextField(labelWithString: min); l.textColor = .tertiaryLabelColor
        let r = NSTextField(labelWithString: max); r.textColor = .tertiaryLabelColor
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let ends = NSStackView(views: [l, spacer, r]); ends.orientation = .horizontal
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 10; box.borderColor = .separatorColor; box.fillColor = .controlBackgroundColor
        let st = NSStackView(views: [t,d,slider,ends]); st.orientation = .vertical; st.spacing = 6; st.edgeInsets = .init(top: 12, left: 14, bottom: 12, right: 14)
        st.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(st)
        NSLayoutConstraint.activate([st.leadingAnchor.constraint(equalTo: box.leadingAnchor), st.trailingAnchor.constraint(equalTo: box.trailingAnchor), st.topAnchor.constraint(equalTo: box.topAnchor), st.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
        return box
    }
    private func paddedScrollContent() -> (root: NSView, stack: NSStackView) {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let content = FlippedDocumentView(); content.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .vertical)
        content.addSubview(stack); scroll.documentView = content

        // Keep short sections packed at the top. The old required bottom equality stretched the
        // stack to the viewport height, and NSStackView then distributed that extra space between
        // cards (the large blank areas visible in Trackpad and Media & Voice). A high-priority
        // bottom preference gives us natural content height while still allowing the document view
        // to be at least as tall as the viewport.
        let preferredBottom = stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28)
        preferredBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            preferredBottom,
        ])
        return (scroll, stack)
    }
    private func labeledRow(_ title: String, field: NSTextField, button: NSButton) -> NSView { let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 50).isActive = true; field.widthAnchor.constraint(equalToConstant: 370).isActive = true; let row = NSStackView(views: [label, field, button]); row.orientation = .horizontal; row.spacing = 8; return row }
    private func chooseApplication(initialPath: String = "", completion: @escaping (String?) -> Void) { let panel = NSOpenPanel(); panel.title = "Choose Application"; panel.prompt = "Choose"; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; if !initialPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: initialPath).deletingLastPathComponent() } else { panel.directoryURL = URL(fileURLWithPath: "/Applications") }; panel.allowedFileTypes = ["app"]; panel.begin { completion($0 == .OK ? panel.url?.path : nil) } }
    private func applicationOptions(title: String, defaultFullscreen: Bool) -> (fullscreen: Bool, whenRunning: RunningApplicationAction)? { let alert = NSAlert(); alert.messageText = title; let fs = NSButton(checkboxWithTitle: "Use full screen", target: nil, action: nil); fs.state = defaultFullscreen ? .on : .off; let pop = NSPopUpButton(); RunningApplicationAction.allCases.forEach { pop.addItem(withTitle: $0.title) }; pop.selectItem(at: RunningApplicationAction.allCases.firstIndex(of: .mediaPlayPause) ?? 0); let st = NSStackView(views: [fs, NSTextField(labelWithString: "When already running:"), pop]); st.orientation = .vertical; st.spacing = 8; alert.accessoryView = st; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return nil }; return (fs.state == .on, RunningApplicationAction.allCases[max(0,pop.indexOfSelectedItem)]) }
    private func promptText(_ title: String, _ message: String, _ initial: String) -> String? { let a = NSAlert(); a.messageText = title; a.informativeText = message; let f = NSTextField(frame: NSRect(x:0,y:0,width:420,height:24)); f.stringValue = initial; a.accessoryView = f; a.addButton(withTitle:"Use"); a.addButton(withTitle:"Cancel"); guard a.runModal() == .alertFirstButtonReturn else { return nil }; let v=f.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); return v.isEmpty ? nil : v }
}

private final class ToggleChooserTarget: NSObject {
    let firstField: NSTextField; let secondField: NSTextField
    init(firstField: NSTextField, secondField: NSTextField) { self.firstField = firstField; self.secondField = secondField }
    @objc func chooseFirst() { choose(into: firstField) }
    @objc func chooseSecond() { choose(into: secondField) }
    private func choose(into field: NSTextField) { let p = NSOpenPanel(); p.canChooseDirectories=false; p.canChooseFiles=true; p.allowedFileTypes=["app"]; p.directoryURL=URL(fileURLWithPath: field.stringValue.isEmpty ? "/Applications" : field.stringValue).deletingLastPathComponent(); if p.runModal() == .OK, let u=p.url { field.stringValue=u.path } }
}

private extension NSBox {
    static func separator() -> NSBox { let b = NSBox(); b.boxType = .separator; return b }
}
