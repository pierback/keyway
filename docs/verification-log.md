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
- `scripts/regression_gate`: passed again after the Focused Target prominent-window routing change.
- `SONOS_HANDOFF_REAL_DEVICE_SMOKE=1 SONOS_HANDOFF_ROOM=Port scripts/regression_gate`: passed at 2026-05-20 18:38 local time, including:
  - `smoke_port_handoff=ok`
  - `smoke_menubar_handoff=ok`
  - `smoke_menubar_slider=ok`
- `scripts/acceptance_preflight`: now reports `acceptance_preflight=pass` on the local machine after the real-device gate.
- Startup and shortcut refresh now request the macOS Accessibility prompt when the media-key event tap cannot be created.
- Keyway now persists shortcut runtime readiness in `~/Library/Application Support/keyway/shortcut-runtime-status.json` so preflight is not dependent on volatile unified-log retention.
- After reinstalling `/Users/f.pieringer/Applications/Keyway.app`, `scripts/acceptance_preflight` passed the Accessibility/media-key event-tap readiness check from the persisted status file:
  - `pass: Keyway persisted shortcut runtime status is mediaFallback=enabled`
- `scripts/acceptance_preflight` now waits briefly for the app-owned MediaRemote helper after a fresh launch, avoiding a false helper block during install/relaunch settling.
- `scripts/acceptance_preflight` accepts validated newer Keyway-owned token state after runtime refreshes, and verifies the legacy Sonos Handoff files remain unchanged during the preflight.
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
- `config.json` still matches the legacy checksum.
- `spotify-desktop-connect-tokens.json` is now newer in Keyway after runtime refresh; `scripts/acceptance_preflight` verifies it has a complete Desktop Connect token schema and that the legacy token file remains unchanged.
- Legacy support files under `~/Library/Application Support/sonos-handoff` remained byte-for-byte unchanged in the install/import and preflight checks.
- Current Spotify readiness was verified through `sonos-handoff-port playback-status`:
  - `spotify_device=Port type=AVR restricted=true`
  - `spotify_device_volume=71`
  - `spotify_playing=true`
- Spotify-to-Sonos handoff was verified through the CLI smoke:
  - `spotify_item=Break Your Heart`
  - `sonos_transport=playing`
  - `handoff=ok`
- Sonos menu-bar handoff was verified through `scripts/smoke_menubar_handoff Port`.
- Sonos menu-bar volume was verified through `scripts/smoke_menubar_slider Port`:
  - `initial_volume=72`
  - `target_volume=82`
  - `observed_volume=82`
  - `restored_volume=72`
- Sonos mute was verified directly and restored:
  - `initial_muted=false`
  - `volume-mute-on=ok`
  - `volume-mute-off=ok`
  - `restored_muted=false`
- `scripts/smoke_overlay_browser_controls`: passed against the installed app with Spotify, QuickTime Player, and Helium media targets active. The smoke opened the actual media-key chooser, toggled Expanded Controls with Tab, selected the browser-like target, and verified visible Accessibility text:
  - `Expanded Controls`
  - `Browser`
  - `Disabled`
  - `Volume disabled without browser extension`
- Media-key constants for Play/Pause, Next, and Previous were checked against local SDK headers:
  - `NX_KEYTYPE_PLAY = 16`
  - `NX_KEYTYPE_NEXT = 17`
  - `NX_KEYTYPE_PREVIOUS = 18`
- Focused Target routing now includes a Prominent Window Target fallback: when the global foreground app is not a Media Target, Keyway checks prominently visible, unobscured layer-0 windows on the display containing the mouse pointer before falling back to Pinned Target, Recent Target, or chooser.

## Not Yet Passed Locally

- Full transport routing, overlay keyboard operation from hardware media keys, and routing confirmation still need a hardware media-key run now that the event tap is enabled.
- Spotify Active Device Volume still needs a run against an unrestricted Spotify active device. The current active device is Sonos `Port`, and Spotify reports it as `restricted=true`, so volume write-back is correctly skipped.

## Next Required Acceptance Checks

1. Re-run media-key checks for Play/Pause, Next, Previous, chooser, pinning, focused target, prominent-window target, recent target, and single target.
2. Re-run full overlay keyboard and routing confirmation checks with live media-key presses.
3. Move Spotify playback to an unrestricted active device, then verify Spotify Active Device Volume.
