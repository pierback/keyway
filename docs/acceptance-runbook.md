# Keyway Acceptance Runbook

Keyway is complete only when this runbook passes on a fresh local install without manual code changes, debug-only commands, or skipped checks. If a check cannot pass because the scope changes, update `../prd-keyway-full-implementation.md` and this runbook in the same change with the explicit reason.

## Preconditions

- macOS development machine with Xcode and Swift toolchain installed.
- Run commands from the repository root unless a step says otherwise.
- Existing old Sonos Handoff app and support directory may remain installed.
- Existing Sonos Handoff config/token files may exist at `~/Library/Application Support/sonos-handoff`.
- Spotify, at least one browser or browser-wrapper media session, and QuickTime are available for manual media-target checks.
- The unpacked Keyway Chromium extension is loaded for per-tab browser checks, and its native bridge reports connected in Keyway Settings.
- Real Sonos smoke checks require the user's local Sonos network and Spotify account state.
- Approve both Accessibility and Input Monitoring for the installed Keyway app if macOS requests them. Both are required for the event tap that suppresses hardware media keys.

## 1. Fresh Install

- [ ] Build Keyway from a clean checkout.
- [ ] Install Keyway locally.
- [ ] Launch Keyway.
- [ ] Confirm Keyway is a distinct app from old Sonos Handoff.
- [ ] Confirm Keyway uses its own bundle identifier.
- [ ] Confirm Keyway uses `~/Library/Application Support/keyway`.
- [ ] Confirm old Sonos Handoff files are not modified during build, install, or launch.

## 2. Config Import

- [ ] Record checksums for existing files in `~/Library/Application Support/sonos-handoff`.
- [ ] Run Keyway config import.
- [ ] Confirm required config/token files are copied into `~/Library/Application Support/keyway`.
- [ ] Confirm old files remain byte-for-byte unchanged.
- [ ] Confirm import failure appears in Settings with actionable recovery.
- [ ] Confirm re-running import does not silently overwrite newer Keyway state.

## 3. Sonos Regression

- [ ] Run automated package tests.
- [ ] Run the local regression gate.
- [ ] Confirm Sonos discovery works.
- [ ] Confirm Spotify-to-Sonos handoff works.
- [ ] Confirm Sonos volume works.
- [ ] Confirm Sonos mute works.
- [ ] Confirm Spotify Desktop Connect token readiness is visible.
- [ ] Confirm Spotify Web API token readiness is visible.
- [ ] Confirm local Sonos smoke paths pass when real devices are available.

## 4. MediaRemote Helper

- [ ] Confirm Keyway starts a long-lived `/usr/bin/perl`-hosted MediaRemote helper.
- [ ] Confirm Keyway communicates with the helper via newline-delimited JSON.
- [ ] Confirm helper health appears in Settings.
- [ ] Confirm helper restart is available from Settings or diagnostics.
- [ ] Kill or break the helper and confirm Keyway reports failure with restart or actionable recovery.

## 5. Media Target Discovery

- [ ] Start Spotify playback or pause with current metadata available.
- [ ] Start media in at least two Chromium tabs with the extension connected.
- [ ] Confirm Keyway lists one canonical Media Target per media tab with the correct browser, title, and playback state.
- [ ] Confirm extension rows replace same-browser legacy MediaRemote rows rather than creating duplicates.
- [ ] Confirm Spotify and the Chromium tabs are all listed as distinct Media Targets.
- [ ] Play local media in QuickTime.
- [ ] Confirm QuickTime appears as a Media Target with correct metadata.
- [ ] Confirm arbitrary audible apps that are not Now Playing clients do not appear as Media Targets.

## 6. Transport Routing

