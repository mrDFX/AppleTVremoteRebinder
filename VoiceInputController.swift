//
//  VoiceInputController.swift
//  AppleTVremoteRebinder
//
//  First-class integration point for the Gen-1 Siri Remote microphone.
//  The decoder/virtual-audio transport remains external because macOS protects the HID BLE
//  service. Jack-R1/SiriRemoteVoiceControl + PacketLogger is supported through bridgeCommand.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

final class VoiceInputController {
    private var bridgeProcess: Process?
    private(set) var bridgeRunning = false { didSet { onStatusChanged?(bridgeRunning) } }
    private var dictationActive = false
    var onStatusChanged: ((Bool) -> Void)?

    func startIfConfigured() {
        guard VoicePreferences.enabled, VoicePreferences.autoStartBridge else { return }
        startBridge()
    }

    func startBridge() {
        guard !bridgeRunning else { return }
        let command = VoicePreferences.bridgeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.bridgeProcess = nil
                self?.bridgeRunning = false
            }
        }
        do {
            try process.run()
            bridgeProcess = process
            bridgeRunning = true
        } catch {
            print("⚠️ Voice bridge failed to start: \(error)")
            bridgeRunning = false
        }
    }

    func stopBridge() {
        bridgeProcess?.terminate()
        bridgeProcess = nil
        bridgeRunning = false
    }

    /// Toggle the user's configured macOS dictation/PTT shortcut. The audio source is supplied by
    /// the configured voice bridge / virtual audio device, so the Siri Remote microphone can be
    /// used without hard-coding a particular dictation application.
    func toggleDictation() {
        if dictationActive { endDictation() } else { beginDictation() }
    }

    func beginDictation() {
        guard !dictationActive else { return }
        if VoicePreferences.enabled && !bridgeRunning && !VoicePreferences.bridgeCommand.isEmpty { startBridge() }
        sendConfiguredShortcut()
        dictationActive = true
    }

    func endDictation() {
        guard dictationActive else { return }
        sendConfiguredShortcut()
        dictationActive = false
    }

    private func sendConfiguredShortcut() {
        let flags = CGEventFlags(rawValue: VoicePreferences.dictationFlags)
        sendKey(VoicePreferences.dictationKeyCode, flags: flags)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(15000)
        up?.post(tap: .cghidEventTap)
    }
}
