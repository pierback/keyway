# Keyway Acceptance Runbook

Keyway is complete only when this runbook passes on a fresh local install without manual code changes, debug-only commands, or skipped checks. If a check cannot pass because the scope changes, update `prd-keyway-full-implementation.md` and this runbook in the same change with the explicit reason.

## Preconditions

- macOS development machine with Xcode and Swift toolchain installed.
- Existing old Sonos Handoff app and support directory may remain installed.
- Existing Sonos Handoff config/token files may exist at `~/Library/Application Support/sonos-handoff`.
- Spotify, at least one browser or browser-wrapper media session, and QuickTime are available for manual media-target checks.
- Real Sonos smoke checks require the user's local Sonos network and Spotify account state.
- Keyway should request Accessibility permission itself when it cannot create the media-key event tap. Approve the installed Keyway app if macOS shows the prompt; macOS requires this for any app-level event tap that suppresses hardware media keys.

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
- [ ] Start at least one browser or browser-wrapper Now Playing session.
- [ ] Confirm Keyway lists both as Media Targets with correct app names and metadata.
- [ ] Play local media in QuickTime.
- [ ] Confirm QuickTime appears as a Media Target with correct metadata.
- [ ] Confirm arbitrary audible apps that are not Now Playing clients do not appear as Media Targets.

## 6. Transport Routing

- [ ] Confirm play/pause is intercepted and suppressed, then re-dispatched by Keyway.
- [ ] Confirm next is intercepted and suppressed, then re-dispatched by Keyway.
- [ ] Confirm previous is intercepted and suppressed, then re-dispatched by Keyway.
- [ ] Confirm routing policy: single target.
- [ ] Confirm routing policy: Focused Target, including foreground Media Target and prominent Media Target window on the pointer display.
- [ ] Confirm routing policy: Pinned Target.
- [ ] Confirm routing policy: Recent Target.
- [ ] Confirm routing policy: chooser when ambiguous.
- [ ] Confirm hardware volume and mute keys are not intercepted.

## 7. Overlay

- [ ] Confirm Keyway shows a polished Raycast-like centered overlay.
- [ ] Confirm overlay appears on the display containing the mouse pointer.
- [ ] Confirm overlay has no search field.
- [ ] Confirm Up/Down changes selected target.
- [ ] Confirm Enter routes the Pending Command.
- [ ] Confirm Escape cancels the Pending Command.
- [ ] Confirm Tab toggles Expanded Controls.
- [ ] Confirm number keys quick-select targets in compact mode.
- [ ] Confirm `P` pins and unpins the selected target.

## 8. Audio Controls

- [ ] Confirm Expanded Controls support Sonos volume.
- [ ] Confirm Expanded Controls support Sonos mute.
- [ ] Confirm Expanded Controls support Spotify Active Device Volume when token/device state allows.
- [ ] Confirm browser volume is clearly disabled when no no-extension backend exists.
- [ ] Confirm no browser extension is required.

Repeatable browser disabled-state smoke:

```bash
KEYWAY_APP="$HOME/Applications/Keyway.app" /Users/f.pieringer/projects/keyway/scripts/smoke_overlay_browser_controls
```

This smoke requires at least two active Now Playing targets, including one browser or browser-wrapper target, so the routing policy opens the chooser instead of auto-routing a single target. It verifies the actual overlay exposes `Expanded Controls`, `Browser`, `Disabled`, and `Volume disabled without browser extension` through Accessibility.

## 9. Routing Confirmation

- [ ] Trigger automatic routing without the overlay.
- [ ] Confirm Keyway posts a native macOS notification, not a custom top-of-screen popup.
- [ ] Confirm the notification names the target and command.
- [ ] Confirm repeated automatic routes replace the existing Keyway status notification instead of stacking unique cards.
- [ ] Confirm no Keyway chooser or legacy HUD window appears for automatic routing.

Repeatable transport routing and native-notification smoke:

```bash
KEYWAY_APP="$HOME/Applications/Keyway.app" /Users/f.pieringer/projects/keyway/scripts/smoke_transport_routing_confirmation
```

This smoke pins a safe Now Playing target, posts synthetic Play/Pause, Next, and Previous media-key events through the HID event tap, verifies Keyway suppresses and routes each command by Pinned Target, checks native-notification request logs, rejects legacy custom Keyway popup windows, and fails on MediaRemote helper parse errors. When QuickTime Player is the target and no QuickTime Now Playing session exists, it creates and cleans up a temporary silent local media file.

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

## 11. Non-Goals

- [ ] Confirm hardware volume and mute keys are not intercepted.
- [ ] Confirm no browser extension is required.
- [ ] Confirm no commercial publishing, App Store, or notarization flow is required to pass this runbook.

## Final Documentation

- [ ] Update `prd-keyway-full-implementation.md` with any explicit scope changes.
- [ ] Update this runbook with any accepted scope changes.
- [ ] Update README and user-facing local install instructions.
- [ ] Document the final verification result and any residual risks.