- [ ] Confirm play/pause is intercepted and suppressed, then re-dispatched by Keyway.
- [ ] Confirm next is intercepted and suppressed, then re-dispatched by Keyway.
- [ ] Confirm previous is intercepted and suppressed, then re-dispatched by Keyway.
- [ ] Confirm routing policy: single target.
- [ ] Confirm routing policy: Current Media Target when exactly one target is actively playing.
- [ ] Confirm routing policy: Focused Target, including foreground Media Target and prominent Media Target window on the pointer display.
- [ ] Confirm routing policy: Recent Target.
- [ ] Confirm routing policy: chooser when ambiguous.
- [ ] Confirm an extension-backed browser command reaches only the selected tab.
- [ ] Disconnect the extension and confirm MediaRemote transport routing still works without a global degraded-health warning.
- [ ] Confirm hardware volume and mute keys are not intercepted.

## 7. Overlay

- [ ] Confirm Keyway shows a polished Raycast-like centered overlay.
- [ ] Confirm overlay appears on the display containing the mouse pointer.
- [ ] Confirm the visible `Open Media Target Chooser` button in the menu bar popover opens the centered overlay.
- [ ] Confirm the centered overlay closes when focus moves to another app.
- [ ] Confirm overlay has no search field.
- [ ] Confirm Up/Down changes selected target.
- [ ] Confirm Enter routes the Pending Command.
- [ ] Confirm Escape cancels the Pending Command.
- [ ] Confirm Tab toggles Expanded Controls.
- [ ] Confirm number keys quick-select targets in compact mode.
- [ ] Confirm Command-Enter focuses the selected target without routing a command.

## 7A. Menu Bar Daily Controls

- [ ] Confirm left-clicking the Keyway menu bar item opens an anchored Control Center-style popover.
- [ ] Confirm the popover background is translucent/transparent outside the rounded material, not a black rectangle.
- [ ] Confirm `Active Sources` lists current Media Targets with identity, compact metadata, supported Previous/Play-Pause/Next controls, and a focus control.
- [ ] Confirm extension-backed Chromium rows expose a reflected per-tab mute control.
- [ ] Confirm the Sonos tile includes the selected/fallback room, Sonos volume, mute, and output/group controls.
- [ ] Confirm Spotify rows expose available Sonos output routes.
- [ ] Confirm right-clicking the Keyway menu bar item opens the native utility menu.
- [ ] Confirm no search field appears in the menu bar popover.

## 8. Audio Controls

- [ ] Confirm Expanded Controls support Sonos volume.
- [ ] Confirm Expanded Controls support Sonos mute.
- [ ] Confirm Expanded Controls support Spotify Active Device Volume when token/device state allows.
- [ ] Confirm an extension-backed Chromium target exposes mute and volume controls.
- [ ] Confirm browser mute changes the selected tab and the reflected state updates in Keyway.
- [ ] Confirm browser volume up/down changes the selected tab's media element without changing another tab.
- [ ] Disconnect the extension and confirm per-tab rows and controls disappear or report the exact reduced-capability state while MediaRemote transport remains available.

Repeatable browser control/degradation smoke:

```bash
KEYWAY_APP="$HOME/Applications/Keyway.app" scripts/smoke_overlay_browser_controls
```

This smoke requires at least two active Now Playing targets, including one browser or browser-wrapper target, so the routing policy opens the chooser instead of auto-routing a single target. It verifies the actual overlay exposes `Expanded Controls` and `Browser`, then either exercises extension-backed mute or verifies one of the explicit reduced-capability states through Accessibility.

Physical media-key overlay acceptance mode:

```bash
KEYWAY_PHYSICAL_MEDIA_KEYS=1 KEYWAY_APP="$HOME/Applications/Keyway.app" scripts/smoke_overlay_browser_controls
```

This mode uses a real hardware Play/Pause press to open the ambiguous-target chooser, then verifies the overlay keyboard path and browser control/degradation state through Accessibility.

## 9. Routing Confirmation

- [ ] Trigger automatic routing without the overlay.
- [ ] Confirm automatic Previous/Next routing targets the focused media app.
- [ ] Confirm the native notification names the routed command and target.
- [ ] Confirm no Keyway chooser or legacy HUD window appears for automatic Previous/Next routing.

Repeatable transport-routing smoke:

```bash
KEYWAY_APP="$HOME/Applications/Keyway.app" scripts/smoke_transport_routing_confirmation
```

