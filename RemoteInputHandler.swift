//
//  RemoteInputHandler.swift
//  AppleTVremoteRebinder
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit

class RemoteInputHandler {
    private let cursorController: CursorController
    private weak var menuBarManager: MenuBarManager?
    private let profileStore: ProfileStore
    private let actionExecutor: RemoteActionExecutor
    private var devices: [IOHIDDevice] = []
    
    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    /// Auto-repeat timers for hold-to-repeat actions (scroll/volume), keyed by button.
    private var repeatTimers: [String: Timer] = [:]

    // Multi-press state.
    private var pendingSingle: [String: DispatchWorkItem] = [:]
    private var pendingHold: [String: DispatchWorkItem] = [:]
    private var holdTriggered: Set<String> = []
    private var profileGeneration = 0
    private var profilePressGeneration: [String: Int] = [:]
    private var pressOnlySequenceGate = PressOnlySequenceGate()
    private var pressOnlySequenceStart: [String: UInt64] = [:]
    private var pressOnlyHoldFired: Set<String> = []

    // Click/drag state
    private var physicalClickSession = PhysicalClickSession()
    private var selectDragWorkItem: DispatchWorkItem?
    private var clickThreshold: Double { InputTiming.dragThreshold }
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    private static func elapsedSeconds(since start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        var info = mach_timebase_info_data_t(numer: 1, denom: 1)
        mach_timebase_info(&info)
        let delta = mach_absolute_time() &- start
        return Double(delta) * Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }

