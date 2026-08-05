# Architecture

## Overview

Keyway is a macOS menu-bar application with a shared Swift package, two app-owned helper paths, and a Chromium Manifest V3 extension. The architecture is organized by responsibility rather than by process alone:

```text
SwiftUI / AppKit presentation
            |
            v
macOS app orchestration and mutable UI state
       |                         |
       v                         v
SonosHandoffCore policy      focused process adapters
(Sonos, Spotify, config)     (MediaRemote and Chromium)
                                  |
                    +-------------+-------------+
                    |                           |
                    v                           v
          Perl / MediaRemote helper     Swift native host
                                                |
                                                v
                                      Chromium MV3 extension
                         content script -> pure policy -> worker
```

The menu-bar target is the application composition root. It constructs concrete integrations and publishes state for the UI, but deterministic selection, planning, normalization, and command rules remain independently testable. Process adapters translate bounded contracts; they do not own product policy. Browser API behavior stays inside the extension.

## Layer and dependency rules

1. **Presentation — `SonosHandoffMenuBar` SwiftUI/AppKit views.** Views render published state and send user intent. They do not discover Sonos devices, call Spotify, parse browser messages, own subprocesses, or choose transport routes.
2. **Application orchestration — controllers in `SonosHandoffMenuBar/.../App`.** Controllers own user-session lifecycle, asynchronous operation gates, request correlation, and publication of UI state. They may depend on core policy and concrete integration adapters. They must not move browser-specific behavior into the app or duplicate deterministic core rules.
3. **Domain and integration policy — `packages/SonosHandoffCore`.** The package owns shared models, configuration, Sonos and Spotify workflows, normalization, planners, resolvers, verification policies, and command-line composition. It does not import or depend on the menu-bar target.
4. **Process adapters.** `MediaRemoteHelperProcess`, `MediaRemoteController`, `ChromiumBrowserExtensionController`, and the native host own concrete process/transport lifecycles. Their contracts are intentionally small: newline-delimited helper JSON, distributed-notification payloads, and Chrome native-messaging frames.
5. **External/runtime-specific implementation.** The Perl/MediaRemote helper and the Chromium extension contain framework- or browser-specific behavior. The extension's pure policy modules do not call Chrome APIs; `service_worker.js` remains the only owner of MV3 lifecycle and browser APIs.

Dependencies flow downward through these layers. Reverse dependencies, circular imports, UI-owned transport policy, native-host-owned product policy, and browser APIs outside the extension are prohibited. A new interface or wrapper is justified only when it establishes a real ownership or process boundary.

## Mutable-state and lifecycle authority

| Authority | Owned state and invariant |
| --- | --- |
| `PlaybackSyncController` and focused app action controllers | Current user-facing playback/output state, operation tickets, and cancellation. Results apply only while their ticket and selected/loading target remain current. |
| `MediaRemoteController` | Helper-pair generation, snapshot refresh gate, pending command/route-shield requests, liveness, timeout tasks, and target publication. One controller owns both helper roles as an atomic pair. |
| `MediaRemoteHelperProcess` | One subprocess generation, its process and pipes, bounded stdout buffer, and line delivery. A retired generation cannot deliver further buffered lines. |
| `ChromiumBrowserExtensionController` | Browser profile snapshots, connection generations, pending command/focus requests, profile silence, suspect targets, and app-visible Chromium targets. No other app type mutates this state. |
| `keyway-chromium-native-host` | One private connection ID and monotonic connection generation, native-message framing, browser-process identity, and notification translation. It never chooses a media candidate or app route. |
| `service_worker.js` | Profile GUID, native-port generation, snapshot epoch, Chrome listener registration, reconstructed source state, and per-tab command routing. |
| `DocumentAuthorityRegistry` | Tab/frame/browser-document/content-document authority and monotonic document generations. Late or retired document messages cannot replace current authority. |
| `media_source_selection.js` | Pure visibility, audibility, route-stickiness, deterministic candidate scoring, and target materialization. It owns no Chrome state. |
| Each content-script instance | Document ID, media-element IDs, observer/listener lifetime, and publication timer for one frame document. Invalidated extension contexts retire the whole instance. |

## Process and contract boundaries

### MediaRemote helper

The app launches separate snapshot and command helper processes but supervises them as one generation. Requests and events remain newline-delimited JSON. `MediaRemoteHelperProcess` scans each stdout chunk once, retains an unterminated suffix, compacts the shared buffer once, and validates the active run generation before and after every callback. Oversized frames fail the pair instead of being silently discarded. Delayed refresh, cache, command, and route-shield work must stop when its task is cancelled.

### Chromium extension and native host

