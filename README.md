# Keyway

Keyway is a local macOS menu bar app for choosing which Now Playing app receives Play/Pause, Next, and Previous. It keeps the existing Sonos handoff and volume workflows, adds MediaRemote target discovery through a bundled `/usr/bin/perl` helper, and shows a centered Raycast-like chooser when routing is ambiguous. A Chromium extension adds exact per-tab targeting, focus, mute, and volume.

Automatic routes use native macOS notifications for brief confirmation feedback. Keyway does not show custom top-of-screen status popups.

Keyway supports local development and notarized Developer ID builds for installation on other Macs. App Store and commercial publishing work remain out of scope.

## Current Scope

- Distinct app identity from the old Sonos Handoff app:
  - bundle id: `com.fpieringer.Keyway`
  - app support: `~/Library/Application Support/keyway`
  - install path: `~/Applications/Keyway.app`
- One-time import copies existing Sonos Handoff config/token files from `~/Library/Application Support/sonos-handoff` without modifying the source files.
- Sonos discovery, Spotify-to-Sonos handoff, Sonos volume, mute, token readiness, and existing smoke scripts remain in the codebase.
- MediaRemote helper runs as `/usr/bin/perl .../MediaRemoteHelper/keyway-mediaremote-helper.pl .../libkeyway_mediaremote.dylib` and speaks newline-delimited JSON.
- Media keys handled by Keyway are only Play/Pause, Next, and Previous. Hardware volume and mute keys are not intercepted.
- MediaRemote transport routing remains available when the Chromium extension is absent.
- The Chromium extension is required for per-tab targets, exact tab focus, reflected mute, and element-level volume.

## Prerequisites

- macOS with Xcode and Swift available.
- Ruby with the `xcodeproj` gem when regenerating the Xcode project.
- Xcode signed into the matching paid Apple Developer account with access to cloud-managed Developer ID signing for notarized releases. The local installer still requires a Developer ID Application certificate in the keychain.
- Spotify and at least one browser or browser-wrapper Now Playing session for media-target checks.
- The unpacked Keyway Chromium extension for per-tab browser checks; see [ChromiumExtension/README.md](ChromiumExtension/README.md).
- Local Sonos network access for real-device Sonos smoke checks.
- Accessibility and Input Monitoring permission for `$HOME/Applications/Keyway.app`. Keyway requests recovery when its media-key event tap cannot be created; macOS requires both permissions for suppressing hardware media-key events.

## Build And Install

From this checkout:

```bash
scripts/bootstrap
```

Build only:

```bash
xcodebuild -workspace Keyway.xcworkspace -scheme Keyway -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode-derived-data -allowProvisioningUpdates build
```

Install and launch the local app:

```bash
scripts/install_menubar_app
```

The installer uses the stable Developer ID identity and refuses updates with a different designated requirement. This keeps Accessibility and Input Monitoring permissions attached to Keyway across later versions.

Build, submit, staple, verify, and package a release for other Macs:

```bash
scripts/build_notarized_app
```

Release archives use automatic signing, and Xcode cloud-signs the exported app with Developer ID before notarization. The notarized app ZIP and a separate Chrome Web Store extension ZIP are written to `.build/distribution/`.

Run the deterministic regression gate:

```bash
scripts/regression_gate
```

Summarize the current local acceptance readiness for a specific Sonos room:

```bash
SONOS_HANDOFF_ROOM=<room-name> scripts/acceptance_preflight
```

`acceptance_preflight=pass` means the installed app, helper, imported config, MediaRemote discovery, media-key permissions, Spotify state, Sonos discovery, and legacy-file integrity passed in the current local environment. It does not exercise the Chromium extension, visible UI, or physical keys. `acceptance_preflight=blocked` means one or more required local conditions, such as active Spotify playback or a discoverable Sonos room, still prevents the core readiness check from passing.

Run real-device smoke checks when the configured Sonos room is discoverable:

```bash
SONOS_HANDOFF_REAL_DEVICE_SMOKE=1 SONOS_HANDOFF_ROOM=<room-name> scripts/regression_gate
```

Run the overlay browser-control smoke while at least two Now Playing targets are active, including one browser or browser-wrapper target. It exercises extension-backed reflected mute when connected and verifies an explicit reduced-capability state otherwise:

```bash
scripts/smoke_overlay_browser_controls
```

For final hardware-key acceptance, run the same overlay smoke in physical media-key mode and press the real Play/Pause key when prompted:

```bash
KEYWAY_PHYSICAL_MEDIA_KEYS=1 scripts/smoke_overlay_browser_controls
```

Run the transport routing confirmation smoke while at least two Now Playing targets are active. It verifies focused-target routing for Previous/Next; Play/Pause chooser behavior is covered by the playback routing probes. The script can create a temporary silent QuickTime Player target when QuickTime is selected as the safe routing target:

```bash
scripts/smoke_transport_routing_confirmation
```

For final hardware-key acceptance, run the same transport smoke in physical media-key mode and press real Previous, Next, Volume Up, Volume Down, and Mute keys when prompted:

```bash
KEYWAY_PHYSICAL_MEDIA_KEYS=1 scripts/smoke_transport_routing_confirmation
```

## Runtime Setup

1. Launch `$HOME/Applications/Keyway.app`.
2. Left-click the menu bar icon for the compact Control Center-style daily controls.
3. Use the visible `Open Media Target Chooser` button in the popover header to open the centered chooser.
4. Right-click the menu bar icon for the native utility menu.
5. Open Settings from the menu bar app.
6. Confirm `General` reports config import status.
7. Confirm `Spotify` reports Desktop Connect and Web API token readiness.
8. Confirm `Transport Routing` reports the Chromium extension connected when per-tab browser capabilities are needed.
9. Confirm `Helper Status` reports the MediaRemote helper as running.
10. Approve Accessibility and Input Monitoring for Keyway in System Settings if `Permissions` reports either missing.

After both permissions are granted, quit and reopen Keyway or use Settings to refresh shortcuts. Keyway writes shortcut readiness to `~/Library/Application Support/keyway/shortcut-runtime-status.json`; `mediaFallback=enabled`, `eventTapRunning=true`, and `commandCenterRouteRunning=true` mean the complete route is ready.

## Acceptance

The implementation target is [docs/acceptance-runbook.md](docs/acceptance-runbook.md). Keyway is complete only when that runbook passes on a fresh local install, or when the PRD and runbook explicitly move a failed check out of scope.

Current local verification notes live in [docs/verification-log.md](docs/verification-log.md).

## Developer Tools

```text
sonos-handoff-port playback-status
sonos-handoff-port sonos-status <room>
sonos-handoff-port handoff <room>
sonos-handoff-port volume-status <room>
sonos-handoff-port volume-down <room>
sonos-handoff-port volume-up <room>
sonos-handoff-port volume-mute <room>
scripts/smoke_port_handoff <room>
scripts/smoke_menubar_handoff <room>
scripts/smoke_menubar_slider <room>
SONOS_HANDOFF_ROOM=<room-name> scripts/acceptance_preflight
```

## Notes

- The MediaRemote bridge intentionally uses private macOS symbols behind the Perl-hosted adapter documented in `docs/adr`.
- The old Sonos Handoff app and `~/Library/Application Support/sonos-handoff` are left alone so the old app can still be used until Keyway fully passes acceptance.