    /// Virtual keys currently held down, keyed by the HID button that initiated the hold.
    /// Captured at press time so release can fire the correct keyUp even if the user
    /// rebinds the button mid-hold. Cleared on device removal to avoid stuck modifiers.
    private var heldKeys: [String: (keyCode: Int, flags: CGEventFlags)] = [:]

    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    
    init(cursorController: CursorController,
         menuBarManager: MenuBarManager,
         profileStore: ProfileStore,
         actionExecutor: RemoteActionExecutor) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
        self.profileStore = profileStore
        self.actionExecutor = actionExecutor
    }
    
    @discardableResult
    func attachRemoteInterface(_ device: IOHIDDevice, startsSession: Bool) -> Bool {
        if startsSession {
            // A new physical session must never inherit stale devices, held keys, or mouse state.
            disconnectAllRemoteInterfaces()
        }
        guard !devices.contains(where: { $0 == device }) else { return true }
        
        // Seize device to prevent system from handling events
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if openResult == kIOReturnSuccess {
            rmDebug(String(format: "🔒 SEIZED HID device (vendor=0x%X product=0x%X)",
                  IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0,
                  IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0))
            IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            devices.append(device)
            return true
        } else {
            rmDebug(String(format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized", openResult))
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                devices.append(device)
                return true
            }
        }
        return false
    }

    func detachRemoteInterface(_ device: IOHIDDevice, endsSession: Bool) {
        guard let index = devices.firstIndex(where: { $0 == device }) else { return }
        closeRemoteInterface(devices.remove(at: index))

        // The removed interface may be the only one that emits a matching key/select release.
        // Close transient state immediately, but keep every surviving HID handle attached.
        completeTriggeredReleaseActions()
        releaseAllHeldKeys()
        cancelPhysicalClick()
        if endsSession {
            disconnectAllRemoteInterfaces()
        }
    }

    func disconnectAllRemoteInterfaces() {
        for device in devices { closeRemoteInterface(device) }
        devices.removeAll()
        completeTriggeredReleaseActions()
        releaseAllHeldKeys()
        cancelPhysicalClick()
    }

    private func closeRemoteInterface(_ device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let identified = identifyButton(page: usagePage, usage: usage)
        rmDebug(String(format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
                       usagePage, usage, intValue, identified ?? "<unmapped>"))
        guard let buttonName = identified else { return }

        onButtonActivity?()

        // Collapse mirrored-interface duplicates. Menu/TV on Gen 1 often do not expose a
        // reliable release event, but a long physical press can produce repeat key-downs.
        // Keep those repeats: they are the only signal we can use to infer Hold.
        let isPressed = (intValue == 1)
        if buttonName == "menu" || buttonName == "tv" {
            guard isPressed else { return }
            guard pressOnlySequenceGate.shouldAccept(
                button: buttonName,
                at: ProcessInfo.processInfo.systemUptime,
                duplicateInterval: 0.075,
                quietInterval: pressOnlySequenceQuietInterval
            ) else { return }
        } else {
            if buttonState[buttonName] == isPressed { return }
            buttonState[buttonName] = isPressed
        }

        let assigned = menuBarManager?.getMapping(for: buttonName) ?? .builtin(.none)

        // Volume keys on the Siri Remote also travel over BT AVRCP absolute-volume, which
        // coreaudiod honors below cghidEventTap. Arm the revert guard on every press so the
        // CoreAudio listener snaps the level back to the pre-press value.
        if isPressed && (buttonName == "volumeUp" || buttonName == "volumeDown") {
            VolumeRevertGuard.shared.armFromRemoteButton()
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }

        let pressed = (intValue == 1)

        // Debounce only on press — release just closes an existing hold.
        if pressed {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        if profileStore.isLegacyPassthrough(buttonName) {
            if pressed { print("🔘 Button pressed: \(buttonName) → \(assigned.persisted)") }
            executeAction(assigned, button: buttonName, pressed: pressed)
        } else if buttonName == "menu" || buttonName == "tv" {
            handlePressOnlyProfileInput(button: buttonName)
        } else {
            handleProfileInput(button: buttonName, pressed: pressed)
        }
    }

    // MARK: - Profiles / multi-press

    /// Invalidates gestures that began under an older profile or while profile storage was
    /// unavailable. In particular, a key-up after recovery must not become a fresh Press action.
    func prepareForProfileChange() {
        profileGeneration &+= 1

        // Complete lifecycle actions from the old profile before it is replaced. This is required
        // for mappings such as Voice Start on Hold + Voice Stop on Release.
        completeTriggeredReleaseActions()
        pressOnlySequenceGate.quarantineActiveSequences(
            at: ProcessInfo.processInfo.systemUptime,
            quietInterval: pressOnlySequenceQuietInterval
        )
        releaseAllHeldKeys(resetPhysicalButtonState: false)
    }

    private var pressOnlySequenceQuietInterval: TimeInterval {
        max(InputTiming.holdThreshold, InputTiming.doubleClickInterval) + 0.20
    }

    /// Menu/TV have no trustworthy release event on some Gen-1 firmware/macOS combinations.
    /// We still support Hold opportunistically: a sustained press usually emits repeated key-down
    /// events. If no repeats arrive, Hold is physically indistinguishable from a single press and
    /// the single action wins after the configured threshold.
    private func handlePressOnlyProfileInput(button: String) {
        let now = mach_absolute_time()
        let holdAction = profileStore.action(for: button, trigger: .hold)
        let doubleAction = profileStore.action(for: button, trigger: .double)
        let singleAction = profileStore.action(for: button, trigger: .single)

        if let start = pressOnlySequenceStart[button] {
            let elapsed = Self.elapsedSeconds(since: start)
            if !holdAction.isNone && elapsed >= InputTiming.holdThreshold && elapsed < 2.0 {
                pendingSingle.removeValue(forKey: button)?.cancel()
                if !pressOnlyHoldFired.contains(button) {
                    pressOnlyHoldFired.insert(button)
                    actionExecutor.execute(holdAction, button: button)
                }
                return
            }
            if !doubleAction.isNone && elapsed <= InputTiming.doubleClickInterval {
                pendingSingle.removeValue(forKey: button)?.cancel()
                pressOnlySequenceStart.removeValue(forKey: button)
                pressOnlyHoldFired.remove(button)
                actionExecutor.execute(doubleAction, button: button)
                return
            }
            // A new physical press after the gesture window starts a new sequence.
            if elapsed > max(InputTiming.holdThreshold, InputTiming.doubleClickInterval) + 0.20 {
                pressOnlySequenceStart[button] = now
                pressOnlyHoldFired.remove(button)
            }
        } else {
            pressOnlySequenceStart[button] = now
            pressOnlyHoldFired.remove(button)
        }

        guard !singleAction.isNone else { return }
        pendingSingle.removeValue(forKey: button)?.cancel()
        let delay: Double
        if !holdAction.isNone { delay = max(InputTiming.holdThreshold, InputTiming.doubleClickInterval) }
        else if !doubleAction.isNone { delay = InputTiming.doubleClickInterval }
        else { delay = 0 }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingSingle.removeValue(forKey: button)
            self.pressOnlySequenceStart.removeValue(forKey: button)
            self.pressOnlyHoldFired.remove(button)
            self.actionExecutor.execute(singleAction, button: button)
        }
        pendingSingle[button] = work
        if delay == 0 { DispatchQueue.main.async(execute: work) }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    private func handleProfileInput(button: String, pressed: Bool) {
        if !holdCapableButtons.contains(button) {
            guard pressed else { return }
            processTap(button)
            return
        }

        if pressed {
            profilePressGeneration[button] = profileGeneration
            holdTriggered.remove(button)
            pendingHold[button]?.cancel()

            let holdAction = profileStore.action(for: button, trigger: .hold)
            if !holdAction.isNone {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.holdTriggered.insert(button)
                    self.actionExecutor.execute(holdAction, button: button)
                }
                pendingHold[button] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + InputTiming.holdThreshold, execute: work)
            }
        } else {
            pendingHold.removeValue(forKey: button)?.cancel()
            guard profilePressGeneration.removeValue(forKey: button) == profileGeneration else {
                holdTriggered.remove(button)
                return
            }

            if holdTriggered.remove(button) != nil {
                let releaseAction = profileStore.action(for: button, trigger: .release)
                if !releaseAction.isNone {
                    actionExecutor.execute(releaseAction, button: button)
                }
                return
            }

            processTap(button)
            let releaseAction = profileStore.action(for: button, trigger: .release)
            if !releaseAction.isNone {
                actionExecutor.execute(releaseAction, button: button)
            }
        }
    }

    private func processTap(_ button: String) {
        let doubleAction = profileStore.action(for: button, trigger: .double)

        if let first = pendingSingle.removeValue(forKey: button) {
            first.cancel()
            if !doubleAction.isNone {
                actionExecutor.execute(doubleAction, button: button)
            }
            return
        }

        let singleAction = profileStore.action(for: button, trigger: .single)
        guard !singleAction.isNone else { return }

        // No double-click mapping means no artificial latency on the common single-press path.
        if doubleAction.isNone {
            actionExecutor.execute(singleAction, button: button)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingSingle.removeValue(forKey: button)
            self.actionExecutor.execute(singleAction, button: button)
        }
        pendingSingle[button] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + InputTiming.doubleClickInterval, execute: work)
    }

    private func cancelPendingProfileActions() {
        for (_, work) in pendingSingle { work.cancel() }
        for (_, work) in pendingHold { work.cancel() }
        pendingSingle.removeAll()
        pendingHold.removeAll()
        holdTriggered.removeAll()
        pressOnlySequenceStart.removeAll()
        pressOnlyHoldFired.removeAll()
        profilePressGeneration.removeAll()
    }

    private func completeTriggeredReleaseActions() {
        let triggeredButtons = holdTriggered
        holdTriggered.removeAll()
        for button in triggeredButtons {
            let releaseAction = profileStore.action(for: button, trigger: .release)
            if !releaseAction.isNone {
                actionExecutor.execute(releaseAction, button: button)
            }
        }
    }
    
    private func handleSelectButton(pressed: Bool) {
        let effects = pressed ? physicalClickSession.press() : physicalClickSession.release()
        applyPhysicalClickEffects(effects)
    }

    private func dragThresholdReached(token: UInt64) {
        let effects = physicalClickSession.dragThresholdReached(token: token)
        if !effects.isEmpty { selectDragWorkItem = nil }
        applyPhysicalClickEffects(effects)
    }

    private func applyPhysicalClickEffects(_ effects: [PhysicalClickSession.Effect]) {
        for effect in effects {
            switch effect {
            case .begin(let token):
                selectDragWorkItem?.cancel()
                // Anchor immediately so pressure-induced touch movement cannot move the target.
                cursorController.beginPhysicalClick()
                let work = DispatchWorkItem { [weak self] in
                    self?.dragThresholdReached(token: token)
                }
                selectDragWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold, execute: work)
            case .startDrag:
                print("🔘 Select button: Drag started")
                cursorController.beginDrag()
            case .finishClick:
                selectDragWorkItem?.cancel()
                selectDragWorkItem = nil
                print("🔘 Select button: Click")
                cursorController.endPhysicalClick()
            case .finishDrag:
                selectDragWorkItem?.cancel()
                selectDragWorkItem = nil
                print("🔘 Select button: Drag ended")
                cursorController.endPhysicalClick()
            case .cancelPending, .cancelDrag:
                selectDragWorkItem?.cancel()
                selectDragWorkItem = nil
                cursorController.cancelPhysicalClick()
            }
        }
    }

    private func cancelPhysicalClick() {
        selectDragWorkItem?.cancel()
        selectDragWorkItem = nil
        let effects = physicalClickSession.cancel()
        applyPhysicalClickEffects(effects)
        // Defensive cleanup for any state created by an older app build or compatibility call.
        if effects.isEmpty { cursorController.cancelPhysicalClick() }
    }
    
    // MARK: - Button Identification
    
    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)  
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    // MARK: - Action Execution
    
    private func executeAction(_ assigned: AssignedAction, button: String, pressed: Bool) {
        switch assigned {
        case .customKey(let keyCode, let flags, _):
            // On hold-capable buttons, mirror the physical press duration (push-to-talk
            // style — a dictation app's hold-hotkey sees the real hold). Tap elsewhere.
            if holdCapableButtons.contains(button) {
                if pressed {
                    if let stale = heldKeys.removeValue(forKey: button) {
                        postKey(keyCode: stale.keyCode, flags: [], keyDown: false)
                    }
                    postKey(keyCode: keyCode, flags: flags, keyDown: true)
                    heldKeys[button] = (keyCode, flags)
                } else if let held = heldKeys.removeValue(forKey: button) {
                    postKey(keyCode: held.keyCode, flags: [], keyDown: false)
                }
                return
            }
            guard pressed else { return }
            sendKey(keyCode, flags: flags)
        case .builtin(let action):
            if action.requiresHold {
                handleHoldAction(action, button: button, pressed: pressed)
                return
            }
            if action.repeatsWhileHeld {
                handleRepeatAction(action, button: button, pressed: pressed)
                return
            }
            // Tap actions fire once, on press only.
            guard pressed else { return }
            switch action {
            case .none:
                break
            case .enterKey:
                sendKey(kVK_Return)
            case .upKey:
                sendKey(kVK_UpArrow)
            case .downKey:
                sendKey(kVK_DownArrow)
            case .escKey:
                sendKey(kVK_Escape)
            case .ctrlC:
                sendKey(kVK_ANSI_C, flags: .maskControl)
            case .mediaPlayPause:
                actionExecutor.execute(.mediaPlayPause, button: button)
            case .spaceKey, .rightCmd, .rightOpt:
                break // handled by handleHoldAction
            case .scrollUp, .scrollDown:
                break // handled by handleRepeatAction
            case .trackpadClick:
                cursorController.performClick()
            }
        }
    }

    /// Scroll/volume actions: fire once on press, then auto-repeat while held
    /// (hold-capable buttons only — tap-only buttons get the single step).
    private func handleRepeatAction(_ action: ButtonAction, button: String, pressed: Bool) {
        let perform: () -> Void
        switch action {
        case .scrollUp:         perform = { MenuBarManager.postScroll(lines: 3) }
        case .scrollDown:       perform = { MenuBarManager.postScroll(lines: -3) }
        default: return
        }

        if pressed {
            perform()
            if holdCapableButtons.contains(button) {
                repeatTimers[button]?.invalidate()
                let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in perform() }
                RunLoop.main.add(timer, forMode: .common)
                repeatTimers[button] = timer
            }
        } else {
            repeatTimers.removeValue(forKey: button)?.invalidate()
        }
    }

    /// Press/release a virtual key mirroring the HID press duration (push-to-talk).
    private func handleHoldAction(_ action: ButtonAction, button: String, pressed: Bool) {
        let spec: (keyCode: Int, flags: CGEventFlags)
        switch action {
        case .spaceKey: spec = (kVK_Space,        [])
        case .rightCmd: spec = (kVK_RightCommand, .maskCommand)
        case .rightOpt: spec = (kVK_RightOption,  .maskAlternate)
        default: return
        }

        if pressed {
            // Defensive: if a prior release was missed, close the stale hold before opening a new one.
            if let stale = heldKeys.removeValue(forKey: button) {
                postKey(keyCode: stale.keyCode, flags: [], keyDown: false)
            }
            postKey(keyCode: spec.keyCode, flags: spec.flags, keyDown: true)
            heldKeys[button] = spec
        } else {
            guard let held = heldKeys.removeValue(forKey: button) else { return }
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
    }

    /// Called on device removal to avoid stuck modifiers if the remote disconnects mid-hold.
    private func releaseAllHeldKeys(resetPhysicalButtonState: Bool = true) {
        for (_, held) in heldKeys {
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
        heldKeys.removeAll()
        if resetPhysicalButtonState {
            buttonState.removeAll()
            pressOnlySequenceGate.reset()
        } else {
            pressOnlySequenceGate.clearAcceptedEvents()
        }
        for (_, timer) in repeatTimers { timer.invalidate() }
        repeatTimers.removeAll()
        cancelPendingProfileActions()
    }

    private func postKey(keyCode: Int, flags: CGEventFlags, keyDown: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        postKey(keyCode: keyCode, flags: flags, keyDown: true)
        usleep(10000)
        postKey(keyCode: keyCode, flags: flags, keyDown: false)
    }
}

// C callback
private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}
