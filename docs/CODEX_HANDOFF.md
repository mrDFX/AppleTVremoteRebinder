# Codex handoff — AppleTVremoteRebinder

## Current state
The app is a native AppKit menu-bar utility for Siri Remote 1st gen (A1513), building natively on Apple Silicon and Intel. The current development line adds a real Settings window, profiles, generic actions, app toggling, trackpad tuning, and voice-input plumbing.

Implemented or substantially implemented:
- project/app rename to AppleTVremoteRebinder
- custom button mappings and key capture
- configurable profiles persisted in `UserDefaults`
- versioned profile documents with legacy migration, recovery copies and fail-closed handling for unreadable/future data
- Press / Double Press / Hold / Release action model (`RemoteTrigger.single/double/hold/release`)
- native actions for volume/media/navigation plus custom shortcuts
- manual shortcut builder for combinations macOS steals during live capture (e.g. Command+Option+Tab)
- launch/ensure/toggle app actions
- `Toggle Two Applications` V2 with independent `launchIfNeeded` and `fullscreen` per app
- HTPC preset where Kodi may fullscreen while regular Google Chrome does not
- Apple Music auto-launch suppression option
- first-press-after-wake app-side swallow removed
- trackpad sensitivity/smoothing/tap/click-lock/natural-scroll/timing preferences
- click locking intended to keep physical click on the pre-press cursor target
- Settings layout cards and scrolling
- external voice bridge preferences plus Voice Input Start/Stop/Toggle actions
- icon resources for remote controls

## Important current limitations
1. Trackpad still requires real hardware tuning. The target feel is Apple-TV-like smoothness and reliable click/drag, not merely functional pointer movement.
2. Menu/TV Hold is inferred from repeated HID events because the current path may not expose normal release events. Verify with real event logs before changing semantics.
3. Voice is not yet an integrated Siri Remote microphone decoder. Current `VoiceInputController` handles dictation/bridge orchestration only.
4. Settings/action editing still uses several `NSAlert` flows. A later UX pass should consider sheets/popovers or a persistent inspector where this improves clarity.
5. Distribution is currently host-native build. A polished release path should eventually cover universal binaries, signing/notarization, upgrades and migration tests.

## Current immediate fix line
A settings-window patch changes the app to `.regular` activation policy while Settings is open, so the window appears in the Dock and Command-Tab. When Settings closes, it returns to `.accessory` so the normal app remains menu-bar-only.

The same patch also:
- stops short Trackpad/Media pages from stretching stack spacing across the full viewport
- lets settings cards fill the usable width
- makes active-profile state explicit instead of leaving an enabled `Make Active` button on an already active profile

Test this behavior manually before starting the next feature.

## UX direction
Do not model the UI as a giant matrix. The desired interaction is closer to native macOS Settings:
- profile navigation in a stable sidebar
- clear representation of the physical Siri Remote controls
- each button opens/contains understandable trigger-to-action configuration
- advanced details appear only when needed
- app actions show app identity/path and per-app launch/fullscreen policy clearly
- shortcuts show glyphs and can be edited without performing the shortcut live
- unsupported trigger semantics should be explained, not silently disabled without context

## Trackpad acceptance tests
With a real A1513:
- move pointer slowly onto a small target; physical click must hit that target
- repeat while the finger shifts slightly from press pressure; cursor must not jump before click
- press-and-hold then move; drag must begin predictably and continue smoothly
- tap-to-click should not generate accidental drags
- two-finger scroll should not intermittently become pointer motion
- small movement should be stable, long movement should not feel sluggish
- repeat after remote sleep/reconnect

Collect logs/traces when behavior is ambiguous rather than tuning constants blindly.

## Voice target
Desired user experience:
- assign Microphone Hold -> Voice Input Start
- Release -> Voice Input Stop
- holding microphone captures Siri Remote voice and exposes it to macOS/apps as usable input/dictation
- no manual PacketLogger ritual should be necessary in the final product

Research the existing SiriRemoteVoiceControl approach and current macOS Bluetooth/audio constraints before choosing the final capture architecture. Keep the transport/decoder isolated from the action engine.

## Git expectations
Work in a feature/fix branch. Do not push to upstream HyperVibe. Before PR:

```bash
git diff --check
rm -rf AppleTVremoteRebinder.app
./build.sh && ./create_app_bundle.sh
```

Then test on both arm64 and x86_64 Macs, and manually test the remote.
