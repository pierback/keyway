# Context

## Domain Terms

### Spotify Connect Handoff

The product flow that activates a Sonos speaker as the Spotify playback device while keeping Spotify as the controller. It does not rely on Spotify Web API available-device transfer because Sonos speakers may be omitted from that device list.

### Sonos Runtime

The core Module that assembles the Spotify Connect Handoff runtime graph behind the public `SpotifyConnectHandoffService` Adapter. It delegates discovery, volume, Spotify playback, and transfer workflows to narrower Modules so callers do not know zeroconf paths, SOAP actions, DNS-SD parsing, token file formats, or active-device polling rules.

### Sonos Directory

The core actor that owns Output target resolution, Spotify zeroconf metadata lookup, visible speaker discovery, and the short-lived target cache. The menu app's Output list and Sonos Runtime's handoff path both depend on this Module so discovery behavior stays consistent.

### Sonos Volume Service

The core Module that owns Sonos Output volume actions at the room-name Interface. It resolves the Output through Sonos Directory, delegates RenderingControl SOAP calls to Sonos Rendering Control, and asks Spotify Playback Service to mirror confirmed local volume writes back to Spotify when the Output is active.

### Spotify Playback Service

The core Module that owns active Spotify device lookup, active-device verification, and best-effort Spotify active-device volume mirroring. It is the playback-state seam used by startup sync, transfer verification, and volume mirroring.

### Spotify Connect Transfer Service

The core Module that owns Spotify Connect Handoff workflow execution after a room name has been chosen. It resolves the Output through Sonos Directory, exchanges Spotify Desktop credentials for a Sonos activation code, calls Sonos Spotify Zeroconf `addUser`, and runs Sonos Transfer Verification plus Spotify active-device verification.

### Sonos Speaker Discovery

The core Module that owns discovery of visible Sonos Outputs for the menu app list. It browses `_sonos._tcp`, resolves discovered instances into host-backed `SonosSpeaker` rows with bounded parallel host resolution, drops unresolved instances, deduplicates speakers, and returns the list sorted by room name.

### Sonos Room Name

The core Module that owns room-name normalization and equality across Spotify, Sonos, and the menu app. Output discovery, Output selection, Volume Monitor reconciliation, and Playback Sync stale-result checks use it so whitespace trimming and case-insensitive room matching cannot drift across the sync loop.

### Sonos Output Selection Resolver

The core Module that chooses the selected Output from the currently visible Sonos speakers and the current menu selection. It preserves a visible current Output and finally chooses the first visible Output, so discovery-driven Output removal and startup fallback use one tested rule.

### Sonos Output Preference Resolver

The core Module that owns Output fallback policy: the `Port` fallback and the ordered preferred room list used by shortcut volume fallback. Shortcut Volume Actions use this Module so missing-selection fallback cannot drift.

### Sonos DNS-SD Resolver

The core Module that owns local DNS-SD browse and host resolution for Sonos devices. Sonos Speaker Discovery uses it for Output list discovery, and Sonos Directory uses it for targeted room resolution so the menu list, transfer, and volume paths share the same network visibility rules.

### Sonos DNS-SD Record Parser

The core Module that owns DNS-SD browse and resolve-output parsing for Sonos devices. It extracts Sonos instances, decoded room names, speaker IDs, and resolved hosts so Output discovery and targeted Output resolution cannot drift in how they interpret `dns-sd` output.

### Sonos Discovery Command Runner

The core Adapter that owns bounded shell execution for local Sonos discovery commands. It runs `dns-sd`, captures stdout and stderr through a bounded output buffer, terminates early when a stop condition matches, and gives Sonos DNS-SD Resolver a small command/result Interface instead of exposing `Process` lifecycle details.

### Sonos Rendering Control

The core Module that owns Sonos RenderingControl SOAP actions for volume, mute, fixed-output status, and volume status. It is the core-side counterpart to the app's Volume Monitor.

### Speaker Volume Control State

The core Module that owns the selected Output volume-control state transitions used by the menu app: busy status, status clearing, slider percentage conversion, local write application, mute application, Sonos status application, and monitor snapshot application. Playback Sync publishes this state, but the transition rules live in core so slider writes, Sonos reads, and external monitor updates share one tested state model.

### Sonos Spotify Zeroconf Client

The core Adapter for Sonos `/spotifyzc` calls. It owns the HTTP method, form encoding, response validation, and metadata extraction used by the Sonos Directory and Sonos Runtime.

### Spotify Connect Bridge

The core Module that owns Spotify Desktop token refresh, Spotify Connect authorization-code exchange for Sonos activation, Spotify Web API active-device verification, and best-effort Spotify active-device volume mirroring. It reads and refreshes the project Web API token only through the Project Web API Token Store. Volume mirroring is queued and non-blocking from the Sonos volume write path so Spotify API latency cannot hold the menu busy after Sonos confirmed the local change.

