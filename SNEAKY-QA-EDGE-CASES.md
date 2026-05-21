# Keyway Sneaky QA Edge Case Report

**Date:** 2026-05-21  
**Scope:** Static QA pass over current working tree, focused on ways a user can make routing, helper IPC, and overlay state behave incorrectly.  
**Method:** Used `ast-grep` for repository-wide code search per project instructions, then read targeted files directly. No runtime or real-device smoke tests were executed for this report.

## Summary

I found 11 edge cases worth testing or fixing. The highest-risk issues are around stale MediaRemote state: Keyway can keep showing and routing to targets after the helper has failed, and can display a success notification even when the helper is disconnected. The next class is routing ambiguity: the current policy collapses multiple sessions from the same app into one identity, and source-app playback changes are only picked up by snapshots, not by a push subscription.

## Fix Status

Applied on 2026-05-21:

| Finding | Status | Fix |
| --- | --- | --- |
| SQA-1 | Fixed | MediaRemote targets are cleared on helper stop/failure, routing is gated on a live helper, and command success is shown only after a `commandResult`. |
| SQA-2 | Fixed | Focused/selected targets are evaluated before the current playing fallback when multiple targets exist. |
| SQA-3 | Fixed | Pinned/recent routing now stores exact target IDs with conservative app fallback only when it is unambiguous and not browser-like. |
| SQA-4 | Fixed | Helper command dispatch now requires an exact target ID; bundle-level fallback was removed from command matching. |
| SQA-5 | Fixed | Routing and chooser display wait for a request-specific snapshot response instead of using a fixed 180 ms sleep, and abort if a stale cache cannot be refreshed. |
| SQA-6 | Fixed | Helper stdout framing is capped; oversized newline-free output clears the buffer and fails/restarts the helper path. |
| SQA-7 | Fixed | Expanded overlay row clicks select rows; routing stays on Enter/non-expanded row click. |
| SQA-8 | Fixed | Audio snapshot updates are generation-guarded and only apply if the selected target still matches. |
| SQA-9 | Fixed | Helper notifications trigger debounced refresh, and hardware-key routing waits for a fresh snapshot when cache age is stale. |
| SQA-10 | Fixed | The menu bar Now Playing card suppresses stale metadata behind a refresh state while an old snapshot is being updated. |
| SQA-11 | Fixed | Exact target IDs are preferred and browser-like app fallback is intentionally rejected to avoid retargeting a different tab/session. |

## Findings

### SQA-1 — Stale targets survive helper failure and can produce false route success

**Severity:** High  
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaRemoteController.swift:228`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTransportActionController.swift:277`

When the MediaRemote helper exits, `handleTermination` clears `process` and `inputPipe`, then calls `markFailed`, but it leaves `targets` and `activeTargetID` intact. `MediaTransportActionController.route` only checks `mediaRemoteController.targets`, not helper health. A later Play/Pause key can choose a stale target, call `send`, hit `inputPipe == nil`, and still show `Play/Pause -> Spotify` as routed.

**Break scenario:** Start Spotify, let Keyway discover it, kill the helper process, then press Play/Pause. The original hardware event is swallowed, Keyway reports a route, but no command is sent.

**Expected:** Helper failure should invalidate routable targets or make routing fall back to pass-through / explicit failure UI.

**Suggested fix:** Clear `targets` and `activeTargetID` on helper stop/failure, or gate `route`/`send` on `health.state == .running`. `send` should return success/failure so `MediaTransportActionController` only shows success after a confirmed `commandResult`.

### SQA-2 — Focused paused media can lose to a single background playing target

