# Keyway Verification Log

Last updated: 2026-07-21

This file records the current worktree, not a cumulative history. Git retains earlier device-run notes.

## Passed in the current worktree

- The regression gate's non-installing checks completed successfully against the current reviewed worktree.
  - All 250 tests in 44 suites passed, including the Spotify OAuth callback-listener and token-status tests.
  - All 35 `scripts/verify_*` semantic verifiers passed, including strict CLI argument semantics.
  - All repository Bash scripts passed syntax checking.
  - `git diff --check` passed.
  - Xcode project generation produced byte-identical project and scheme files across two consecutive runs.
- That gate ran after the immutable-diff review fixes, including owned route-fallback timeouts, strict CLI parsing, exact-path installer process selection, explicit Developer ID propagation, bounded notarization polling, and deterministic Xcode identifiers.
- Both live Settings entry paths now use one canonical SwiftUI scene.
  - The first utility-menu `Settings...` invocation from menu-bar-only mode opened one `Keyway Settings` window and changed the Launch Services application type from `UIElement` to `Foreground`.
  - Two subsequent Cmd+, invocations kept the window count at exactly one.
  - Closing the only window restored the Launch Services application type to `UIElement`.
- The visible menu-bar control center rendered its Brave, Chrome, Spotify, Sonos, and Web API states. The control-click utility menu exposed Settings, helper restart, and quit.
- Killing both app-owned MediaRemote helpers produced replacement processes, kept the popover source list intact, and accepted the next targeted Safari transport command within five seconds.
- Spotify AppleEvent transport passed play and pause (2/2 commands, 0 failures, 75 ms p95 acknowledgement).
- Chromium extension transport passed its isolated live end-to-end run.
  - All 9 command checks passed: pause, play, two play/pause toggles, two mute toggles, volume, next, and previous.
  - Both exact-tab focus checks passed.
  - All 10 alternating-target stress iterations passed with zero wrong-target, duplicate, or failed acknowledgements.
  - Discovery took 147 ms and p95 acknowledgement was 227 ms.
- Chromium Manifest V3 service-worker suspension and recovery passed in 18.1 seconds with no extension console or runtime errors.
- The insecure-page extension regression is covered without `crypto.randomUUID`; Chrome control loaded the final content script on a non-secure LAN HTTP origin and reported zero extension warnings or errors. The user's existing media tab was not touched.
- Safari Play and Pause both passed through the installed app's popover, with matching MediaRemote state and successful targeted-command traces.
- `scripts/hitl_touchbar_playback_state_check` passed against the live route-shield state (`playbackRate=1` while Spotify was playing); Safari's paused state remained `playbackRate=0`.
- All 10 Settings sections were opened through the installed app: General, Transport Routing, Overlay, Audio Controls, Sonos, Spotify, Shortcuts, Permissions, Helper Status, and Diagnostics.
- Spotify Web API sign-in is valid. `project-webapi-token.json` exists with owner-only permissions, live playback state was readable, and `scripts/smoke_spotify_webapi_transport` passed Play and Pause (2/2 commands).
- The `Kitchen` Sonos speaker was discovered on the local network. A real volume change and mute change passed and both values were restored to volume 8 and unmuted.
- Pausing Spotify no longer clears the selected Sonos output. The live popover kept `Kitchen` selected and showed its restored volume at 8% while every media source was paused.
- The centered media-target overlay was inspected live after its sizing fix; the command header, all three source rows, expanded area, and footer fit without clipping.
- Spotify Settings now validates the Desktop Connect file contents and distinguishes missing credentials from corrupt files, network/server failures, and an invalid Web API sign-in instead of collapsing every failure into “token missing.”
- Full-diff reuse, quality, efficiency, and focused permission-state reviews completed with no remaining accepted findings.
- The current diff removes more than 2,000 net lines while retaining the verified behavior above.

## Release pipeline evidence

- The final universal app and both embedded helpers were signed inside-out with `Developer ID Application: Fabian Pieringer (7Q44SDV7BM)`, notarized by Apple, stapled, and installed at `/Users/fabian/Applications/Keyway.app`.
- The installed app contains both `x86_64` and `arm64` slices. Strict code-signature verification and staple validation passed, and Gatekeeper accepted it as `Notarized Developer ID`.
- The distributable ZIP is `/Users/fabian/projects/keyway/.build/distribution/Keyway-0.1.0.zip`; its SHA-256 is `b4b9e285c3484c41a7823b269b8c1c1fe86d1c3d19d9da35fc7660c47eba4e96`.
- The previous and final apps have the same bundle identifier, team identifier, and designated requirement. Accessibility and Input Monitoring remained granted after replacement.
- The final app restart asked the already-installed Chromium extension to reload once, replacing the browser-owned stale native host without restarting or reloading any tab. The live host then ran from `/Users/fabian/Applications/Keyway.app/Contents/Helpers/keyway-chromium-native-host`, every manifest pointed at that path, and Settings reported the extension connected with no active browser media.
- The exact-Suno overlay transport/state-restoration smoke passed immediately before this lifecycle-only reconnect change. The final installed build's reconnect was verified without commanding or focusing a user browser tab.
- Killing both installed MediaRemote helpers produced replacements, and the next targeted QuickTime command succeeded. The isolated QuickTime document was then closed.
- The final Spotify Settings wording was inspected live, and its `Check` action preserved the correct split state: Desktop Connect token missing, Web API sign-in valid.