### Spotify Desktop Credential Provider

The core Module that owns the `spotify-desktop-connect-tokens.json` file used for Spotify Connect Handoff. It selects the preferred Desktop login, validates and refreshes expired Desktop streaming tokens through the Spotify Connect Token Client, persists refreshed Desktop tokens, and maps missing or unreadable Desktop token files to app-facing Settings recovery errors.

### Spotify Connect Token Client

The core Adapter for Spotify Accounts token endpoints used by Spotify Connect Handoff. It owns refresh-token HTTP requests, Spotify Connect token exchange request construction, Accounts JSON validation, auth failure mapping, and token expiry normalization.

### Spotify Project Access Token Provider

The core Module that owns project Web API access-token readiness for active-device verification and Spotify volume mirroring. It loads tokens through the Project Web API Token Store, rejects missing or malformed project tokens with app-facing sign-in recovery errors, refreshes expired access tokens through the Spotify Connect Token Client, and persists replacements back through the store.

### Spotify Active Device Waiter

The core Module that owns bounded Spotify Web API active-device polling. Spotify Connect Bridge uses it for two policies: transfer verification waits until the selected Output is active and playing, while volume mirroring waits only until the selected Output is the active device.

### Spotify Volume Mirror Queue

The core Module that owns best-effort Spotify volume mirror scheduling after Sonos confirms a local volume write. It runs at most one Spotify Web API mirror request at a time and coalesces queued intermediate writes to the latest room/volume so held shortcuts and quick slider changes cannot build a stale Spotify API backlog. Spotify Connect Bridge waits briefly, with a hard attempt bound, for Spotify's active device to catch up to the selected Sonos room before it writes active-device volume.

### Project Web API Token Store

The core Module that owns the `project-webapi-token.json` file format, persistence, completeness checks, and deletion. Spotify login writes through it, readiness checks validate through it, and Spotify Connect Bridge refreshes through it so token schema rules stay in one place.

### Spotify Auth Callback Server

The core Module that owns the local browser callback listener for Spotify login. It opens the authorization URL only after the listener is ready, validates callback state, returns the browser response text, applies the callback timeout, and hands the authorization code back to Spotify login.

### Spotify Auth Callback Request

The core Module that parses and validates the local Spotify login callback request. It owns callback path matching, state validation, and authorization-code extraction so the callback listener does not duplicate HTTP parsing and auth failure mapping.

### Spotify Authorization Request

The core Module that builds the Spotify OAuth authorization URL used by app sign-in. It owns callback state, redirect URI wiring, scope selection, and PKCE verifier/challenge generation so the Spotify Auth Coordinator stays focused on login workflow and token persistence.

### Sonos Transfer Verification

The core Module that owns post-activation AVTransport checks for Spotify Connect Handoff. It verifies that the target enters Spotify Connect mode, sends Play, and treats a still-active Spotify Connect URI as ready even when Sonos transport state lags behind, so the menu app does not show false transfer failures after handoff has actually landed.

### Playback Sync

The menu app Module that owns the currently selected output, discovered Sonos speakers, transfer progress, volume reads/writes, slider debounce, and reconciliation of external Sonos/Spotify volume changes back into UI state. It publishes Speaker Volume Control State from core rather than owning volume transition rules itself. The menu view renders Playback Sync state and forwards user intent. Volume controls are enabled only after Playback Sync has a fresh status for the selected Output.

### Playback Operation Gate

The menu app Module that owns freshness tickets and cancellation for asynchronous Playback Sync work. Volume and transfer tasks must be started through this Module, and Playback Sync applies their results only while the ticket still matches the selected or loading Output. Starting newer Playback Sync work cancels stale work before it can wait in the Volume Command Queue and later run against the wrong Output.

### Playback Slider Committer

The menu app Module that owns slider editing state, debounced slider commit scheduling, and pending slider commit cancellation. Playback Sync asks it to schedule or cancel slider commits, while Playback Sync remains responsible for validating Output tickets and applying volume state.

### Menu Bar View

The menu app Module that renders the native macOS-style Sound drop-down. It is presentation-only: `MenuBarController` owns high-level menu orchestration, while `MenuBarVolumeControl` and `MenuBarOutputSection` render the volume and Output surfaces from Playback Sync state.

### Playback Output Directory

The menu app Module that turns local Sonos discovery into the current Output list plus selected Output. It delegates speaker discovery caching to Playback Discovery Cache and selected-Output policy to the Sonos Output Selection Resolver so the app owns published state, while core owns the fallback rule.

