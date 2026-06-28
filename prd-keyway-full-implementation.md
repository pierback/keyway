# PRD: Keyway Full Implementation

**Date:** 2026-05-20

---

## Problem Statement

### What problem are we solving?

macOS routes transport keys opaquely when multiple media sessions exist. A browser video, Spotify, QuickTime, and Sonos/Spotify handoff can compete for play/pause, next, previous, and volume intent, leaving the user without a clear way to decide which target should respond.

### Why now?

The current Sonos Handoff app already owns much of the required macOS infrastructure: a menu bar shell, Accessibility-gated event tap, global shortcuts, HUD feedback, Sonos output control, and Spotify/Sonos state. Keyway expands that foundation into a broader media-control utility instead of keeping Sonos as the product identity.

### Who is affected?

- **Primary user:** A macOS power user who regularly has multiple active Now Playing sessions and wants hardware transport keys to target the intended app.
- **Secondary user:** The existing Sonos Handoff user who needs Spotify-to-Sonos handoff and Sonos volume behavior preserved inside Keyway.

---

## Proposed Solution

### Overview

Keyway is a polished local macOS menu bar utility that routes play/pause, next, and previous to the intended Now Playing Media Target, preserves Sonos Handoff as a capability, and provides a Raycast-like Media Overlay for resolving ambiguity and controlling supported target volume.

### User Experience

#### User Flow: Automatic Transport Routing

1. User presses play/pause, next, or previous.
2. Keyway suppresses the original transport-key event.
3. Keyway resolves the command target automatically using the Target Selection Policy.
4. Keyway dispatches the command to the target.
5. If no chooser was needed, Keyway posts a native macOS notification naming the target and command.

#### User Flow: Ambiguous Target Chooser

1. User presses a Transport Key while multiple plausible targets exist.
2. Keyway opens the centered Command Palette Overlay on the pointer display.
3. User selects a target with arrows, Enter, or a number key.
4. Keyway sends the Pending Command to that target, updates session Recent Target memory, and closes.

#### User Flow: Expanded Controls

1. User opens or expands the Media Overlay with `Tab`.
2. Keyway reveals target-specific controls.
3. Sonos and Spotify volume controls are available where the backend supports them.
4. Browser volume controls are disabled when they would require a browser extension.

#### User Flow: Settings

1. User opens Keyway Settings from the always-visible menu bar item.
2. Settings appears as a normal macOS window and is reachable through Cmd-Tab while visible.
3. User reviews permissions, helper health, routing behavior, overlay behavior, Sonos status, Spotify status, shortcuts, and diagnostics.

### Design Considerations

- The Media Overlay uses a Raycast-like centered command palette visual style.
- The overlay has no search field; it uses a non-editable Command Header.
- The menu bar item is always visible.
- Keyway is menu-bar-first, but Settings behaves like a normal app window while visible.
- Hardware volume and mute keys remain normal macOS behavior in the initial implementation.

---

## End State

When this PRD is complete, the following will be true:

- [ ] The existing app is reframed as Keyway with a new bundle identity and app support directory.
- [ ] Keyway can import old Sonos Handoff config without modifying the old app's files.
- [ ] Existing Sonos Handoff behavior is preserved inside Keyway.
- [ ] Keyway intercepts and suppresses play/pause, next, and previous while enabled.
- [ ] Keyway lists MediaRemote Media Targets through a long-running helper.
- [ ] Keyway routes Transport Keys using the resolved Target Selection Policy.
- [ ] The Media Overlay supports compact routing, focused-target selection, expansion, number selection, cancellation, and command dispatch.
- [ ] Native macOS notification confirmation appears after successful automatic routing.
- [ ] Sonos and Spotify volume controls work where supported by existing or feasible backends.
- [ ] Browser transport routing works where exposed through Now Playing; browser volume is clearly unsupported when no no-extension backend exists.
- [ ] Keyway Settings exposes the full configuration and diagnostics surface needed to run the app daily.
- [ ] No commercial publishing, App Store, licensing, or marketing release work is required.

---

## Success Metrics

### Quantitative

| Metric | Current | Target | Measurement Method |
|--------|---------|--------|--------------------|
| Transport routing latency | Unknown | Feels immediate for daily use | Manual smoke test with Spotify and browser target |
| Helper startup recovery | None | Helper status visible and recoverable | Settings diagnostics |
| Sonos regression coverage | Existing tests/scripts | Existing core behavior still passes | Existing regression gate plus targeted smoke tests |

### Qualitative

- The app can replace the current Sonos Handoff menu bar app on the user's Mac.
- The Media Overlay feels polished enough for daily use.
- Routing decisions are understandable through current media target, focus, session recency, and native notification feedback.

## Implementation Status

As of 2026-05-20, the main implementation is present on branch `keyway-planning`. `scripts/acceptance_preflight` now reports `acceptance_preflight=pass` on the local machine when Spotify playback is active on the discoverable Sonos `Port` room. The deterministic regression gate and the real-device smoke gate pass. The remaining blockers are manual verification blockers, not accepted scope removals:

- Accessibility is granted to the installed `com.fpieringer.Keyway` bundle on the local machine, and Keyway persists `mediaFallback=enabled` in `~/Library/Application Support/keyway/shortcut-runtime-status.json`.
- `SONOS_HANDOFF_REAL_DEVICE_SMOKE=1 SONOS_HANDOFF_ROOM=Port scripts/regression_gate` passes, including CLI Spotify-to-Sonos handoff, menu-bar handoff, and menu-bar Sonos volume smoke paths.
- Sonos mute was verified directly through the local CLI and restored to its original state.
- Expanded Controls browser volume disabled-state is verified by `scripts/smoke_overlay_browser_controls`, which opens the actual overlay, toggles controls with Tab, selects the browser target, and confirms the visible disabled no-extension state.
- QuickTime target discovery has been verified with local media playback.
- Settings normal-window behavior has been verified through the menu bar UI; System Events reports Keyway as visible and not background-only while Settings is open.
- Focused Target routing now checks the global foreground Media Target first, then a prominently visible, unobscured Media Target window on the display containing the pointer before falling back to Recent Target or chooser when no single current target is already active.
- Status feedback now uses native macOS notifications through `UNUserNotificationCenter`; the legacy top-of-screen custom HUD panel implementation has been removed from the app, and status notifications reuse a stable identifier so repeated route confirmations replace instead of stacking.
- `scripts/smoke_transport_routing_confirmation` verifies focused-target automatic routing for Previous and Next, absence of chooser/legacy custom popup windows during automatic routing, and clean MediaRemote helper command parsing. Play/Pause is chooser-first and is covered by playback chooser probes/HITL checks.
- Spotify Active Device Volume still needs a run against an unrestricted Spotify active device; the current active device is Sonos `Port`, which Spotify reports as `restricted=true`.
- Live Helium hardware Play/Pause selected-row routing has passed. Full live hardware Next/Previous routing and overlay keyboard behavior still need manual runs.

The current verification record is maintained in `docs/verification-log.md`.

---

## Acceptance Criteria

### App Identity and Transition

- [ ] App display name is Keyway.
- [ ] Keyway uses a new bundle identifier.
- [ ] Keyway uses `~/Library/Application Support/keyway`.
- [ ] Existing `~/Library/Application Support/sonos-handoff` files are not modified.
- [ ] Keyway can perform one-time Config Import from the old support directory.
- [ ] Keyway and old Sonos Handoff are treated as distinct apps during development.

### Sonos Capability Preservation

- [ ] Existing Sonos output discovery still works.
- [ ] Existing Spotify-to-Sonos handoff still works.
- [ ] Existing Sonos volume and mute behavior still works.
- [ ] Existing Spotify token readiness and Sonos settings remain accessible.
- [ ] Presentation may change, but core Sonos behavior is a strict regression boundary.

### MediaRemote Helper

- [ ] Keyway starts a long-running MediaRemote Helper.
- [ ] Helper is hosted through `/usr/bin/perl`.
- [ ] Helper communicates with Keyway using newline-delimited JSON Helper Messages.
- [ ] Helper streams target snapshots or provides low-latency snapshot refresh.
- [ ] Helper accepts command-dispatch requests and returns command results.
- [ ] Helper failures are visible in Settings diagnostics.

### Target Selection and Routing

- [ ] Media Targets are Now Playing clients, not arbitrary audio sources.
- [ ] Target Selection Policy resolves single target, Current Media Target, Focused Target, Recent Target, then chooser for non-play-family commands.
- [ ] A new chooser session starts with row 1 selected.
- [ ] Current Media Target is automatic when exactly one target is actively playing.
- [ ] Recent Target is automatic within the current Keyway run.
- [ ] Focused Target beats Recent Target when focus is clear.
- [ ] Transport Keys are always suppressed and re-dispatched deliberately while routing is enabled.
- [ ] Hardware volume and mute keys are not intercepted.

### Media Overlay

- [ ] Overlay appears centered on the display containing the mouse pointer.
- [ ] Overlay has a Raycast-like command palette style with no search input.
- [ ] Command Header names the pending routing action.
- [ ] Compact mode supports up/down, Enter, Escape, Tab, number quick-select, and Command-Enter focus.
- [ ] Expanded Controls show target-specific volume/mute controls where supported.
- [ ] Unsupported browser volume is visible as unsupported rather than silently absent.
- [ ] Overlay closes after dispatch or cancellation.

### Audio Target Control

- [ ] Sonos volume control is available through the existing Sonos backend.
- [ ] Spotify volume means Spotify Active Device Volume.
- [ ] Spotify volume works where Spotify token/device state allows.
- [ ] Browser volume does not require a browser extension.
- [ ] Browser volume controls may be disabled when no reliable no-extension backend exists.

### Settings

- [ ] Keyway Settings is a normal macOS settings window.
- [ ] Settings is reachable through Cmd-Tab while visible.
- [ ] Settings covers General, Transport Routing, Overlay, Audio Controls, Sonos, Spotify, Shortcuts, and Advanced diagnostics.
- [ ] Menu Bar Item is always visible.
- [ ] Settings exposes Accessibility/Input Monitoring status and recovery guidance.
- [ ] Settings exposes helper status and restart/recovery actions.

