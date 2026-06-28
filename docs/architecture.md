# Architecture

## Overview

The repository is split into two layers:

```text
Menu Bar App  ---->  SonosHandoffCore
```

## Responsibilities

### `SonosHandoffMenuBar`

- owns the native macOS status item lifecycle
- exposes transfer, settings, Output volume, and Output mute actions
- keeps the native-style Sound drop-down presentation in the Menu Bar View Module
- keeps Output discovery, grouped Output selection, transfer progress, group editing, volume writes, slider debounce, and external volume reconciliation in the Playback Sync Module
- keeps global shortcut registration and key-repeat handling in the Shortcut Runtime Module
- keeps temporary shortcut and external-volume feedback in the Status HUD Module
- logs and displays the Port's reported volume and fixed-output state for volume troubleshooting
- registers Carbon global hotkeys for `Shift+F10/F11/F12`
- enables the held `fn+F10/F11/F12` key-intercept path only after Accessibility permission allows the app to intercept and suppress native media/function-key events
- delegates all non-UI work to `SonosHandoffCore`

### `SonosHandoffCore`

- shared models and errors
- config loading and saving
- keychain abstraction
- Spotify token status and playback-state verification boundaries
- Accessibility permission boundary
- public handoff Adapter through `SpotifyConnectHandoffService`
- Sonos Runtime for Spotify Connect activation orchestration and handoff verification
- Sonos Directory for actor-owned Output target resolution, speaker discovery, Spotify zeroconf metadata lookup, and target caching
- Sonos Volume Service for room-name volume actions and Spotify volume mirror handoff
- Spotify Playback Service for active Spotify device lookup, verification, and volume mirroring
- Spotify Connect Transfer Service for `addUser` activation and readiness verification
- Sonos Transfer Verification for bounded AVTransport readiness checks after activation
- Sonos Speaker Discovery for bounded local-network Output list discovery
- Sonos Room Name, Sonos Output Preference Resolver, and Sonos Output Selection Resolver for shared room matching and selected-Output fallback rules
- Speaker Volume Control State for shared selected-Output volume UI state transitions
- Sonos DNS-SD Resolver for shared Sonos browse and host resolution
- Sonos Spotify Zeroconf Client for Sonos `/spotifyzc` request construction and response validation
- Sonos Rendering Control for volume, mute, fixed-output status, and volume status
- Spotify Connect Bridge for Spotify Desktop token refresh, Sonos authorization-code exchange, active-device verification, and active-device volume mirroring
- Spotify Desktop Credential Provider for Desktop Connect token selection, refresh, and persistence
- Spotify Connect Token Client for Spotify Accounts token refresh and Spotify Connect token exchange
- Spotify Project Access Token Provider for Web API token readiness and refresh

## Important Modules

### Playback Sync