## Bugs fixed in this pass

- Replaced content-script `crypto.randomUUID()` with one unconditional `crypto.getRandomValues` identifier path, so the extension can initialize on insecure HTTP pages.
- Made the Command Center route shield publish actual playing/paused state instead of forcing the Touch Bar to remain in play mode.
- Removed the duplicate AppKit Settings window. Cmd+, and both menu-bar Settings actions now invoke the one SwiftUI Settings scene, with regular-app activation only while it is visible.
- Replaced the inert legacy `showSettingsWindow:` call with the canonical application-menu Settings command and its real menu-item sender.
- Removed the one-method Accessibility automation wrapper and query the shared permission API directly.
- Removed the one-case desktop transport backend enum/switch and dispatch Spotify AppleEvents through direct fail-closed target guards.
- Reused that single desktop-target eligibility decision at submission time instead of maintaining a second copy.
- Removed the unused combined Sonos coordinator-removal operation and narrowed the Spotify playback observer protocol to the operations consumed by the app.
- Added `scripts/hitl_touchbar_playback_state_check` for the physical Touch Bar state transition.
- Kept the shortcut runtime permission report synchronized when either Accessibility or Input Monitoring changes, while suppressing unchanged two-second status rewrites.
- Removed the dead route-status model and duplicate automatic-target resolution, so each media command sorts and resolves the cached target set once.
- Made DNS-SD command failures visible instead of converting them into an empty Sonos result, while treating the runner's expected collection timeout as success.
- Declared Sonos Bonjour and local-network access in the app plist, and removed unconditional “enabled” Settings indicators that could not prove a speaker was visible.
- Made the browser-audio verifier compile the production `SonosRoomName` implementation instead of maintaining a second copy.
- Removed the unused `gone` media-source state and duplicate target-only views; `SourceRow` is now the canonical source/overlay model.
- Removed unreachable optional Sonos-target branches and verified the selected-room/group scope plus `Port` member fallback through public volume and mute actions.
- Removed duplicate group-edit orchestration and deleted the unused Sonos runtime, playback-service, output-preference, and coordinator-replacement layers.
- Planned each Sonos group-membership change once, then reused that value for execution, optimistic selection, and observation.
- Made the parent playback controller the sole owner of group-edit operation state and kept the child controller limited to rows and suggestions.
- Kept the chosen Sonos room and volume controls available while Spotify is paused, playing on a non-Sonos device, or its Web API authorization needs attention, without falsely labeling an unmatched device as Spotify-on-Sonos.
- Removed the one-use Spotify handoff readiness policy and switched directly on the two real readiness inputs.
- Made Spotify token status truthful: corrupt Desktop files and service failures surface as check failures, missing or revoked credentials remain actionable unavailable states, and a server-rejected access token gets one refresh-and-retry before sign-in is declared invalid.
- Sized the media-target overlay for its command header so the footer is no longer clipped.
- Replaced three CLI argument scans and their hidden unchecked index dependency with one validated parsing pass.
- Reworked the overlay browser smoke to toggle and restore mute only after reflected state arrives.
- Made the QuickTime routing smoke close only the exact document it created.
- Reloaded the Chromium extension once at app startup so an app update cannot leave the browser connected to a native host inside the discarded app bundle.
- Removed stale browser-extension, modifier-click chooser, and machine-specific path claims from the current product and acceptance documentation.

## External checks still required

1. Securely copy `spotify-desktop-connect-tokens.json` from a working Keyway Mac. The file is not present on this Mac, it does not sync through Spotify Web API sign-in, and it is required for Spotify-to-Sonos handoff.
2. Run the actual Spotify-to-`Kitchen` Sonos handoff after that Desktop Connect credential is present.
3. Press Play/Pause once on the physical Touch Bar for the final hardware-only confirmation; generated media-key events are intentionally rejected by Keyway.

A real existing YouTube tab was intentionally left untouched. Exact-tab browser behavior passed against the user's Suno tab and in the isolated Chromium extension suite.

Spotify Web API authorization is complete and is not the blocker. The only missing Spotify credential is the device-local Desktop Connect token file from a working Keyway installation.
