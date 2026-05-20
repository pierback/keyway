# Keyway Verification Log

Last updated: 2026-05-20

## Verified In This Branch

- Branch: `keyway-planning`
- Implementation commits:
  - `e2fd154 Document Keyway product direction`
  - `7f8b8ab Add Keyway acceptance runbook`
  - `2d66be1 Cut over app identity to Keyway`
  - `9ac40cc Add MediaRemote helper bridge`
  - `4b1137e Route media keys through Keyway overlay`
  - `53e5590 Fix media target overlay chooser state`
- Verification documentation updates are committed on top of the implementation commits.
- `swift test --package-path packages/SonosHandoffCore`: passed with 236 tests.
- `xcodebuild -workspace Keyway.xcworkspace -scheme Keyway -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode-derived-data build`: passed.
- `scripts/install_menubar_app`: passed and installed `/Users/f.pieringer/Applications/Keyway.app`.
- `scripts/regression_gate`: passed in default mode again at 2026-05-20 17:22 local time.
- `scripts/acceptance_preflight`: initially reported `acceptance_preflight=blocked` because Accessibility and Sonos room discovery were unavailable locally.
- Startup and shortcut refresh now request the macOS Accessibility prompt when the media-key event tap cannot be created.
- After reinstalling `/Users/f.pieringer/Applications/Keyway.app`, `scripts/acceptance_preflight` passed the Accessibility/media-key event-tap readiness check:
  - `pass: Keyway event tap has reached mediaFallback=enabled`
- The latest `scripts/acceptance_preflight` run still reports `acceptance_preflight=blocked` with exit code 2 because Spotify has no active playback and Sonos room `Port` is not discoverable.
- `codex-review --parallel-tests "scripts/regression_gate"`: initially reported overlay chooser state findings; fixed in `53e5590`; rerun clean with no accepted/actionable findings.
- Installed bundle id: `com.fpieringer.Keyway`.
- Installed app signature uses identifier `com.fpieringer.Keyway` and TeamIdentifier `7Q44SDV7BM`.
- Installed helper process observed:
  - `/usr/bin/perl /Users/f.pieringer/Applications/Keyway.app/Contents/Resources/MediaRemoteHelper/keyway-mediaremote-helper.pl /Users/f.pieringer/Applications/Keyway.app/Contents/Resources/MediaRemoteHelper/libkeyway_mediaremote.dylib`
- Installed helper NDJSON smoke returned Spotify and Helium browser-wrapper targets:
  - Spotify: `com.spotify.client`, title `Journey Unknown`, artist `Fuga Ronto`
  - Helium: `net.imput.helium`, title `Instagram`
- QuickTime Player target discovery was verified by opening `/tmp/keyway-quicktime-check.aiff` in QuickTime:
  - QuickTime Player: `com.apple.QuickTimePlayerX`, media type `kMRMediaRemoteNowPlayingInfoTypeAudio`
- Helper failure/restart was verified by killing the app-owned helper:
  - Keyway logged `MediaRemoteHelper failed=MediaRemote helper exited with status 15.`
  - A new `/usr/bin/perl` helper was observed running within two seconds.
- Settings was opened through the menu bar UI with `Cmd+,`:
  - System Events reported `background only=false` and `visible=true` for process `Keyway`.
  - The Settings window contained General, Transport Routing, Overlay, Audio Controls, Sonos, Spotify, Shortcuts, Permissions, Helper Status, and Diagnostics.
  - Helper Status displayed `Running`, `MediaRemote snapshot loaded`, `targets=3`.
- Config import copied legacy files into `~/Library/Application Support/keyway`.
- `config.json` and `spotify-desktop-connect-tokens.json` have matching SHA-256 checksums in legacy and Keyway support directories.
- Legacy support files under `~/Library/Application Support/sonos-handoff` remained byte-for-byte unchanged in the install/import check.
- Current Spotify readiness was verified through `sonos-handoff-port playback-status`:
  - `spotify_device=Fabian’s MacBook Pro (2) type=Computer restricted=false`
  - `spotify_device_volume=100`
  - `spotify_playing=true`
- Media-key constants for Play/Pause, Next, and Previous were checked against local SDK headers:
  - `NX_KEYTYPE_PLAY = 16`
  - `NX_KEYTYPE_NEXT = 17`
  - `NX_KEYTYPE_PREVIOUS = 18`

## Not Yet Passed Locally

- Real Sonos smoke checks could not be run successfully because the configured rooms were not discoverable from the current network:
  - `Port`
  - `Office`
  - `kitchen`
- Spotify playback status currently reports no active playback, so Spotify volume and active-device acceptance checks need a rerun with Spotify playing.
- Full transport routing, overlay keyboard operation from hardware media keys, and routing confirmation still need a hardware media-key run now that the event tap is enabled.
- Sonos volume and mute still need a run on a network where a configured Sonos room is discoverable.

## Next Required Acceptance Checks

1. Start active Spotify playback on a controllable device.
2. Re-run media-key checks for Play/Pause, Next, Previous, chooser, pinning, focused target, recent target, and single target.
3. Connect to a network where at least one configured Sonos room is discoverable, then run:

```bash
SONOS_HANDOFF_REAL_DEVICE_SMOKE=1 SONOS_HANDOFF_ROOM=<room-name> /Users/f.pieringer/projects/keyway/scripts/regression_gate
```

4. Re-run Sonos volume and mute checks against the discoverable room.
5. Re-run full overlay keyboard and routing confirmation checks with live media-key presses.