---

## Technical Context

### Existing Patterns

- `/Users/f.pieringer/projects/keyway/SonosHandoffMenuBar/SonosHandoffMenuBar/App/ShortcutEventTap.swift` — existing Accessibility-gated CGEvent tap lifecycle.
- `/Users/f.pieringer/projects/keyway/SonosHandoffMenuBar/SonosHandoffMenuBar/App/ShortcutEventParser.swift` — existing media/function-key decoding pattern.
- `/Users/f.pieringer/projects/keyway/SonosHandoffMenuBar/SonosHandoffMenuBar/App/StatusHUD.swift` — native macOS notification feedback facade.
- `/Users/f.pieringer/projects/keyway/packages/SonosHandoffCore/Sources/SonosHandoffCore` — existing Sonos, Spotify, config, and volume behavior.

### System Dependencies

- macOS Accessibility permission for event tap behavior.
- Private MediaRemote framework accessed through a Perl-hosted helper.
- `/usr/bin/perl` as the helper host.
- Spotify Desktop Connect and Web API token files for existing Sonos and Spotify volume flows.
- Local Sonos network discovery and SOAP control for Sonos Outputs.

### Data Model Changes

- New Keyway app support directory.
- One-time copied config/token files from old Sonos Handoff directory.
- Shared in-memory Keyway state for Recent Target recall.
- Runtime Keyway state for overlay expansion and helper diagnostics.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Private MediaRemote behavior changes | High | High | Isolate behind MediaRemote Helper and expose diagnostics |
| Perl-hosted helper feels fragile | Medium | High | Long-running helper, NDJSON protocol, restart controls, smoke tests |
| Sonos behavior regresses during rebrand | Medium | High | Treat Sonos capability as regression boundary and run existing tests |
| Browser volume is impossible without extension | High | Medium | Mark unsupported while preserving browser transport routing |
| Shortcut/event tap conflicts with old app | Medium | Medium | Treat apps as distinct during development and expose Keyway registration status |
| Overlay becomes too complex | Medium | Medium | Keep compact routing fast; move richer controls behind Tab |

---

## Alternatives Considered

### Start a New Keyway Repo

- **Description:** Create Keyway as a fresh macOS app and migrate Sonos Handoff later.
- **Pros:** Clean naming and architecture from day one.
- **Cons:** Duplicates existing menu bar, event tap, HUD, Sonos, Spotify, and installer work.
- **Decision:** Rejected because the existing repo already owns the hard local infrastructure.

### Keep Sonos Handoff as Product Name

- **Description:** Add media target routing inside the current Sonos Handoff product.
- **Pros:** Minimal rename work.
- **Cons:** Product name would not match QuickTime/browser/Spotify media-key routing.
- **Decision:** Rejected because Keyway is broader than Sonos.

### Require Browser Extension for Browser Volume

- **Description:** Build a companion extension for per-tab browser volume/mute.
- **Pros:** Better browser control.
- **Cons:** Adds installation, permissions, browser compatibility, and maintenance scope.
- **Decision:** Rejected for the initial full implementation.

### Direct Native MediaRemote Calls

- **Description:** Call private MediaRemote APIs directly from the Swift/ObjC app.
- **Pros:** Cleaner process model.
- **Cons:** Direct calls returned empty Now Playing results on macOS 26.4.1.
- **Decision:** Rejected in favor of the Perl-hosted helper.

---

## Non-Goals

- App Store eligibility.
- Commercial publishing, notarized distribution pipeline, licensing, or marketing.
- Browser extension.
- Browser per-tab volume control when it requires a browser extension.
- Hardware volume/mute key interception.
- Public website or onboarding funnel.
- Multi-user support.
- Backward-compatible shared runtime with old Sonos Handoff.

---

## Interface Specifications

### MediaRemote Helper IPC

Helper Messages use newline-delimited JSON.

Example snapshot:

```json
{"type":"snapshot","targets":[],"activeTargetID":null}
```

Example command request:

```json
{"type":"sendCommand","requestID":"uuid","targetID":"com.spotify.client:63530","command":"playPause"}
```

Example command response:

```json
{"type":"commandResult","requestID":"uuid","ok":true}
```

### Overlay Keys

```text
Up/Down      Select target
Enter        Dispatch Pending Command to selected target
Escape       Cancel Pending Command
Tab          Toggle Expanded Controls
1-9          Compact mode: dispatch to visible target number
P            Pin/unpin selected target
Cmd+Up/Down  Expanded mode: adjust supported selected-target volume
```

---

## Documentation Requirements

- [ ] Update README from Sonos Handoff to Keyway.
- [ ] Keep Sonos capability documentation under the Sonos context.
- [ ] Document private API limitations and helper diagnostics.
- [ ] Document browser volume non-goal.
- [ ] Document local install/build flow for personal use.