Native messaging keeps the existing four-byte little-endian length prefix and JSON wire format. The extension sends `hello`, `snapshot`, `keepalive`, command-result, and focus-result messages. The native host enriches snapshots/results with browser identity plus private connection correlation, and strips the private connection token before a command crosses the native wire. The app rejects stale connection generations and stale request results.

Target identity remains:

```text
chromium-tab:<profile-guid>:<tab-id>
```

The persisted profile GUID survives service-worker suspension and native-host churn. Frame/media identifiers stay private routing state. `DocumentAuthorityRegistry` rejects late messages from navigated or retired documents. On worker restart, the worker restores persisted profile/epoch metadata, reconnects the native port, rebuilds candidates from content-script probes and tab state, and republishes a canonical snapshot. Listener registration remains top-level and synchronous for MV3 wake-up semantics.

The content script takes one document/open-shadow-root snapshot per publication or command pass and reuses the supported-control result for all media elements in that pass. A synchronous exception or callback-time `chrome.runtime.lastError` reporting `Extension context invalidated.` disconnects its observer and clears its timer.

### Sonos and Spotify

`SonosHandoffCore` owns Sonos discovery, grouping, AVTransport/rendering-control operations, Spotify credential/token flows, transfer, and verification policy. The menu app coordinates these operations and reflects results; it does not duplicate network, XML, token, room-name, or group-planning rules. Concrete network, DNS-SD, keychain, AppleEvent, and file access stay behind their existing focused integration boundaries.

## Repository responsibilities

### `SonosHandoffMenuBar`

- owns the native status item, menu, overlays, settings, shortcut runtime, HUD, permission onboarding, and app lifecycle;
- coordinates Output discovery and selection, transfer progress, group editing, volume actions, external-volume reconciliation, media-source routing, and helper/native-host lifecycle;
- keeps UI modules limited to rendering and intent forwarding;
- composes `SonosHandoffCore` and the concrete macOS/Chromium adapters.

### `SonosHandoffCore`

- owns shared models, errors, configuration, keychain abstractions, deterministic policy, and the public handoff adapter;
- composes Sonos discovery, grouping, rendering control, AVTransport verification, Spotify Connect/Desktop/Web API token flows, transfer, active-device verification, and volume mirroring;
- supplies the same behavior to the menu app, helper executables, semantic harnesses, and `sonos-handoff-port` without depending on presentation code.

## Important Modules

### Playback Sync

`PlaybackSyncController` is the menu app seam for user-facing playback state. The SwiftUI menu reads its published state and sends user intent to it. `SonosRoomName` lives in `SonosHandoffCore` and owns room-name normalization and equality for the full sync loop, so Output discovery, selected Output persistence, monitor reconciliation, and stale-result checks use one definition of the same Sonos room. `PlaybackOutputDirectory` owns grouped Output selection, delegates background discovery and cached discovery results to the `PlaybackDiscoveryCache` actor, then delegates selected-Output policy to `SonosOutputSelectionResolver`: preserve the visible current Output, then choose the first visible Output. `PlaybackOutputSelection` owns the live selected Output name shared by Playback Sync, startup monitor seeding, and Shortcut Volume Actions, so shortcuts target the same Output the menu currently shows before falling back to Spotify Active Device Volume. Group editing is derived in core through `SonosGroupMembershipResolver` and `SonosGroupMembershipChangePlanner`, which chooses a replacement coordinator inline; the menu app can expose available rows as direct plus actions in the Output list or render the full edit list through Option/Show More, then applies the resulting add/remove/remove-coordinator changes through `SonosGroupingService` and transfers playback to the replacement coordinator with coordinator-migration verification. Background playback sync uses `SonosGroupSuggestionTracker` to keep one current group suggestion in `PlaybackGroupSuggestionStore`; the menu renders that store as an in-menu fallback row while the app also delivers a macOS notification action for the same suggestion. `PlaybackOperationGate` owns freshness tickets and cancellation for asynchronous Playback Sync work, so transfer and volume results are applied only while they still belong to the selected or loading Output, and stale work is cancelled before it can wait in the Speaker Volume Command Queue and later run against the wrong Output. `SpeakerVolumeControlState` lives in `SonosHandoffCore` and owns the selected-Output volume UI state transitions: busy, clear, slider percent conversion, local write, mute, Sonos status, and monitor snapshot application. `PlaybackSliderCommitter` owns slider editing state, debounced slider commit scheduling, and pending slider commit cancellation; Playback Sync owns only the resulting volume command and selected-Output validation. `PlaybackTransferActionController` owns menu-triggered Output transfer calls and transfer logging. `PlaybackVolumeActionController` owns menu-triggered Output volume reads/writes through the Speaker Volume Command Queue. Debounced slider writes keep dragging audible without marking the menu volume state busy, while the final release write owns the busy state and refresh path. `SpeakerVolumeCommandQueue` lives in `SonosHandoffCore` and serializes app-triggered volume reads and writes so slider commits, step changes, shortcut changes, mute toggles, monitor polls, and status refreshes cannot publish stale Sonos results out of order; it uses an explicit FIFO operation slot with a bounded waiter list so an idle menu session does not retain old operation chains, and cancelled waiters are removed before they can run stale Sonos operations. `SonosVolumeMonitor` owns external volume polling, but polling now crosses the same Speaker Volume Command Queue seam as writes and waits until an Output is selected. App startup keeps seeding the monitor through `PlaybackOutputDirectory` until discovery finds an Output, so a transient launch-time discovery miss cannot permanently disable external volume reflection. `SpeakerVolumeMonitorReconciler` lives in `SonosHandoffCore` and owns monitor snapshot, local-change overlay, and feedback decisions so local-write echo suppression hides only duplicate HUD feedback, not the latest Sonos state published back into the menu.