This smoke focuses a safe Now Playing target, posts synthetic Next and Previous media-key events through the HID event tap, verifies Keyway suppresses and routes each command by Focused Target, requires the native routing notification to be delivered, rejects chooser/legacy custom Keyway popup windows during automatic routing, and fails on MediaRemote helper parse errors. Play/Pause is covered by chooser-specific checks because ambiguous Play/Pause must open the chooser. When QuickTime Player is the target and no QuickTime Now Playing session exists, it creates and cleans up a temporary silent local media file.

Physical media-key acceptance mode:

```bash
KEYWAY_PHYSICAL_MEDIA_KEYS=1 KEYWAY_APP="$HOME/Applications/Keyway.app" scripts/smoke_transport_routing_confirmation
```

This mode uses the same routing setup and assertions, but prompts for real hardware Previous and Next key presses instead of posting synthetic HID events. Play/Pause hardware acceptance is handled by chooser/HITL checks. It also prompts for plain hardware Volume Up, Volume Down, and Mute presses and fails if Keyway logs a plain media-key volume or mute interception.

Playback chooser routing hardening suite:

```bash
scripts/probe_playback_routing_suite
KEYWAY_PROBE_ROUTING_SUITE_TARGETS=1 scripts/probe_playback_routing_suite
```

The default suite verifies cghid event-tap readiness, generated media-key rejection, selected-row echo semantics, route-shield invariants, and HITL replay fixtures. Target mode requires both Spotify and Helium to be visible, selects each, and asserts the selected backend is `spotify_apple_event` or `chromium_extension`, with latency thresholds that reject slow `/usr/bin/osascript`-style dispatch. It fails rather than skipping when either requested target is unavailable.

Live Helium selected-row regression:

```bash
scripts/hitl_helium_playback_toggle_check
```

Start media in Helium first, then press the real hardware Play/Pause key and select Helium in the chooser. The checker verifies active-tab JavaScript state before and after selection, selected target identity, `chromium_extension` backend traces, and that the Helium media is paused after dispatch.

Chromium extension exact-tab smoke:

This command requires Node.js and a Playwright installation resolvable by Node.js.

```bash
KEYWAY_CHROMIUM_EXTENSION_ITERATIONS=10 scripts/smoke_chromium_extension_transport
```

This launches a temporary Chromium profile with two local media tabs and verifies exact-tab focus, Play/Pause, reflected mute, isolated volume, and page-backed Next/Previous. It leaves the normal browser profile untouched, but installs or repairs Keyway native-host manifests under the user's Application Support directories.

## 10. Settings

- [ ] Confirm Settings opens as a normal macOS window.
- [ ] Confirm Settings is visible in Cmd-Tab while open.
- [ ] Confirm Settings includes General.
- [ ] Confirm Settings includes Transport Routing.
- [ ] Confirm Settings includes Overlay.
- [ ] Confirm Settings includes Audio Controls.
- [ ] Confirm Settings includes Sonos.
- [ ] Confirm Settings includes Spotify.
- [ ] Confirm Settings includes Shortcuts.
- [ ] Confirm Settings includes permissions.
- [ ] Confirm Settings includes helper status.
- [ ] Confirm Settings includes diagnostics.
- [ ] Confirm Transport Routing reports Chromium extension status and exposes Repair Bridge, Reveal Extension, and Open Extensions.

## 11. Non-Goals

- [ ] Confirm hardware volume and mute keys are not intercepted.
- [ ] Confirm Safari tab-level support and Firefox support are not required; non-extension browsers remain app-level MediaRemote targets only.
- [ ] Confirm App Store and commercial publishing work are not required; builds distributed to another Mac must pass the notarized Developer ID release flow.

## Final Documentation

- [ ] Update `../prd-keyway-full-implementation.md` with any explicit scope changes.
- [ ] Update this runbook with any accepted scope changes.
- [ ] Update README and user-facing local install instructions.
- [ ] Document the final verification result and any residual risks.
