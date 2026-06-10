# Keyway Sneaky QA Behavior Findings

**Date:** 2026-05-21
**Scope:** Menu bar popover behavior, Settings/modal opening paths, Sonos output tile controls, and async state changes that can shift hit targets.
**Method:** Static behavioral QA over the current working tree. I used `ast-grep` for repository-wide Swift searches per project instructions, inspected the screenshot at `/Users/f.pieringer/Library/Caches/clipimg/objects/a190ec2530b3850d19a2ba34bf2697293472e9a0302914813f23dcd6dbfbb230.png`, then read the targeted AppKit/SwiftUI files directly. I did not get a deterministic runtime reproduction of the intermittent click because the menu bar app needs interactive focus/state timing.

## Summary

The screenshot points at the Sonos output section, specifically the small `toggle-group-editing` button in the Output header. That button does not directly open Settings. The only Settings path inside this tile is the conditional Spotify auth CTA (`Sign In to Spotify...`). The most plausible explanation for "clicking here sometimes opens the modal" is a timing/hit-testing issue: async Spotify auth state or animated layout changes can insert or remove a Settings-opening button while the user is clicking nearby, and SwiftUI opacity transitions can keep disappearing controls hit-testable until the transition ends.

I found several other behavior traps around the same area: outside-click dismissal lets the original click continue to the underlying UI, popover-local state persists across closes, and refresh/auth tasks can mutate the popover after it has been closed and reopened.

## Fix Status

Applied on 2026-05-21:

| Finding | Status | Fix |
| --- | --- | --- |
| BQA-1 | Fixed | Removed the inline Spotify auth Settings CTA from the Output tile so Output/header clicks cannot open Settings through a transient button. |
| BQA-2 | Fixed | Local outside-popover clicks now close the popover and consume the dismissing click. |
| BQA-3 | Fixed | Settings opening is guarded with an in-progress debounce before the Settings command is sent. |
| BQA-4 | Fixed | Removed the duplicate Diagnostics menu action that routed to Settings. |
| BQA-5 | Fixed | Popover-only UI state resets on disappear. |
| BQA-6 | Fixed | Popover appear refresh work is tracked, cancelled on disappear, and guarded with appearance generations. |
| BQA-7 | Mitigated | Output rows now reserve a stable trailing control column so join/mixer controls do not shift row hit targets. |
| BQA-8 | Fixed | Grouping mode is hidden when there are no output rows or editable group rows. |
| BQA-9 | Fixed | Removed the duplicate auth CTA path; auth state no longer creates a second Settings-opening slot inside the Output tile. |

## Findings

### BQA-1 — Output header click can be stolen by transient Spotify auth Settings CTA

**Severity:** High
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:31`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:69`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/PlaybackSyncController.swift:965`

The screenshot location maps to the `toggle-group-editing` button:

```swift
Button {
    withAnimation(MenuBarMotion.modeSwitch) {
        forceGroupEditing.toggle()
    }
}
```

That control only toggles grouping mode. The same `MenuBarOutputSection`, however, conditionally renders a `Button(action: openSpotifySettings)` when `playback.spotifyAuthRequired` is true. `spotifyAuthRequired` is set asynchronously from `PlaybackSyncController.requireSpotifyAuth`, which also changes `menuMessage` and selected room state.

**Break scenario:** Open the popover while Spotify auth state is being checked. Click the Output header/right-side checklist control as the auth-required state flips. The UI can animate the auth CTA into or out of the same tile; a disappearing or newly inserted `Sign In to Spotify...` button can receive the click and open Settings, even though the visible target looked like the Output control.

**Expected:** Clicking the Output/grouping control should never invoke Settings. Auth recovery should require a visible, stable, explicit click target.

**Suggested fix:** Make the auth CTA occupy a fixed non-overlapping slot or disable hit testing during insertion/removal transitions. Add source-specific logging to `openSettings` so future reports can distinguish `headerMenu`, `spotifyAuthCTA`, and `diagnostics`.

### BQA-2 — Outside-click dismissal forwards the same click to underlying UI

**Severity:** High
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/KeywayStatusItemController.swift:244`

The local outside-click monitor closes the popover but returns the event:

```swift
popoverLocalDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
    self?.closePopoverIfNeeded(for: event)
    return event
}
```

**Break scenario:** Click outside the popover to dismiss it, but the click lands on a window/control behind it. Keyway closes the popover and still lets the original click activate the underlying control. If the underlying control is Settings or another modal launcher, the user experiences "I clicked the popover and a modal opened."

**Expected:** A click used to dismiss the popover should not also activate an underlying Keyway control.

**Suggested fix:** For local events outside the popover/status-item frame, return `nil` after closing, or move dismissal to an AppKit popover/window behavior that consumes the dismissing click. Global outside clicks cannot be consumed, so treat those separately.

### BQA-3 — Settings opening is asynchronous and unguarded

**Severity:** Medium
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/KeywayStatusItemController.swift:140`

`openSettings` closes the popover, schedules work on the next main-queue turn, sends `showSettingsWindow:`, then activates the app. There is no "settings open in progress" guard or debounce.

**Break scenario:** Double-click Settings, click a Settings-opening item during a popover close animation, or trigger Diagnostics and Settings close together. Multiple `showSettingsWindow:` actions can be queued while activation/deactivation notifications are also closing the popover.

**Expected:** Settings should be an idempotent command: one visible Settings window, no duplicate modal/main-window surprises.

**Suggested fix:** Add a small `settingsOpenInProgress` guard or central Settings presenter. Open after popover close has completed, and ignore duplicate requests for a short interval.

### BQA-4 — Diagnostics opens Settings, so two distinct menu actions do the same modal thing

**Severity:** Medium
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/KeywayStatusItemController.swift:149`