### Playback Discovery Cache

The menu app actor that owns cached Output discovery results and in-flight background discovery. Startup monitor seeding and menu refreshes both use this actor so opening the menu does not create a second slow discovery path when a background refresh is already running.

### Playback Output Selection

The menu app Module that owns the live selected Output name shared by Playback Sync, startup monitor seeding, and Shortcut Volume Actions. Saved config remains only the fallback used when no live Output has been selected yet.

### Playback Transfer Suggestion

The menu app Module path that prompts for newly visible Sonos Outputs while Spotify is playing on a non-Sonos active device. It uses core transfer-suggestion tracking to avoid prompting for speakers first seen while Spotify is stopped, delivers a notification with Move and Ignore actions, and accepts by running the same room handoff path as menu Output selection.

### Playback Volume Actions

The menu app Module that executes menu-triggered Output volume reads and writes through the Speaker Volume Command Queue. Playback Sync owns the published UI state and validation that results still belong to the selected Output, while Playback Slider Committer owns slider edit/debounce mechanics.

### Playback Transfer Actions

The menu app Module that executes menu-triggered Output transfer. It owns calls through the Sonos Runtime Adapter and transfer logging; Playback Sync owns only the loading, selection, and failure state, and validates that transfer results still belong to the current in-flight Output generation.

### Volume Monitor

The menu app Module that polls the selected Output for Sonos volume and mute state and publishes the latest reported state back to Playback Sync. It does not poll a hard-coded room before an Output exists; app startup keeps retrying discovery through Playback Output Directory until an Output can seed the monitor.

### Speaker Volume Monitor Reconciler

The core Module that decides how a polled Sonos volume status changes the Volume Monitor snapshot and whether it should produce Status HUD feedback. It also owns local-change snapshot overlay rules. Local write echo suppression only suppresses HUD feedback; it must not suppress snapshot updates.

### Speaker Volume Command Queue

The core Module that serializes app-triggered Sonos volume reads and writes for the selected Output. Slider commits, menu step changes, shortcut changes, mute toggles, monitor polls, and explicit status refreshes pass through this queue so Playback Sync does not publish stale results from overlapping Sonos requests. The queue uses an explicit FIFO operation slot with a bounded waiter list rather than a retained task chain, so long-running menu sessions do not keep old operations alive and queued callers that are cancelled before acquiring the slot are removed without running stale Sonos operations.

### Output

A Sonos room visible on the local network and selectable in the menu app. The Output list is discovery-driven: when a Sonos speaker is not discovered, it should not be shown as an Output.

### Shortcut Runtime

The menu app Module that owns global keyboard shortcuts for Sonos volume and mute. It coordinates Carbon hotkey registration, the Accessibility-gated media/function-key event tap, held volume repeats, shortcut readiness reporting, and volume intent forwarding to Shortcut Volume Actions. `VolumeHotkeyController` owns shortcut policy, not OS registration mechanics.

### Shortcut Carbon HotKey Registrar

The menu app Module that owns Carbon hotkey handler installation and `Shift+F10/F11/F12` registration. It does not register `Shift+fn+F10/F11/F12`; the Accessibility-gated Shortcut Event Tap is the sole fn-key handler so volume and mute shortcuts cannot double-fire. It hides Carbon references, hotkey IDs, modifier masks, and registration logging behind a small hotkey-id callback.

### Shortcut Event Tap

The menu app Module that owns the Accessibility-gated `CGEvent` tap lifecycle for media/function-key interception. It hides tap creation, run-loop source installation, tap enablement, and callback bridging behind a small event callback.

### Shortcut Runtime Reporter

The menu app Module that owns shortcut runtime status transitions. It translates Carbon registration, Accessibility permission, and media fallback outcomes into `ShortcutRuntimeStatus` updates so the Shortcut Runtime does not scatter status mutation across registration branches.

### Shortcut Volume Actions

The menu app Module that executes shortcut-triggered Sonos volume and mute changes. It owns live Output lookup, in-flight shortcut write coalescing, Status HUD feedback, and Volume Monitor echo suppression while sending all Sonos reads/writes through the Volume Command Queue. It receives the same live App Environment volume Adapter and Playback Output Selection as Playback Sync, so shortcut writes target the same selected Output as the menu and share one runtime graph with menu writes, monitor polls, and Spotify volume mirroring.

### Status Feedback

The menu app Module that owns transient feedback for shortcut and external volume changes. `StatusHUD` exposes a small feedback Interface to playback and shortcut Modules and delivers feedback with native macOS notifications through `UNUserNotificationCenter`. Keyway does not show a custom top-of-screen feedback panel. It is presentation-only; playback state belongs to Playback Sync.