`PlaybackSyncController` is the menu app seam for user-facing playback state. The SwiftUI menu reads its published state and sends user intent to it. `SonosRoomName` lives in `SonosHandoffCore` and owns room-name normalization and equality for the full sync loop, so Output discovery, selected Output persistence, monitor reconciliation, and stale-result checks use one definition of the same Sonos room. `PlaybackOutputDirectory` owns grouped Output selection, delegates background discovery and cached discovery results to the `PlaybackDiscoveryCache` actor, then delegates selected-Output policy to `SonosOutputSelectionResolver`: preserve the visible current Output, then choose the first visible Output. `PlaybackOutputSelection` owns the live selected Output name shared by Playback Sync, startup monitor seeding, and Shortcut Volume Actions, so shortcuts target the same Output the menu currently shows before falling back to the core `Port` fallback. Group editing is derived in core through `SonosGroupMembershipResolver`, `SonosGroupMembershipChangePlanner`, and `SonosCoordinatorReplacementResolver`; the menu app can expose available rows as direct plus actions in the Output list or render the full edit list through Option/Show More, then applies the resulting add/remove/remove-coordinator changes through `SonosGroupingService` and transfers playback to the replacement coordinator with coordinator-migration verification. Background playback sync uses `SonosGroupSuggestionTracker` to keep one current group suggestion in `PlaybackGroupSuggestionStore`; the menu renders that store as an in-menu fallback row while the app also delivers a macOS notification action for the same suggestion. `PlaybackOperationGate` owns freshness tickets and cancellation for asynchronous Playback Sync work, so transfer and volume results are applied only while they still belong to the selected or loading Output, and stale work is cancelled before it can wait in the Speaker Volume Command Queue and later run against the wrong Output. `SpeakerVolumeControlState` lives in `SonosHandoffCore` and owns the selected-Output volume UI state transitions: busy, clear, slider percent conversion, local write, mute, Sonos status, and monitor snapshot application. `PlaybackSliderCommitter` owns slider editing state, debounced slider commit scheduling, and pending slider commit cancellation; Playback Sync owns only the resulting volume command and selected-Output validation. `PlaybackTransferActionController` owns menu-triggered Output transfer calls and transfer logging. `PlaybackVolumeActionController` owns menu-triggered Output volume reads/writes through the Speaker Volume Command Queue. Debounced slider writes keep dragging audible without marking the menu volume state busy, while the final release write owns the busy state and refresh path. `SpeakerVolumeCommandQueue` lives in `SonosHandoffCore` and serializes app-triggered volume reads and writes so slider commits, step changes, shortcut changes, mute toggles, monitor polls, and status refreshes cannot publish stale Sonos results out of order; it uses an explicit FIFO operation slot with a bounded waiter list so an idle menu session does not retain old operation chains, and cancelled waiters are removed before they can run stale Sonos operations. `SonosVolumeMonitor` owns external volume polling, but polling now crosses the same Speaker Volume Command Queue seam as writes and waits until an Output is selected. App startup keeps seeding the monitor through `PlaybackOutputDirectory` until discovery finds an Output, so a transient launch-time discovery miss cannot permanently disable external volume reflection. `SpeakerVolumeMonitorReconciler` lives in `SonosHandoffCore` and owns monitor snapshot, local-change overlay, and feedback decisions so local-write echo suppression hides only duplicate HUD feedback, not the latest Sonos state published back into the menu.

### Menu Bar View

`MenuBarController` owns high-level menu orchestration: app lifecycle actions, settings commands, and the Show More section. `MenuBarVolumeControl` owns the compact Sound slider row, and `MenuBarOutputSection` owns the Output list rows and transfer loading affordance. Those SwiftUI Modules render Playback Sync state and forward intent, but do not read Sonos, Spotify, or token state directly.

### Sonos Runtime

`SpotifyConnectHandoffService` is the public Adapter used by the app. It delegates to the internal Sonos Runtime, which now assembles narrower backend Modules instead of owning workflow code directly. `SonosDirectory` owns target resolution and speaker discovery. `SonosVolumeService` owns room-name volume actions and asks `SpotifyPlaybackService` to mirror confirmed Sonos volume writes back to Spotify. `SpotifyConnectTransferService` owns the handoff workflow: resolve target, exchange Spotify credentials, call Sonos Spotify Zeroconf `addUser`, run Sonos Transfer Verification, and verify Spotify active-device state. `SonosTransferVerifier` owns the bounded AVTransport checks after activation: the target must enter Spotify Connect mode, but a still-active Spotify Connect URI is treated as ready even if Sonos transport state has not reported `PLAYING` yet. This avoids false UI failures after handoff has landed but Sonos state is lagging.

### Sonos Directory

`SonosDirectory` is the core actor for resolving an Output into a cached `ConnectSonosTarget`. Its Interface is intentionally small: discover visible Sonos speakers through `SonosSpeakerDiscovery`, or resolve a room name into a target for transfer and volume actions. Zeroconf `getInfo` and cache expiry stay behind this seam for locality. The menu app uses the same target resolution behavior that transfer and volume actions use, so a missing Sonos speaker is removed from the Output list and cannot drift into a separate UI-only list.

`SonosDNSSDResolver` owns DNS-SD browse and host resolution. `SonosDiscoveryCommandRunner` owns bounded `dns-sd` process execution and output capture. `SonosDNSSDRecordParser` owns browse-line and resolve-output parsing: Sonos instances, decoded room names, speaker IDs, and resolved hosts. `SonosSpeakerDiscovery` uses the resolver for Output list discovery, while `SonosDirectory` uses it for targeted room resolution before transfer and volume actions. Keeping those paths behind one runner, resolver, and parser means discovery-driven Output removal and targeted handoff resolve failures use the same execution bounds, parsing, timeout, and visibility rules.

