# Keyway

Keyway is a local macOS menu bar app for choosing which Now Playing app receives Play/Pause, Next, and Previous. It keeps the existing Sonos handoff and volume workflows, adds MediaRemote target discovery through a bundled `/usr/bin/perl` helper, and shows a centered Raycast-like chooser when routing is ambiguous.

Automatic routes use native macOS notifications for brief confirmation feedback. Keyway does not show custom top-of-screen status popups.

Keyway is intentionally local-only for now. It does not include App Store, notarization, or commercial publishing scripts.

## Current Scope

- Distinct app identity from the old Sonos Handoff app:
  - bundle id: `com.fpieringer.Keyway`
  - app support: `~/Library/Application Support/keyway`
  - install path: `~/Applications/Keyway.app`
- One-time import copies existing Sonos Handoff config/token files from `~/Library/Application Support/sonos-handoff` without modifying the source files.
- Sonos discovery, Spotify-to-Sonos handoff, Sonos volume, mute, token readiness, and existing smoke scripts remain in the codebase.
- MediaRemote helper runs as `/usr/bin/perl .../MediaRemoteHelper/keyway-mediaremote-helper.pl .../libkeyway_mediaremote.dylib` and speaks newline-delimited JSON.
- Media keys handled by Keyway are only Play/Pause, Next, and Previous. Hardware volume and mute keys are not intercepted.
- Browser volume is shown as disabled unless a future no-extension backend exists; no browser extension is required.

## Prerequisites

- macOS with Xcode and Swift available.
- Ruby with the `xcodeproj` gem when regenerating the Xcode project.
- Spotify and at least one browser or browser-wrapper Now Playing session for media-target checks.
- Local Sonos network access for real-device Sonos smoke checks.
- Accessibility permission for `/Users/f.pieringer/Applications/Keyway.app`; Keyway requests it when the media-key event tap cannot be created. macOS requires this for suppressing hardware media-key events.

## Build And Install

From this checkout:

```bash
/Users/f.pieringer/projects/keyway/scripts/bootstrap
```

Build only:

```bash
xcodebuild -workspace /Users/f.pieringer/projects/keyway/Keyway.xcworkspace -scheme Keyway -configuration Debug -destination 'platform=macOS' -derivedDataPath /Users/f.pieringer/projects/keyway/.build/xcode-derived-data build
```

Install and launch the local app:

```bash
/Users/f.pieringer/projects/keyway/scripts/install_menubar_app
```

Run the deterministic regression gate:

```bash
/Users/f.pieringer/projects/keyway/scripts/regression_gate
```

Summarize the current local acceptance readiness:

```bash
/Users/f.pieringer/projects/keyway/scripts/acceptance_preflight
```

`acceptance_preflight=pass` means the installed app, helper, imported config, MediaRemote discovery, Accessibility readiness, Spotify state, Sonos discovery, and legacy-file integrity passed in the current local environment. `acceptance_preflight=blocked` means the installed app is intact but one or more required local conditions, such as active Spotify playback or a discoverable Sonos room, still prevents that readiness check from passing.

Run real-device smoke checks when the configured Sonos room is discoverable:

```bash
SONOS_HANDOFF_REAL_DEVICE_SMOKE=1 SONOS_HANDOFF_ROOM=<room-name> /Users/f.pieringer/projects/keyway/scripts/regression_gate
```

Run the overlay browser-volume disabled-state smoke while at least two Now Playing targets are active, including one browser or browser-wrapper target:

```bash
/Users/f.pieringer/projects/keyway/scripts/smoke_overlay_browser_controls
```

Run the transport routing confirmation smoke while at least two Now Playing targets are active. The script can create a temporary silent QuickTime Player target when QuickTime is selected as the safe routing target:

```bash
/Users/f.pieringer/projects/keyway/scripts/smoke_transport_routing_confirmation
```

## Runtime Setup

1. Launch `/Users/f.pieringer/Applications/Keyway.app`.
2. Open Settings from the menu bar app.
3. Confirm `General` reports config import status.
4. Confirm `Spotify` reports Desktop Connect and Web API token readiness.
5. Confirm `Helper Status` reports the MediaRemote helper as running.
6. Approve Accessibility for Keyway in System Settings if macOS shows the prompt or `Permissions` reports it missing.

After Accessibility is granted, restart Keyway or use Settings to refresh shortcuts. Keyway writes shortcut readiness to `~/Library/Application Support/keyway/shortcut-runtime-status.json`; `mediaFallback=enabled` means the media-key event tap is ready.

## Acceptance

The implementation target is [docs/acceptance-runbook.md](/Users/f.pieringer/projects/keyway/docs/acceptance-runbook.md). Keyway is complete only when that runbook passes on a fresh local install, or when the PRD and runbook explicitly move a failed check out of scope.

Current local verification notes live in [docs/verification-log.md](/Users/f.pieringer/projects/keyway/docs/verification-log.md).

## Developer Tools

```text
sonos-handoff-port playback-status
sonos-handoff-port sonos-status <room>
sonos-handoff-port handoff <room>
sonos-handoff-port volume-status <room>
sonos-handoff-port volume-down <room>
sonos-handoff-port volume-up <room>
sonos-handoff-port volume-mute <room>
/Users/f.pieringer/projects/keyway/scripts/smoke_port_handoff <room>
/Users/f.pieringer/projects/keyway/scripts/smoke_menubar_handoff <room>
/Users/f.pieringer/projects/keyway/scripts/smoke_menubar_slider <room>
/Users/f.pieringer/projects/keyway/scripts/acceptance_preflight
```

## Notes

- The MediaRemote bridge intentionally uses private macOS symbols behind the Perl-hosted adapter documented in `docs/adr`.
- The old Sonos Handoff app and `~/Library/Application Support/sonos-handoff` are left alone so the old app can still be used until Keyway fully passes acceptance.