**Severity:** High  
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTransportActionController.swift:235`

The domain model says focused target should win before pinned/recent fallback. The current implementation returns the only playing target before checking focus:

```swift
let playingTargets = targets.filter(\.isCurrentlyPlaying)
if playingTargets.count == 1, let playingTarget = playingTargets.first {
    return (playingTarget, .current)
}
```

**Break scenario:** Spotify is playing in the background. QuickTime is foreground and paused but still exposed as a Media Target. Press Play/Pause expecting QuickTime to resume. Keyway routes to Spotify and pauses it instead.

**Expected:** A clear focused target should receive the command even if another target is currently playing, or the chooser should appear if that decision is intentionally ambiguous.

**Suggested fix:** Move focused-target evaluation before the single-playing-target shortcut, or add a test that codifies why background playback should override foreground intent.

### SQA-3 — Pin/recent/selected identity cannot distinguish multiple sessions from the same app

**Severity:** High  
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTargetPreferenceStore.swift:30`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTransportActionController.swift:288`

Pinned, recent, and in-memory selected targets store `target.routingIdentity`, which is usually a bundle identifier. For browsers and wrapper apps, two distinct MediaRemote clients can share the same bundle or parent bundle.

**Break scenario:** Chrome exposes two Now Playing sessions, such as YouTube and a web player. Select or pin the second one. Routing later matches the first target with the same routing identity, especially after sorting changes by playback state/freshness.

**Expected:** User selection should be stable at the Media Target level, not only the application level, at least while the exact target remains available.

**Suggested fix:** Store a compound identity: exact `id` first, plus bundle fallback for cross-launch persistence. Matching should prefer exact ID and only fall back to bundle identity when the exact target is absent.

### SQA-4 — Helper command matching also falls back to bundle identity, so duplicate clients are vulnerable

**Severity:** Medium  
**File:** `MediaRemoteHelper/KeywayMediaRemoteShim.m:189`

`KeywayClientMatchesTarget` matches `targetID` against exact client ID, bundle ID, or parent bundle ID. The app currently sends exact `target.id`, but the fallback means any future caller or degraded persisted identity can target the first client with that bundle.

**Break scenario:** A test harness or future code path sends `com.google.Chrome` instead of `com.google.Chrome:<pid>`. The helper sends the command to the first Chrome client returned by MediaRemote, not necessarily the one the user selected.

**Expected:** Command dispatch should require an exact target ID unless the UI is explicitly in an app-level routing mode.

**Suggested fix:** Remove bundle fallback from helper command matching. Keep fallback matching in UI decision code only, where ambiguity can be resolved before dispatch.

### SQA-5 — Fixed 180 ms snapshot grace period can drop or misroute first commands

**Severity:** Medium  
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTransportActionController.swift:88`

When no targets are currently cached, `route` asks the helper for a snapshot and waits a fixed 180 ms before checking again. The helper snapshot path can wait up to 5 seconds. A cold helper, slow MediaRemote response, or app just starting playback can easily exceed 180 ms.

**Break scenario:** Launch a media app and immediately press Play/Pause. Keyway suppresses the hardware key, shows "No Media Target" after 180 ms, and the actual snapshot arrives later.

**Expected:** The pending command should wait for the specific refresh response, time out with a deliberate threshold, or pass through when Keyway cannot make a fresh routing decision.

**Suggested fix:** Track request IDs and complete routing from the corresponding `snapshot` response. Avoid using stale `targets` after a blind sleep.

### SQA-6 — Helper stdout buffering is unbounded for a malformed or newline-free response

**Severity:** Medium  
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaRemoteController.swift:167`

`handleOutput` appends all helper stdout to `outputBuffer` and only drains it when a newline appears. There is no maximum line size, no recovery if a newline never arrives, and no reset on parse errors.

**Break scenario:** The helper or private framework path emits a huge JSON line, binary garbage, or a partial line before wedging. Keyway can grow memory indefinitely while the helper still appears connected.

**Expected:** IPC framing should have a maximum line length and treat oversized/malformed frames as helper failure.

**Suggested fix:** Cap `outputBuffer` to a sane size, clear it on overflow, and restart the helper with a precise failure message.

### SQA-7 — Expanded overlay mouse click still routes instead of selecting

**Severity:** Low  
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTargetOverlayController.swift:386`

Keyboard behavior changes in expanded mode: number keys select rows without dispatching. Mouse behavior does not change: each row is a `Button` whose action calls `onChoose(target)`, while selection is only a simultaneous gesture.

**Break scenario:** Open expanded controls to inspect two targets. Click the second row expecting to select it and inspect its controls. The overlay closes and dispatches the pending command.

**Expected:** Expanded mode should make row click select, with a separate explicit route action, or it should visually communicate that clicking still routes.

**Suggested fix:** Pass `model.expanded` into row behavior. In expanded mode, row click should call `onSelect(index)` only.

### SQA-8 — Async audio snapshots can apply to the wrong selected target

