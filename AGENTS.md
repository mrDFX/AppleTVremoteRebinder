# AppleTVremoteRebinder — Codex instructions

## Project goal
AppleTVremoteRebinder is a native macOS menu-bar controller for Siri Remote 1st gen (A1513). The product goal is to be at least as capable and polished as Remote Buddy 2 for the Mac-as-Apple-TV / HTPC use case, while remaining configurable rather than hardcoding Kodi/Chrome behavior.

## Non-negotiable workflow
- Never work directly on `main`. Start from updated `main` and use a feature/fix branch.
- Push only to `origin` (`mrDFX/AppleTVremoteRebinder`). Do not add or push to `machinarii/hypervibe`.
- Keep each logical change reviewable. Prefer a PR and squash merge.
- Before editing, inspect `git status`, current branch, and recent commits. Do not discard user changes.
- Do not commit `AppleTVremoteRebinder.app` or build output. `build.sh` may rewrite the tracked `AppleTVremoteRebinder` binary; restore that binary before committing unless the task explicitly changes release artifacts.
- Keep bundle/package identifiers neutral. Do not put `mrDFX`/`mrdfx` into bundle IDs, namespaces, source identifiers, or app-visible internals. Current bundle ID is `com.appletvremoterebinder.app`.

## Build and verification
Primary build:

```bash
rm -rf AppleTVremoteRebinder.app
./build.sh && ./create_app_bundle.sh
```

Never run `create_app_bundle.sh` after a failed build. Also run:

```bash
git diff --check
```

Before a PR is considered ready, test native builds on both:
- Apple Silicon (`arm64`)
- Intel Mac (`x86_64`)

Manual hardware testing with a Siri Remote A1513 is required for HID/touch/voice behavior; passing compilation alone is not enough.

## Architecture and persistence
- Profiles/actions live in `RemoteProfiles.swift` and are persisted in `UserDefaults`.
- Preserve existing user configuration. The profile storage key is intentionally `remoteProfiles.v1`; do not reset it casually.
- Default HTPC values may suggest Kodi/Google Chrome, but runtime behavior must not depend on those apps being installed and must remain editable.
- `Toggle Two Applications` uses per-app `ApplicationTarget` policies: path, `launchIfNeeded`, and `fullscreen`. Keep those settings independent for App A and App B.
- Physical remote trigger enum names are `.single`, `.double`, `.hold`, `.release`.
- Menu and TV may not expose a normal release event on this hardware path. Their Hold behavior is currently inferred from repeat events. Improve this only when backed by observed HID/private-API behavior; do not fake unsupported release semantics.

## UI/UX requirements
- Use native AppKit controls and macOS conventions. Settings should feel like a real macOS preferences window, not a debug panel.
- The menu-bar app should normally remain an accessory with no persistent Dock icon. While Settings is open it must be reachable via Dock and Command-Tab; restore accessory behavior after Settings closes.
- Avoid giant empty regions, compressed cards, overlapping constraints, or horizontally cramped action editors. Test resized windows at minimum and normal sizes.
- Every physical button should be visibly configurable where technically supported: Menu, TV/Home, Microphone/Siri, Play/Pause, Volume +, Volume −.
- Make shortcut configuration support arbitrary modifier combinations (including Command+Option+Tab) without relying only on live key capture.
- Never overwrite a path the user already selected (for example regular Google Chrome instead of Canary) merely because a preset/default is regenerated.

## Trackpad quality bar
Trackpad behavior is a product-critical path, not a secondary feature.
- One-finger pointer motion should feel smooth and predictable at TV distances.
- Tap-to-click, physical click, drag, and two-finger scrolling must coexist without accidental pointer jumps.
- Physical click must land at the cursor position the user intended before pressure nudges the finger.
- Small finger jitter should be filtered without obvious latency or a "floaty" cursor.
- Keep sensitivity, smoothing, natural scrolling, click lock, double-press, hold, and drag thresholds configurable.
- Regression-test click-at-current-cursor and drag after every touch pipeline change.

## Media and app actions
Keep generic actions first-class:
- system volume up/down/mute
- media play/pause/next/previous
- arbitrary keyboard shortcut
- launch/activate app
- ensure app running + configurable action when already running
- toggle two apps with independent launch/fullscreen policies
- URL and shell action
- voice input start/stop/toggle

Apple Music auto-launch protection is configurable and defaults ON. Do not break normal keyboard media keys while suppressing remote-origin AVRCP behavior.

## Voice goal
The eventual goal is push-to-talk voice input from the Siri Remote microphone into macOS/apps. Current code only has the action/preferences/controller plumbing and an external bridge command; microphone packet capture/decoding is not yet a complete integrated feature.

Treat microphone work as a separate subsystem: capture transport, codec/decoding, virtual or direct audio input, PTT lifecycle, permissions, and failure UI. Prefer a self-contained setup over requiring the user to manually orchestrate multiple tools, but keep fallback bridge configurability.

## Product-level roadmap
Prioritize, in roughly this order:
1. Input correctness and trackpad feel.
2. Reliable button trigger detection including Menu/TV Hold if technically available.
3. High-quality Settings/action-editor UX and profile management.
4. Integrated microphone/voice input.
5. Broader Remote Buddy-like app/profile behaviors and discoverability.
6. Packaging, universal distribution, signing/notarization, migration and automated tests.

## Code review rules
- Flag any change that resets `UserDefaults` or silently rewrites user-selected app paths.
- Flag hardcoded application-specific behavior outside explicit presets.
- Flag build artifacts in source PRs.
- Flag assumptions that Menu/TV emit release events without captured evidence.
- Flag UI work that has not considered window resizing and minimum-size constraints.
- Flag touch changes that do not preserve click, drag, and scroll semantics together.
