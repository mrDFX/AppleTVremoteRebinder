//
//  MediaController.swift
//  Remotastic
//
//  Sends system media key events (NX_SYSDEFINED subtype 8) for remote button mappings.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin

class MediaController {
    static let syntheticEventMarker: Int64 = 0x41545242 // "ATRB"

    func sendMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) {
        guard let nxCode = nxKeyCode(for: keyType) else { return }
        postSystemDefinedKey(nxKeyCode: nxCode)
    }

    private func nxKeyCode(for keyType: MediaKeyInterceptor.MediaKeyType) -> Int32? {
        switch keyType {
        case .playPause: return NX_KEYTYPE_PLAY
        case .next: return NX_KEYTYPE_NEXT
        case .previous: return NX_KEYTYPE_PREVIOUS
        case .volumeUp: return NX_KEYTYPE_SOUND_UP
        case .volumeDown: return NX_KEYTYPE_SOUND_DOWN
        case .mute: return NX_KEYTYPE_MUTE
        }
    }

    private func postSystemDefinedKey(nxKeyCode: Int32) {
        let ts = ProcessInfo.processInfo.systemUptime
        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: ts,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((nxKeyCode << 16) | (0xa << 8)),
            data2: -1
        )
        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: ts,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((nxKeyCode << 16) | (0xb << 8)),
            data2: -1
        )
        let sessionTap: CGEventTapLocation = .cgSessionEventTap
        if let downEvent = keyDown?.cgEvent {
            downEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            downEvent.post(tap: sessionTap)
        }
        usleep(50000)
        if let upEvent = keyUp?.cgEvent {
            upEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            upEvent.post(tap: sessionTap)
        }
    }
}
