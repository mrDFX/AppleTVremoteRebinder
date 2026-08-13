//
//  RemoteActionExecutor.swift
//  AppleTVremoteRebinder
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

final class RemoteActionExecutor {
    private weak var menuBarManager: MenuBarManager?
    private let mediaController: MediaController
    weak var voiceController: VoiceInputController?
    weak var cursorController: CursorController?

    init(menuBarManager: MenuBarManager, mediaController: MediaController) {
        self.menuBarManager = menuBarManager
        self.mediaController = mediaController
    }

    func execute(_ action: RemoteAction, button: String) {
        DispatchQueue.main.async { [weak self] in self?.executeOnMain(action, button: button) }
    }

    private func executeOnMain(_ action: RemoteAction, button: String) {
        switch action {
        case .none: break
        case .legacy:
            guard let assigned = menuBarManager?.getMapping(for: button) else { return }
            menuBarManager?.executeAction(assigned.persisted)
        case .mediaPlayPause:
            mediaController.sendMediaKey(.playPause)
        case .system(let systemAction):
            executeSystem(systemAction)
        case .keyStroke(let keyCode, let flags, _):
            sendKey(keyCode, flags: CGEventFlags(rawValue: flags))
        case .launchApplication(let path, let fullscreen):
            activateApplication(target: ApplicationTarget(path: path, launchIfNeeded: true, fullscreen: fullscreen))
        case .ensureApplication(let path, let fullscreen, let whenRunning):
            if runningApplication(path: path) == nil {
                activateApplication(target: ApplicationTarget(path: path, launchIfNeeded: true, fullscreen: fullscreen))
            } else {
                executeRunningAction(whenRunning, button: button)
            }
        case .toggleApplications(let firstPath, let secondPath, let fullscreen):
            toggleApplications(first: ApplicationTarget(path: firstPath, launchIfNeeded: true, fullscreen: fullscreen),
                               second: ApplicationTarget(path: secondPath, launchIfNeeded: true, fullscreen: fullscreen))
        case .toggleApplicationsV2(let first, let second):
            toggleApplications(first: first, second: second)
        case .openURL(let raw):
            if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
        case .shellCommand(let command):
            runShell(command)
        case .voiceInput:
            voiceController?.toggleDictation()
        case .voiceInputStart:
            voiceController?.beginDictation()
        case .voiceInputStop:
            voiceController?.endDictation()
        }
    }

    private func executeSystem(_ action: SystemAction) {
        switch action {
        case .volumeUp: mediaController.sendMediaKey(.volumeUp)
        case .volumeDown: mediaController.sendMediaKey(.volumeDown)
        case .mute: mediaController.sendMediaKey(.mute)
        case .nextTrack: mediaController.sendMediaKey(.next)
        case .previousTrack: mediaController.sendMediaKey(.previous)
        case .escape: sendKey(kVK_Escape)
        case .returnKey: sendKey(kVK_Return)
        case .space: sendKey(kVK_Space)
        case .arrowUp: sendKey(kVK_UpArrow)
        case .arrowDown: sendKey(kVK_DownArrow)
        case .arrowLeft: sendKey(kVK_LeftArrow)
        case .arrowRight: sendKey(kVK_RightArrow)
        case .tab: sendKey(kVK_Tab)
        case .appSwitcher: sendKey(kVK_Tab, flags: .maskCommand)
        case .rightClick: cursorController?.performRightClick()
        }
    }

    private func executeRunningAction(_ action: RunningApplicationAction, button: String) {
        switch action {
        case .none: break
        case .legacy:
            guard let assigned = menuBarManager?.getMapping(for: button) else { return }
            menuBarManager?.executeAction(assigned.persisted)
        case .mediaPlayPause: mediaController.sendMediaKey(.playPause)
        case .escape: sendKey(kVK_Escape)
        case .space: sendKey(kVK_Space)
        }
    }

    private func runningApplication(path: String) -> NSRunningApplication? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == wanted }
    }

    private func activateApplication(target: ApplicationTarget) {
        if let running = runningApplication(path: target.path) {
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            if target.fullscreen { scheduleFullscreen(for: running) }
            return
        }
        guard target.launchIfNeeded else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: target.path)
        guard FileManager.default.fileExists(atPath: url.path) else { showMissingApplication(target.path); return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            if let error = error { print("⚠️ Failed to open \(target.path): \(error)"); return }
            guard target.fullscreen, let app = app else { return }
            DispatchQueue.main.async { self?.scheduleFullscreen(for: app) }
        }
    }

    private func toggleApplications(first: ApplicationTarget, second: ApplicationTarget) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL.path
        let firstPath = URL(fileURLWithPath: first.path).standardizedFileURL.path
        let secondPath = URL(fileURLWithPath: second.path).standardizedFileURL.path

        let target: ApplicationTarget
        if front == firstPath { target = second }
        else if front == secondPath { target = first }
        else if runningApplication(path: first.path) != nil { target = first }
        else if runningApplication(path: second.path) != nil { target = second }
        else { target = first }
        activateApplication(target: target)
    }

    private func scheduleFullscreen(for app: NSRunningApplication) {
        for delay in [0.10, 0.50, 1.20, 2.50] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.setFullscreen(pid: app.processIdentifier) }
        }
    }

    private static func setFullscreen(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let window = windows.first else { return }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, "AXFullScreen" as CFString, &settable) == .success, settable.boolValue else { return }
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); usleep(12000); up?.post(tap: .cghidEventTap)
    }

    private func runShell(_ command: String) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-lc", command]
            do { try process.run() } catch { print("⚠️ Shell action failed: \(error)") }
        }
    }

    private func showMissingApplication(_ path: String) {
        let alert = NSAlert(); alert.messageText = "Application Not Found"
        alert.informativeText = "The configured application no longer exists at:\n\(path)\n\nChoose another application in Settings."
        alert.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
