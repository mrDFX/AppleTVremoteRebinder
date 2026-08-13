<img src="banner.png" alt="AppleTVremoteRebinder">

# AppleTVremoteRebinder

A native macOS menu-bar controller for the 1st-generation Siri Remote (A1513). It turns the remote into a configurable input for using a Mac as an HTPC / Apple-TV-style set-top box, with editable button profiles, trackpad tuning, media and app actions, and voice-input plumbing.

The product goal is to be at least as capable as Remote Buddy 2 for the Mac-as-Apple-TV use case, while keeping every mapping user-editable rather than hard-coded to a specific app.

> **Status.** No pre-built binary is shipped — build the app bundle yourself (see [Building](#building)). Tested on the 1st-gen Siri Remote (A1513). The 2nd-gen A2540 click-ring directions and dedicated Mute button are not mapped yet.

---

## Features

### Configurable button profiles

Every physical button (Menu, TV, Siri/Microphone, Play/Pause, Volume +, Volume −) is independently assignable through a native AppKit Settings window. Each button can carry different actions for:

- **Press** — single click
- **Double Press** — two clicks within the configurable window
- **Hold** — button pressed and held
- **Release** — matched release event, where the hardware exposes one

Menu and TV do not emit a distinct release on this hardware path; their Hold behavior is inferred from repeat events. Push-to-talk actions therefore need Play/Pause, Volume +, Volume −, or Siri, which produce both press and release.

Multiple profiles are supported. Profiles are persisted in `UserDefaults` under a versioned schema (`remoteProfiles.v1`) with legacy migration, a recovery history, and fail-closed handling for corrupt or future payloads.

### Actions

Generic action types available to every trigger:

- **System volume** — up / down / mute, routed through the media-key event path so keyboard media keys still work normally
- **Media transport** — play/pause / next / previous
- **Keyboard shortcut** — arbitrary modifier combinations, including ones macOS steals during live capture (e.g. `⌘⌥Tab`), via a manual shortcut builder
- **Launch / Activate application** — with an optional "if already running" branch
- **Toggle Two Applications** — independent `launchIfNeeded` and `fullscreen` policies per side, so e.g. Kodi can be launched fullscreen while Chrome is only activated
- **Open URL** and **Run Shell**
- **Voice Input** — Start / Stop / Toggle (see [Voice](#voice))

The HTPC preset ships as a starting point that references Kodi and Google Chrome, but the paths are stored in the profile and remain user-editable; runtime behavior does not require any specific app to be installed.

Apple Music auto-launch suppression is opt-in and defaults **on**. It intercepts remote-origin AVRCP play events so Music/iTunes does not wake up when it is not the active target; regular keyboard media keys keep working.

### Trackpad

The Gen-1 touch surface is used as a pointer, with configurable:

- Sensitivity and motion smoothing
- Tap-to-click, physical click, and drag thresholds
- Click lock — freezes the pointer at the pre-press target so pressure-induced finger drift does not move the cursor off the button
- Two-finger scroll, natural-scroll direction, scroll scale
- Double-press / hold / long-press timings

Physical click begins on button-down and completes at the anchored cursor position on release; drag begins only after the drag threshold. The click session is generation-tokened so a stale drag timer cannot leak into the next click, and a mid-drag disconnect always emits the matching mouse-up.

### Remote status and battery

The menu bar and **Settings → General** show live connection state, active HID interface count, and the Siri Remote battery percentage when macOS exposes it. Battery reads use standard HID battery usages first, with the driver's `BatteryPercent` IORegistry property as a compatibility fallback. When the A1513 firmware/macOS combination does not publish either value, the UI reports **Battery: Unavailable** instead of inventing a percentage.

Connection/disconnection and low-battery notifications are independently configurable. Disconnect alerts wait briefly to absorb normal Bluetooth interface re-enumeration; low-battery alerts use hysteresis and a persisted cooldown to avoid repeated notifications.

### Voice

The end-goal is push-to-talk voice input from the Siri Remote microphone into macOS/apps. Current code covers the action/preferences plumbing and an external bridge command; microphone packet capture and decoding is not yet an integrated feature.

Configure the bridge and dictation/PTT shortcut under **Settings → Media & Voice**, then map **Voice Input — Start** to Microphone / Hold and **Voice Input — Stop** to Microphone / Release. The reverse-engineered `SiriRemoteVoiceControl` / PacketLogger path (or a replacement decoder) can feed a virtual audio input without hard-coding one decoder into the app.

### Safety

- **HID seize.** On connect, the remote is seized at the HID level so macOS does not also dispatch the same media-key events — no double action to Music/iTunes, no system funk sound on unhandled keys.
- **Stuck-key prevention.** If the remote disconnects while a push-to-talk key is held, the virtual key is released automatically.
- **Balanced physical clicks.** Disconnecting mid-drag posts the matching mouse-up, and delayed drag timers cannot leak into the next click.
- **Interface-safe reconnect.** The remote is treated as connected while any of its HID interfaces is present; losing one interface no longer tears down the others.
- **Stale-hold self-heal.** If a release HID event is ever missed, the next press closes the stale hold before opening a new one.

---

## Building

### Prerequisites

- macOS 11 (Big Sur) or later
- Xcode Command Line Tools: `xcode-select --install`

### Build

```bash
./build.sh
./create_app_bundle.sh
```

`build.sh` runs a single `swiftc` invocation over every source file, linking IOKit, CoreGraphics, AudioToolbox, Carbon, AppKit, UserNotifications, and the private MultitouchSupport framework via a bridging header. No Xcode project is required. The bundle is ad-hoc signed with hardened runtime and the entitlements from `AppleTVremoteRebinder.entitlements`.

Native builds are verified on both `arm64` and `x86_64`.

### Tests

Regression tests use an isolated `UserDefaults` suite and do not touch saved settings:

```bash
./run_profile_tests.sh   # profile schema, migration, recovery, sequence quarantine
./run_input_tests.sh     # HID interface registry, physical-click state machine, battery normalization, connection/low-battery alert policy
```

---

## Installing and running

1. Build and bundle: `./build.sh && ./create_app_bundle.sh`
2. Move `AppleTVremoteRebinder.app` to `/Applications` (optional, helps icon caching)
3. Launch: `open AppleTVremoteRebinder.app`
4. Grant permissions in **System Settings → Privacy & Security**:
   - **Accessibility** — for posting keyboard/mouse events
   - **Input Monitoring** — for reading HID events (add the app explicitly with the **+** button)
   - **Bluetooth** — to talk to the remote
5. Pair the Siri Remote via **System Settings → Bluetooth** if it isn't already paired
6. Configure profiles from the menu-bar item → **Open Settings…**

Without Input Monitoring, HID and media-key interception cannot work — volume and play/pause buttons will pass through to the system and, for example, wake Music.

A diagnostic log is written to `/tmp/appletvremoterebinder.log`. NSLog is redacted under hardened runtime, so file logging is used instead.

---

## How the input paths work

A physical Siri Remote press can arrive two ways:

1. **HID (seized)** — `RemoteInputHandler` reads raw HID input from every interface of the paired remote.
2. **AVRCP → NX_SYSDEFINED** — Bluetooth media-key events arrive via a `.cghidEventTap` at `.headInsertEventTap`, caught by `MediaKeyInterceptor` before the system dispatcher routes them to Music.

Both paths converge on the same mapping through a short debounce, so a press fires its mapped action exactly once regardless of which path delivered it first.

### The NX_SYSDEFINED hack

macOS has no public API for synthesizing or intercepting media keys. Both `MediaKeyInterceptor` and `MediaController` use the same undocumented `NSSystemDefined` event format the HID stack uses internally:

- **Event type** `NX_SYSDEFINED` (raw value `14`) with **subtype `8`**
- **Key code and state packed into `data1`** as a bitfield: `(nxKeyCode << 16) | (keyState << 8)`, where `0xA` is key down and `0xB` is key up
- **Magic `modifierFlags`** (`0xa00` for down, `0xb00` for up) mirror the state nibble. Real media-key events arrive with these flags, and some consumers (e.g. Music) refuse posted events without them.

`MediaController` fabricates matching `NSSystemDefined` events via `NSEvent.otherEvent(...)` and posts them to the session tap. A **`usleep(50_000)`** gap between down and up is required — without it macOS coalesces or drops the pair and the media key is ignored. The event tap is re-enabled on `tapDisabledByTimeout`, `tapDisabledByUserInput`, and `NSWorkspace.didWakeNotification`, because macOS silently disables event taps across sleep/wake and input stalls.

This is the standard reverse-engineered technique (surfaced in projects like SPMediaKeyTap and Noteify) and can change in any macOS release.

---

## Caveats

- Uses Apple's **private `MultitouchSupport` framework** — not App Store compatible; Apple can change or remove this API.
- **`NX_SYSDEFINED` media-key synthesis and interception is undocumented** — relies on magic modifier-flag values, subtype `8`, and a manual `data1` bitfield layout. Apple can break it in any release.
- Tested on **Siri Remote 1st-gen (A1513, product ID `0x266`)**. HID codes are a superset that should cover the 2nd-gen A2540 as well, but its click-ring directional presses and dedicated Mute button are not mapped yet.
- Ad-hoc signing ties TCC permission grants to the exact binary hash — a rebuild may require re-approving Accessibility and Input Monitoring in System Settings.

---

## Credits

Built on top of [Remotastic](https://github.com/lauschue/Remotastic) by [@lauschue](https://github.com/lauschue), which provided the initial Siri-Remote HID handling, MultitouchSupport integration, and menu-bar scaffolding.

UI icons from [The Noun Project](https://thenounproject.com/):

- [Arrow Up by Dayeong Kim](https://thenounproject.com/icon/arrow-up-6066125/)
- [Microphone by Alvida](https://thenounproject.com/icon/microphone-8162320/)
- [Radio by Kiran Shastry](https://thenounproject.com/icon/radio-2338991/)