`SonosSpeakerDiscovery` owns the Output list policy. It asks the resolver for visible Sonos instances, resolves hosts through bounded parallel lookups, drops unresolved instances, deduplicates by speaker id, and sorts by room name. This keeps slow or missing speakers from making the menu wait for serial per-speaker timeouts.

### Sonos Grouping

`SonosZoneGroupTopology` reads Sonos group topology through `GetZoneGroupState` and parses visible groups into `SonosGroupState`. `SonosSpeakerGroup` owns Spotify-style group display names and room matching for grouped Spotify device names. `SonosGroupingService` owns local group mutations: joining a standalone speaker to a coordinator, making a member standalone, migrating a coordinator, and removing a coordinator while rebuilding the remaining group around a replacement member. The safe live validation executable `sonos-handoff-safe-grouping-check` is the mutation gate for real speakers: dry-run mode never changes state, `--prepare-silent` sets all discovered speakers to volume `0` and muted, and `--mutate` also performs join/remove/coordinator-removal validation after the same safety preparation.

### Sonos Spotify Zeroconf Client

`SonosSpotifyZeroconfClient` is the Adapter for Sonos `/spotifyzc`. It owns GET versus POST selection, form encoding, JSON validation, and metadata extraction. Sonos Directory uses it for `getInfo`; Spotify Connect Transfer Service uses it for `addUser`.

### Spotify Connect Bridge

`SpotifyConnectBridge` owns Spotify-side protocol work needed after local Sonos discovery: Connect authorization-code exchange, Web API active-device polling, and Web API active-device volume writes. `SpotifyPlaybackService` is the runtime Module that exposes active playback status, active-device verification, and queued volume mirroring to Sonos Runtime callers. `SpotifyDesktopCredentialProvider` owns Desktop Connect token selection, refresh, and persistence through `spotify-desktop-connect-tokens.json`; missing or unreadable Desktop token files become app-facing Settings recovery errors before Sonos activation starts. `SpotifyConnectTokenClient` owns Spotify Accounts token HTTP behavior for refresh-token requests and Spotify Connect token exchange, so auth failure mapping and expiry normalization stay out of the bridge. `SpotifyProjectAccessTokenProvider` owns project Web API token readiness and refresh through `ProjectWebAPITokenStore`; missing, incomplete, or malformed project tokens become app-facing sign-in recovery errors before active-device verification or volume mirroring attempts network work. `SpotifyActiveDeviceWaiter` owns the bounded polling loop and exposes explicit policies for transfer verification versus volume mirroring: transfer waits for the selected Output to be active and playing, while volume mirroring waits only for the selected Output to become active. This keeps Spotify credential and player-state rules out of Sonos volume and transfer workflows while keeping token persistence and polling rules local to their Modules.

`SpotifyVolumeMirrorQueue` owns the mirror scheduling policy behind Spotify Playback Service. Sonos Volume Service queues volume mirroring as non-blocking best effort after Sonos confirms the local volume write, so Spotify API latency cannot keep menu controls busy. The queue runs one mirror request at a time and coalesces queued intermediate writes to the latest room/volume, preventing held shortcuts and quick slider changes from building a stale Spotify API backlog. Before issuing the Web API volume write, `SpotifyConnectBridge` polls the active device with a hard attempt bound so a handoff that has landed on Sonos but has not yet propagated through Spotify does not drop the first volume mirror.

### Project Web API Token Store

`ProjectWebAPITokenStore` owns the `project-webapi-token.json` file format used by Spotify Web API auth, readiness checks, active-device verification, and active-device volume mirroring. `SpotifyAuthCoordinator` writes login results through it, `ConnectTokenStatusStore` validates readiness through it, and `SpotifyConnectBridge` refreshes expired tokens through it. Hard-cutover rule: a project token without a non-empty `client_id` is incomplete and requires login again.

### Spotify Auth Callback Server

