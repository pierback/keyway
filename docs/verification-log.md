# Keyway Verification Log

Last updated: 2026-05-20

## Verified In This Branch

- Branch: `keyway-planning`
- Commits:
  - `e2fd154 Document Keyway product direction`
  - `7f8b8ab Add Keyway acceptance runbook`
  - `2d66be1 Cut over app identity to Keyway`
  - `9ac40cc Add MediaRemote helper bridge`
  - `4b1137e Route media keys through Keyway overlay`
- `swift test --package-path packages/SonosHandoffCore`: passed with 236 tests.
- `xcodebuild -workspace Keyway.xcworkspace -scheme Keyway -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode-derived-data build`: passed.
- `scripts/install_menubar_app`: passed and installed `/Users/f.pieringer/Applications/Keyway.app`.
- `scripts/regression_gate`: passed in default mode.
- Installed bundle id: `com.fpieringer.Keyway`.
- Installed helper process observed:
  - `/usr/bin/perl /Users/f.pieringer/Applications/Keyway.app/Contents/Resources/MediaRemoteHelper/keyway-mediaremote-helper.pl /Users/f.pieringer/Applications/Keyway.app/Contents/Resources/MediaRemoteHelper/libkeyway_mediaremote.dylib`
- Installed helper NDJSON smoke returned Spotify and Helium browser-wrapper targets:
  - Spotify: `com.spotify.client`, title `My Love Turns to Liquid`, artist `Dream 2 Science`
  - Helium: `net.imput.helium`, title `Instagram`
- Config import copied legacy files into `~/Library/Application Support/keyway`.
- Legacy support files under `~/Library/Application Support/sonos-handoff` remained byte-for-byte unchanged in the install/import check.
- Media-key constants for Play/Pause, Next, and Previous were checked against local SDK headers:
  - `NX_KEYTYPE_PLAY = 16`
  - `NX_KEYTYPE_NEXT = 17`
  - `NX_KEYTYPE_PREVIOUS = 18`

## Not Yet Passed Locally

- Media-key interception could not be validated on this machine during this run because Accessibility is not yet granted to the new `com.fpieringer.Keyway` app. The observed log was:
  - `mediaFallback=disabled ... event_tap_create_failed accessibility=false`
- Real Sonos smoke checks could not be run successfully because the configured rooms were not discoverable from the current network:
  - `Port`
  - `Office`
  - `kitchen`
- QuickTime target discovery still needs a manual run with a local media file playing.
- Settings Cmd-Tab visibility still needs manual verification with the Settings window open.

## Next Required Acceptance Checks

1. Grant Accessibility to `/Users/f.pieringer/Applications/Keyway.app`.
2. Restart Keyway or refresh shortcuts from Settings.
3. Re-run media-key checks for Play/Pause, Next, Previous, chooser, pinning, focused target, recent target, and single target.
4. Connect to a network where at least one configured Sonos room is discoverable, then run:

```bash
SONOS_HANDOFF_REAL_DEVICE_SMOKE=1 SONOS_HANDOFF_ROOM=<room-name> /Users/f.pieringer/projects/keyway/scripts/regression_gate
```

5. Play local media in QuickTime and confirm it appears in the overlay target list.
6. Open Settings and verify it appears in Cmd-Tab while visible.