### Menu Bar View

`MenuBarController` owns high-level menu orchestration: app lifecycle actions, settings commands, and the Show More section. `MenuBarVolumeControl` owns the compact Sound slider row, and `MenuBarOutputSection` owns the Output list rows and transfer loading affordance. Those SwiftUI Modules render Playback Sync state and forward intent, but do not read Sonos, Spotify, or token state directly.

### Sonos Service Composition

`SpotifyConnectHandoffService` is the public Adapter and composition root used by both the app and the command-line tool. It constructs the focused backend services directly instead of forwarding through another runtime facade. `SonosDirectory` owns target resolution and speaker discovery. `SonosVolumeService` owns room-name volume actions and queues confirmed Sonos volume writes for Spotify mirroring. `SpotifyConnectTransferService` owns the handoff workflow: resolve target, exchange Spotify credentials, call Sonos Spotify Zeroconf `addUser`, run Sonos Transfer Verification, and verify Spotify active-device state. `SonosTransferVerifier` owns the bounded AVTransport checks after activation: the target must enter Spotify Connect mode, but a still-active Spotify Connect URI is treated as ready even if Sonos transport state has not reported `PLAYING` yet. This avoids false UI failures after handoff has landed but Sonos state is lagging. `sonos-handoff-port` only parses commands and formats results; discovery, HTTP, XML, authentication, transfer, playback, and volume behavior all use this same core graph.

### Sonos Directory

`SonosDirectory` is the core actor for resolving an Output into a cached `ConnectSonosTarget`. Its Interface is intentionally small: discover visible Sonos speakers through `SonosSpeakerDiscovery`, or resolve a room name into a target for transfer and volume actions. Zeroconf `getInfo` and cache expiry stay behind this seam for locality. The menu app uses the same target resolution behavior that transfer and volume actions use, so a missing Sonos speaker is removed from the Output list and cannot drift into a separate UI-only list.

`SonosDNSSDResolver` owns DNS-SD browse and host resolution. `SonosDiscoveryCommandRunner` owns bounded `dns-sd` process execution and output capture. `SonosDNSSDRecordParser` owns browse-line and resolve-output parsing: Sonos instances, decoded room names, speaker IDs, and resolved hosts. `SonosSpeakerDiscovery` uses the resolver for Output list discovery, while `SonosDirectory` uses it for targeted room resolution before transfer and volume actions. Keeping those paths behind one runner, resolver, and parser means discovery-driven Output removal and targeted handoff resolve failures use the same execution bounds, parsing, timeout, and visibility rules.

`SonosSpeakerDiscovery` owns the Output list policy. It asks the resolver for visible Sonos instances, resolves hosts through bounded parallel lookups, drops unresolved instances, deduplicates by speaker id, and sorts by room name. This keeps slow or missing speakers from making the menu wait for serial per-speaker timeouts.

### Sonos Grouping

`SonosZoneGroupTopology` reads Sonos group topology through `GetZoneGroupState` and parses visible groups into `SonosGroupState`. `SonosSpeakerGroup` owns Spotify-style group display names and room matching for grouped Spotify device names. `SonosGroupingService` owns local group mutations: joining a standalone speaker to a coordinator, making a member standalone, migrating a coordinator, and removing a coordinator while rebuilding the remaining group around a replacement member. The safe live validation executable `sonos-handoff-safe-grouping-check` is the mutation gate for real speakers: dry-run mode never changes state, `--prepare-silent` sets all discovered speakers to volume `0` and muted, and `--mutate` also performs join/remove/coordinator-removal validation after the same safety preparation.

### Sonos Spotify Zeroconf Client

`SonosSpotifyZeroconfClient` is the Adapter for Sonos `/spotifyzc`. It owns GET versus POST selection, form encoding, JSON validation, and metadata extraction. Sonos Directory uses it for `getInfo`; Spotify Connect Transfer Service uses it for `addUser`.