`SpotifyAuthCallbackServer` owns the local HTTP callback listener used during Spotify login from the app. It owns `NWListener` setup, browser-open timing, callback timeout, and browser response text. `SpotifyAuthCallbackRequest` owns callback path matching, state validation, and authorization-code extraction, keeping HTTP parsing out of the listener lifecycle. `SpotifyAuthorizationRequest` owns callback state, redirect URI wiring, scope selection, and PKCE verifier/challenge generation. `SpotifyAuthCoordinator` now keeps the auth flow orchestration and token exchange only: it opens the authorization URL, exchanges the returned authorization code, and persists the resulting project Web API token.

### Shortcut Runtime

`VolumeHotkeyController` is the app seam for global volume shortcuts. It owns shortcut policy: parsed shortcut outcomes, held-key repeat coalescing, Carbon duplicate suppression, mute handling, and volume intent dispatch. `AppDelegate` configures it with the same live App Environment used by the menu, so shortcuts do not construct a separate `SpotifyConnectHandoffService` or `ConfigStore`. `ShortcutCarbonHotKeyRegistrar` owns Carbon handler installation and plain function-key registration. `ShortcutEventTap` owns the Accessibility-gated `CGEvent` tap lifecycle and is the sole handler for `Shift+fn+F10/F11/F12`, so fn shortcuts cannot double-fire through Carbon and the event tap. `ShortcutEventParser` owns OS key-code decoding. `ShortcutRuntimeReporter` owns shortcut readiness transitions into `ShortcutRuntimeStatus`, including Accessibility permission, fn fallback state, and Carbon registration state. `ShortcutVolumeActionController` owns live Output lookup through Playback Output Selection, in-flight shortcut write coalescing, HUD feedback, and Volume Monitor echo suppression; when no live Output exists yet, it falls back through `SonosOutputPreferenceResolver`. Shortcut volume writes cross the shared Speaker Volume Command Queue seam, shared live volume Adapter, and shared selected-Output seam, so shortcut writes, menu writes, monitor reads, and Spotify volume mirroring stay ordered inside one runtime graph. The result is locality: Carbon, event-tap, key decoding, status reporting, and Sonos volume writes can change independently.

### Media Target Router

`MediaTransportActionController` owns the Target Selection Policy for Transport Keys. It refreshes MediaRemote state, sorts the available Media Targets, and routes non-play-family commands in this order: single target, Current Media Target when exactly one target is actively playing, Focused Target, Recent Target from shared in-memory selection memory, then Media Overlay chooser. Play-family commands stay chooser-first whenever multiple targets exist. Focused Target first matches the global foreground application against Media Targets, then checks for a prominently visible, unobscured layer-0 Media Target window on the display containing the mouse pointer. This makes a visible browser-wrapper or QuickTime window win over stale session recency when another non-media app is technically frontmost, without routing to a covered media window. `MediaTargetSelectionMemory` owns the shared in-memory Recent Target recall used by source focus and transport routing, while `MediaTargetOverlayController` owns the centered Command Palette Overlay, keyboard routing, focused-target selection, and Expanded Controls.

### Status Feedback

`StatusHUD` is the presentation Module for transient shortcut and external-volume feedback. It exposes the small feedback Interface used by playback and shortcut Modules: show progress, finish with a message, show volume, and show mute state. The implementation uses native macOS notifications through `UNUserNotificationCenter`; Keyway does not own or show a custom top-of-screen status panel. Status notifications reuse stable identifiers so repeated routing and volume confirmations replace instead of stacking unique notification cards.

## Why Spotify Available-Device Transfer Is Excluded

The product goal is to keep Spotify as the controller after handoff. The Spotify Web API available-devices endpoint can omit Sonos speakers, so the core flow does not rely on Spotify Web API device discovery or Web API transfer:

1. select a visible Output row
2. resolve the Sonos speaker through Sonos Directory
3. activate its Spotify Connect endpoint through Sonos Spotify Zeroconf Client
4. verify that Sonos entered Spotify Connect mode and request Play
5. poll Spotify active-device state as best-effort confirmation

The Sonos calls are limited to activating Spotify Connect and adjusting volume. Track control remains in Spotify after handoff.