`openDiagnostics()` currently calls `openSettings()`. In both the status item utility menu and popover menu, "Diagnostics" looks distinct from "Settings..." but opens the same Settings window.

**Break scenario:** User chooses Diagnostics expecting a diagnostic panel or helper status. The main Settings window appears instead, reinforcing the report that unrelated clicks sometimes open the main modal.

**Expected:** Diagnostics should open a diagnostic view, or the menu item should be removed/renamed until that view exists.

**Suggested fix:** Hard cutover: either implement a diagnostics section and route to it explicitly, or delete the Diagnostics action.

### BQA-5 — Popover state persists across closes, shifting the meaning of the same click

**Severity:** Medium
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:16`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/KeywayStatusItemController.swift:331`

The popover is a retained `NSPopover` with a retained SwiftUI root. Local UI state such as `forceGroupEditing` and `showSpeakersList` is `@State`, and there is no reset on disappear.

**Break scenario:** Enable grouping mode, close the popover, reopen later. The same Output tile area can still be in Group mode, with different rows/actions than the user expects. If rows also refresh at reopen, controls move while the user is clicking.

**Expected:** A menu bar control center should reopen in a predictable default state, or persisted modes should be visibly obvious.

**Suggested fix:** Reset transient popover-only state in `onDisappear`, or intentionally persist it in the model with clear visual state and tests.

### BQA-6 — Reopening the popover spawns uncancelled refresh/auth work

**Severity:** Medium
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/PlaybackSyncController.swift:157`

`appear()` starts a new untracked `Task` every time the popover appears. It runs cached output application, background refresh, active Spotify sync, and output refresh. The task is not cancelled when the popover disappears.

**Break scenario:** Rapidly open/close the menu bar popover while network/Sonos/Spotify calls are slow. Older tasks can complete after a later open and mutate `spotifyAuthRequired`, `outputRows`, `menuMessage`, and selected room state, causing stale rows or the auth Settings CTA to appear under a later click.

**Expected:** Popover-scoped refresh work should either be coalesced at the controller level or cancelled when the popover disappears.

**Suggested fix:** Store the appear task and cancel it on disappear, or move refresh coalescing into `PlaybackSyncController` with explicit generations so stale completions cannot update UI.

### BQA-7 — Small trailing controls sit beside full-row buttons with fragile hit boundaries

**Severity:** Medium
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:212`

Output rows combine a wide transfer `Button` with adjacent small buttons for group join and mixer toggle. The trailing controls are only 22 px wide and sit inside an animated row stack.

**Break scenario:** Click near the right edge of a row while a group/mixer control appears, disappears, or animates. The click can hit transfer, join, or mixer depending on the current frame. With no Sonos speakers or during refresh, this makes the popover feel like controls randomly do the wrong thing.

**Expected:** Different commands should have stable, generous hit regions and should not swap under the cursor during animation.

**Suggested fix:** Reserve a fixed trailing actions column for all row states, and disable row/action hit testing while the row is transitioning.

### BQA-8 — Empty/offline state still exposes mode controls that lead to dead ends

**Severity:** Low
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:31`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:133`

When no Sonos speakers are found, the Output section still shows the grouping-mode checklist button. Clicking it changes the header to "Group" and shows "No active Sonos group." That is technically consistent, but it is not actionable and creates another way for the same screenshot area to mutate unexpectedly.

**Break scenario:** In the offline state shown in the screenshot, repeatedly click the Output checklist while refresh/auth state is changing. The section flips between two empty modes and may expose the auth CTA or stale message below it.

**Expected:** Offline state should minimize controls that do nothing.

**Suggested fix:** Hide or disable grouping mode when there are no output rows and no active group.

### BQA-9 — Auth message and auth CTA duplicate the same state in different vertical slots

**Severity:** Low
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:59`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MenuBarOutputSection.swift:69`

When auth is required, `PlaybackSyncController` sets both `menuMessage` and `spotifyAuthRequired`. The UI can render both a text message and a Settings-opening CTA. These are outside the row `ScrollView`, so they can push the lower part of the tile while rows remain capped at 118 px.

**Break scenario:** Auth state appears while the user is trying to click output controls. Layout expands, row positions change, and the new CTA opens Settings.

**Expected:** Auth recovery should be one stable UI element, not two separately animated elements.

**Suggested fix:** Replace the duplicate message + CTA with one fixed-height auth row.

## Focused Repro Ideas

1. Open Keyway with Spotify signed out or with an expired token, then repeatedly click the Output checklist button in the screenshot while the popover first loads.
2. Force `spotifyAuthRequired` true/false every 100 ms in a debug build and click the Output header/right side. Confirm whether Settings opens from a visually hidden/fading auth CTA.
3. Open the popover, click outside onto a Keyway window button, and verify whether the outside click both dismisses the popover and activates the underlying button.
4. Toggle grouping mode, close the popover, reopen it, and verify whether the stale grouping state persists.
5. Rapidly open/close the popover during slow Sonos discovery and expired Spotify auth. Watch for stale output rows or Settings CTA insertion after reopen.

## Search Notes

- Repository-wide searches used `ast-grep` for Swift patterns including `openSettings`, `spotifyAuthRequired`, `Button` actions, `withAnimation`, `@State`, and popover/event-monitor usage.
- Targeted file reads used `sed`/`nl` only after `ast-grep` identified the relevant files and line ranges.