### Spotify Connect Bridge

`SpotifyConnectBridge` owns Spotify-side protocol work needed after local Sonos discovery: Connect authorization-code exchange, Web API active-device polling, and Web API active-device volume writes. `SpotifyConnectHandoffService`, `SpotifyConnectTransferService`, and `SonosVolumeService` call that bridge directly instead of forwarding through a pass-through playback facade. `SpotifyDesktopCredentialProvider` owns Desktop Connect token selection, refresh, and persistence through `spotify-desktop-connect-tokens.json`; missing or unreadable Desktop token files become app-facing Settings recovery errors before Sonos activation starts. `SpotifyConnectTokenClient` owns Spotify Accounts token HTTP behavior for refresh-token requests and Spotify Connect token exchange, so auth failure mapping and expiry normalization stay out of the bridge. `SpotifyProjectAccessTokenProvider` owns project Web API token readiness and refresh through `ProjectWebAPITokenStore`; missing, incomplete, or malformed project tokens become app-facing sign-in recovery errors before active-device verification or volume mirroring attempts network work. `SpotifyActiveDeviceWaiter` owns the bounded polling loop and exposes explicit policies for transfer verification versus volume mirroring: transfer waits for the selected Output to be active and playing, while volume mirroring waits only for the selected Output to become active. This keeps Spotify credential and player-state rules out of Sonos volume and transfer workflows while keeping token persistence and polling rules local to their Modules.

`SpotifyVolumeMirrorQueue` owns the mirror scheduling policy inside Sonos Volume Service. Sonos Volume Service queues volume mirroring as non-blocking best effort after Sonos confirms the local volume write, so Spotify API latency cannot keep menu controls busy. The queue runs one mirror request at a time and coalesces queued intermediate writes to the latest room/volume, preventing held shortcuts and quick slider changes from building a stale Spotify API backlog. Before issuing the Web API volume write, `SpotifyConnectBridge` polls the active device with a hard attempt bound so a handoff that has landed on Sonos but has not yet propagated through Spotify does not drop the first volume mirror.

### Project Web API Token Store

`ProjectWebAPITokenStore` owns the `project-webapi-token.json` file format used by Spotify Web API auth, readiness checks, active-device verification, and active-device volume mirroring. `SpotifyAuthCoordinator` writes login results through it, `ConnectTokenStatusStore` validates readiness through it, and `SpotifyConnectBridge` refreshes expired tokens through it. Hard-cutover rule: a project token without a non-empty `client_id` is incomplete and requires login again.

### Spotify Auth Callback Server

`SpotifyAuthCallbackServer` owns the local HTTP callback listener used during Spotify login from the app. It owns `NWListener` setup, browser-open timing, callback timeout, and browser response text. `SpotifyAuthCallbackRequest` owns callback path matching, state validation, and authorization-code extraction, keeping HTTP parsing out of the listener lifecycle. `SpotifyAuthorizationRequest` owns callback state, redirect URI wiring, scope selection, and PKCE verifier/challenge generation. `SpotifyAuthCoordinator` now keeps the auth flow orchestration and token exchange only: it opens the authorization URL, exchanges the returned authorization code, and persists the resulting project Web API token.

### Shortcut Runtime

`VolumeHotkeyController` is the app seam for global volume shortcuts. It owns shortcut policy: parsed shortcut outcomes, held-key repeat coalescing, cross-source Carbon/event-tap duplicate suppression, mute handling, and volume intent dispatch. `AppDelegate` configures it with the same live App Environment used by the menu, so shortcuts do not construct a separate `SpotifyConnectHandoffService` or `ConfigStore`. `ShortcutCarbonHotKeyRegistrar` owns Carbon handler installation and plain function-key registration. `ShortcutEventTap` owns the Accessibility-gated `CGEvent` tap lifecycle for hardware media keys and `Shift+fn+F10/F11/F12`; the Shortcut Runtime coalesces the duplicate callback when macOS also delivers the same physical press through Carbon. `ShortcutEventParser` owns OS key-code decoding. `ShortcutRuntimeReporter` owns shortcut readiness transitions into `ShortcutRuntimeStatus`, including Accessibility permission, fn fallback state, and Carbon registration state. `ShortcutVolumeActionController` owns live Output lookup through Playback Output Selection, in-flight shortcut write coalescing, HUD feedback, and Volume Monitor echo suppression. Shortcut volume writes cross the shared Speaker Volume Command Queue seam, shared live volume Adapter, and shared selected-Output seam, so shortcut writes, menu writes, monitor reads, and Spotify volume mirroring stay ordered inside one runtime graph. The result is locality: Carbon, event-tap, key decoding, status reporting, and Sonos volume writes can change independently.

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