**Severity:** Low  
**File:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTargetOverlayController.swift:237`

`refreshAudioSnapshot` captures `selectedTarget`, starts an async task, and always assigns the result to `model.audioSnapshot` when it completes. Rapid selection changes or delayed volume refreshes can let an older task overwrite newer UI state.

**Break scenario:** Open expanded controls, move quickly across a browser target and Spotify target while Spotify/Sonos status calls are slow. The browser detail or enabled controls can represent a previous selection.

**Expected:** Only the latest snapshot request should update the model, and the selected target should still match before assignment.

**Suggested fix:** Add a monotonically increasing snapshot request token or compare the captured target ID with `model.selectedTarget?.id` before assigning.

### SQA-9 — Source-app playback changes are only eventually consistent

**Severity:** Medium  
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaRemoteController.swift:144`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/KeywayStatusItemController.swift:108`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTransportActionController.swift:88`

Keyway starts a MediaRemote helper at launch and refreshes snapshots every 5 seconds. It also requests a refresh when the menu opens, the overlay opens, or a transport key is pressed. There does not appear to be a MediaRemote notification subscription that pushes source-app playback changes into Keyway immediately.

**Break scenario:** Pause Spotify from the Spotify app, then immediately press the hardware Play/Pause key. Keyway can still route based on the cached snapshot that says Spotify is playing. The new snapshot has been requested, but routing already read `mediaRemoteController.targets`.

**Expected:** For a command-routing app, a direct source-app state change should not leave Keyway making automatic decisions from stale playback state.

**Suggested fix:** Treat source-app snapshots as versioned/freshness-bound data. If the cache is older than a short threshold during a hardware key event, wait for the requested snapshot response or show the chooser instead of auto-routing from stale state.

### SQA-10 — Menu bar Now Playing card can show old metadata after source app changes

**Severity:** Low  
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/KeywayStatusItemController.swift:314`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/KeywayStatusItemController.swift:461`

The menu bar card derives its title, artist, progress, and active row from the cached `mediaRemoteController.targets`. Opening the popover requests a snapshot, but the UI can render the previous cache first. If the source app changed track, paused, or stopped just before opening Keyway, the first visible state can be wrong until the helper responds.

**Break scenario:** Skip to the next track in Spotify, immediately open the Keyway menu, and inspect the Now Playing card. It can briefly show the previous track and progress.

**Expected:** The card should either mark the state as refreshing or suppress stale metadata while a refresh is in flight.

**Suggested fix:** Expose `isRefreshing` / snapshot age from `MediaRemoteController`, then let the card show a lightweight loading/refreshing state when opening from stale data.

### SQA-11 — Source-app stop/quit does not immediately clear route preferences

**Severity:** Medium  
**Files:** `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTargetPreferenceStore.swift:41`, `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaTransportActionController.swift:248`

Recent and pinned target identities survive source-app stop/quit because they are persisted by routing identity. That is useful when the same app returns, but it can combine badly with stale snapshots and same-bundle matching. If a browser tab stops exposing MediaRemote and another tab with the same browser identity appears, Keyway can treat it as the same recent/pinned target.

**Break scenario:** Pin a YouTube target in Chrome, close that tab, then start playback in a different Chrome tab. The persisted identity still matches Chrome, so the new unrelated tab can inherit the old pin/recent behavior.

**Expected:** App-level fallback should be explicit and conservative. A selected browser tab/session disappearing should not silently retarget a different tab unless the user pinned the whole app.

**Suggested fix:** Store exact target ID plus app fallback separately, and expire recent exact targets when absent from a fresh snapshot. Require explicit app-level pinning if cross-session browser behavior is desired.

## Test Ideas

- Unit-test `automaticTarget` with a focused paused target plus one background playing target.
- Unit-test exact ID preference for selected/pinned/recent matching with two targets sharing the same bundle ID.
- Add a fake MediaRemote controller that transitions from running with targets to failed with stale targets, then assert route does not show success.
- Add an IPC parser test for oversized newline-free stdout chunks.
- Add an overlay model/controller test for expanded-mode row click semantics and stale async snapshot suppression.
- Add a source-app mutation test: cached snapshot says Spotify is playing, fresh snapshot says paused/absent, hardware key arrives between the two.
- Add a popover test that marks stale metadata as refreshing instead of presenting it as current.

## Search Notes

Repository-wide searches used `ast-grep` for Swift patterns including force unwraps, `Task` usage, `FileManager` usage, `@Published` state, routing identity, and playback state checks. Plain `sed`/`nl` reads were used only after identifying specific files and line ranges.
