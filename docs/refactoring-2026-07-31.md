# Keyway refactoring report — 2026-07-31

## Outcome

The complete repository was refactored in place from the uploaded authoritative baseline. The work concentrated on the highest-confidence architectural and reliability risks in the Chromium extension, its Swift native host, the app-side Chromium state machine, MediaRemote subprocess handling, asynchronous task lifetimes, build metadata, and semantic verification. Existing product behavior, protocols, process boundaries, permissions, configuration, UX, keyboard behavior, and technology choices were preserved.

A pristine extraction of the uploaded archive was retained for comparison. Its baseline run passed **26 of 40** verifiers; nine additional suites failed before exercising production behavior because their harnesses attempted to import unavailable AppKit, ApplicationServices, or Combine modules (or build the full macOS-only package), and five could not start because `ast-grep` or Apple `xcrun` was absent.

All semantic checks that can execute against the refactored tree pass: **38 of 43** repository verifiers completed successfully, while the same five tool-dependent checks remain unavailable. This means every one of the 35 original executable verifiers passes, plus three new focused suites. JavaScript, Swift parse, shell, Perl, Ruby, Python, JSON, property-list, Xcode-project, package-manifest, and whitespace/static checks pass. A real macOS/Xcode build and browser/hardware integration run remains required because this container has no macOS SDK, Xcode, AppKit runtime, Chrome UI, MediaRemote framework, Sonos hardware, or Spotify session.

## Architecture assessment

### Authoritative runtime map

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
          Perl / Objective-C helper     Swift native host
                                                |
                                                v
                                      Chromium MV3 extension
                               content script -> pure policy -> worker
```

The key dependency rule is that presentation sends intent and observes state; app controllers coordinate lifecycle; deterministic domain/selection policy stays in `SonosHandoffCore` or pure extension policy; process adapters translate bounded contracts; browser APIs stay inside the extension. No lower layer imports or owns presentation behavior, and no transport process owns Sonos, Spotify, target-selection, or UI policy.

### Before and after

| Area | Before | After |
| --- | --- | --- |
| Architecture description | `docs/architecture.md` described only “Menu Bar App -> SonosHandoffCore,” omitting the helper, native host, Chromium extension, process contracts, and mutable-state authority. | Five explicit layers, three process boundaries, dependency rules, state owners, and ordering/correlation invariants are documented. |
| App-side Chromium integration | A 1,183-line `ChromiumBrowserExtensionTransport.swift` combined constants, installation, wire DTOs, connection state, request correlation, lifecycle, and publication. | Protocol policy (`ChromiumBrowserExtensionTransport`), installation (`ChromiumNativeMessagingHostInstaller`), wire values (`ChromiumBrowserExtensionMessages`), and the single mutable controller (`ChromiumBrowserExtensionController`) have focused ownership. |
| Native host | A 373-line `main.swift` combined framing, identity, JSON mutation, connection filtering, notification routing, and process loop. | Framing, message types/state, browser identity, routing, and process-loop responsibilities are separate Swift files with direct tests. |
| MV3 worker | A 1,071-line service worker mixed Chrome lifecycle with document authority and candidate-scoring policy. | The 867-line worker owns Chrome APIs and lifecycle; `DocumentAuthorityRegistry` (102 lines) and media selection/materialization policy (144 lines) are pure ES modules. |
| Content script | Publication rescanned the full page/shadow DOM for each media element and again for supported-control discovery. Runtime invalidation was handled only on synchronous calls. | Each publish/command pass takes one page snapshot and reuses it; async `runtime.lastError` invalidation retires the bridge, observer, and timer, leaving already-installed element callbacks inert. |
| Timeout/retry tasks | Several one-shot tasks used `try? await Task.sleep`; cancellation could return `nil` yet allow stale timeout/retry work to continue. | Each changed task guards successful sleep and current identity before mutating state or retrying. |
| MediaRemote stdout | Each complete line searched then shifted the remaining `Data`, repeating scans and copies for multi-line chunks. | One pass records line boundaries and compacts the buffer once per chunk; teardown during a callback stops delivery from that retired process generation. |
| Linux semantic coverage | Nine policy suites failed before executing because their harnesses imported AppKit, ApplicationServices, or Combine unnecessarily, or because the CLI verifier attempted a full macOS-only package build. | Test-only platform stubs let the real production policy sources compile and execute on Linux. Product sources and package platform constraints are unchanged. |

### State and lifecycle ownership

- `PlaybackSyncController`, `MediaTransportActionController`, settings controllers, and shortcut controllers remain app orchestration seams; their core resolvers/planners remain deterministic and independently testable.
- `MediaRemoteController` owns helper generations, snapshot/request state, route shielding, and timeout tasks. `MediaRemoteHelperProcess` owns one subprocess generation, pipes, bounded output buffer, and line delivery.
- `ChromiumBrowserExtensionController` is the only app-process owner of browser profile snapshots, connection generations, pending command/focus requests, silence detection, and target publication.
- The native host owns one private `connectionID` plus monotonic `connectionGeneration`; it translates native frames and distributed notifications but does not select browser media or app targets.
- The MV3 worker owns profile GUID, native-port generation, snapshot epoch, resume state, Chrome listeners, and the canonical per-tab source map. `DocumentAuthorityRegistry` alone owns tab/frame/document generations.
- Each content-script instance owns its document ID, media IDs, element listeners, mutation observer, and publication interval. Invalidated contexts retire the instance.

## Prioritized problems found

1. **Repeated page-wide work in the content script.** `publishAll()` published every media element, while each `publishElement()` independently scanned the document and open shadow roots to discover track controls. On media-heavy pages this multiplied full-tree work by the number of elements and made each heartbeat more expensive than necessary.
2. **Competing concerns inside the MV3 service worker.** Chrome listener/port/storage lifecycle, navigation authority, stale-document rejection, media candidate scoring, route stickiness, and target serialization lived together. That made suspension/reconstruction invariants harder to inspect and pure policy difficult to test without a Chrome harness.
3. **Native-host and app Chromium monoliths.** Wire framing, JSON schemas, installation, process identity, distributed notifications, mutable connection state, request correlation, and target publication had unclear file-level boundaries. Build metadata also named only the old aggregate files, creating a risk that a new source would be omitted from Xcode phases.
4. **Cancellation did not consistently terminate delayed work.** Suppressing `Task.sleep` cancellation with `try?` without checking the result allowed retired timeout/retry tasks to proceed and potentially finish newer requests, restart a retired helper, expire a newer shield, or retry a completed group mutation.
5. **MediaRemote buffer handling repeated scans/copies and had a reentrancy edge.** Multi-line chunks repeatedly searched and removed prefixes; a callback that tore down the helper could still leave already-buffered lines eligible for delivery unless generation validity was rechecked.
6. **Important policy suites were coupled to unavailable UI frameworks.** The baseline Linux run reported compile failures before testing browser audio, app-side Chromium transport, desktop routing, overlay policy, target resolution, CLI parsing, shortcut decoding, source focus, and source-store behavior. This reduced confidence in behavior-preserving refactoring even though those policies did not require a real macOS UI runtime.
7. **Architecture documentation under-described real boundaries.** It did not state who owned mutable state across the app, helper, native host, worker, and content scripts, nor the protocol-v4 ordering and stale-result rules needed to safely evolve the system.

## Implemented refactorings and preserved invariants

### Chromium content script

- Added `scanPage()` and `querySelectorInRoots()` in `ChromiumExtension/content_script.js`.
- `publishAll()` now creates one `{ mediaElements, roots }` snapshot and computes supported commands once for the publication cycle.
- `applyCommand()` resolves the media element and page controls from one snapshot.
- Mutation-observer refresh uses the same one-scan publication path.
- `sendRuntimeMessage()` now checks callback-time `chrome.runtime.lastError`; `Extension context invalidated.` retires the bridge, disconnecting the observer and clearing the interval.
- Preserved: document-local IDs, all-frame behavior, existing command list and page-control semantics, direct media-element fallback, message shapes, publish interval, and user-visible behavior.

### MV3 service worker policy and lifecycle

- Added `ChromiumExtension/document_authority.js` with `DocumentAuthorityRegistry` for frame authority, browser/content document matching, monotonic generations, retirement, and history reactivation.
- Added `ChromiumExtension/media_source_selection.js` for visibility, audibility, route stickiness, deterministic scoring, and target materialization.
- `service_worker.js` retains top-level Chrome listener registration, tab/frame orchestration, storage/session resume, native-port generation, heartbeat/alarm ownership, and command/focus routing.
- `removeStaleSources()` refreshes a source only when a candidate was actually removed. Unchanged heartbeats no longer rescore every candidate merely because the stale sweep ran.
- Preserved: Manifest V3, permissions and host origins, profile GUID format/storage, canonical `chromium-tab:<profileGuid>:<tabId>` IDs, protocol version 4, persisted snapshot/epoch behavior, resume age, heartbeat timing, candidate weights/stickiness, command/result schemas, tab/frame routing, history reactivation, and native-host reconnect behavior.

### Swift native host

- Split `packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/main.swift` into:
  - `NativeMessagingFraming.swift` — native frame length decoding/encoding, exact reads, serialized writes.
  - `NativeMessageTypes.swift` — hello/snapshot wire values and connection state.
  - `HostBrowserIdentity.swift` — parent browser process identity.
  - `NativeMessageRouting.swift` — hello recording, identity/connection enrichment, connection filtering, result serialization.
  - `main.swift` — notification observers, process loop, and shutdown.
- Added a real production-source protocol harness covering framing, legacy hello defaults, resume snapshots, browser identity enrichment, connection-ID filtering, reload routing, and command/focus result correlation.
- Preserved: four-byte little-endian framing, JSON keys/defaults, protocol-v4 messages, distributed-notification names and objects, private connection token, generation semantics, stdin/stdout process contract, and browser identity approach.

### App-side Chromium integration

- Split the former aggregate file into:
  - `ChromiumBrowserExtensionTransport.swift` — constants, protocol policy, target parsing/validation, supported commands.
  - `ChromiumNativeMessagingHostInstaller.swift` — browser manifest paths, installation state, manifest writes, bundled-host selection.
  - `ChromiumBrowserExtensionMessages.swift` — snapshot/result DTOs, pending request values, command/focus payloads.
  - `ChromiumBrowserExtensionController.swift` — the sole mutable connection/profile/request state machine.
- Kept request timeout ownership adjacent to pending requests and added cancellation checks after sleep.
- Updated `scripts/generate_xcode_projects.rb` and the checked-in Xcode project to include every new Swift and JavaScript module in native-host inputs and extension resources.
- Preserved: notification transport, manifest installation locations/content, browser support, extension ID/host name, protocol validation, epoch/connection/profile checks, target publication, silence behavior, command/focus API, correlation IDs, and app UX.

### MediaRemote and task lifetimes

- Reworked `MediaRemoteHelperProcess.handleOutput` to scan a received buffer once, record complete-line ranges, remove the consumed prefix once, and stop if line handling tears down the current process generation.
- Added post-sleep cancellation/result guards to snapshot refresh, command cache, command result, route-shield timeouts, Chromium command/focus timeouts, and playback group-mutation observation retry.
- Added `scripts/verify_task_cancellation_semantics` and strengthened `verify_media_remote_helper_process_semantics` for multi-line buffering plus callback-triggered teardown.
- Preserved: newline-delimited JSON, buffer bound/failure behavior, helper restart policy, callback ordering for a live generation, timeout values, result messages, route-shield behavior, and group-mutation retry count/timing.

### Verification architecture

- Added `verify_chromium_worker_policy_semantics`, `verify_chromium_native_host_protocol_semantics`, and `verify_task_cancellation_semantics`.
- Updated Chromium verifiers to load all worker modules and all native-host Swift sources, so a split file cannot escape semantic or build-metadata checks.
- Replaced test-harness-only AppKit/ApplicationServices/Combine dependencies with minimal local substitutes in nine scripts. Production imports and target requirements were not changed.
- `verify_port_cli_argument_semantics` now compiles the production argument parser with domain stubs instead of attempting to build the entire macOS-only package before testing invalid arguments.
- Preserved: assertions and production source under test. Tests were not weakened to accept different behavior.

## Chromium extension and native-host assessment

### Service-worker suspension and reconstruction

MV3 globals are treated as disposable. Durable identity remains in `chrome.storage.local`; the last published target snapshot and epoch remain in `chrome.storage.session`. A new worker connects a fresh native port, increments `nativePortGeneration`, loads resume state, sends `hello`, probes tabs, and publishes. Every callback carries the port and generation and exits unless `isCurrentNativePort()` still matches. Pending resume targets are age-bounded and replaced or pruned as live document generations arrive.

The refactor makes the reconstruction rules inspectable without changing them: `DocumentAuthorityRegistry` rejects retired browser-document IDs and content-document mismatches, while the worker remains responsible for Chrome navigation/history events. Candidate selection is deterministic and pure, so suspension tests can verify the same scores and stickiness without reproducing Chrome APIs.

### Content-script lifecycle

A content-script instance is authoritative only for its generated `documentID`. The worker additionally binds it to Chrome's `sender.documentId`, tab, frame, and authority generation. Commands include the document/media route and fail when the content document or element is no longer present. Reinjection or extension reload creates a new instance; callback-time runtime invalidation now tears down the old observer/timer instead of allowing repeated failed heartbeats.

### Native-port and request ownership

The worker owns one generation-checked Chrome `Port`. The native host owns one private process connection ID/generation. The app controller accepts a snapshot or result only after protocol, profile, epoch, connection ID, connection generation, target, and request correlation checks. A disconnected/replaced worker or native host therefore cannot complete a request created by a newer lifecycle. The wire format and framing remain unchanged.

### Permissions and protocol

`ChromiumExtension/manifest.json` remains Manifest V3 with the same `alarms`, `nativeMessaging`, `scripting`, `storage`, `tabs`, and `webNavigation` permissions; the same HTTP/HTTPS host scope; the same stable extension key/ID; and the same JavaScript module system. No permission, origin, protocol version, native-host name, distributed-notification name, message field, command, installation step, or supported browser was added or removed.

## Concrete improvement evidence

### Reliability and stability

- Stale Chromium callbacks are rejected at four independently owned generations: content document, worker native port, host connection, and app request/epoch. The new pure-policy and native-host protocol suites exercise these invariants directly.
- Async runtime invalidation now retires the content bridge; it no longer depends solely on a synchronous exception from `sendMessage`.
- Canceled timeout/retry tasks cannot proceed past `Task.sleep`; a dedicated source-level semantic verifier covers each changed site.
- MediaRemote line delivery stops when handling a line invalidates the helper generation, preventing buffered output from a retired subprocess from entering current state.
- Build metadata names all new modules, preventing an Xcode resource/input phase from silently using only the old aggregate files.

### Performance

No wall-clock benchmark is claimed because a representative macOS/browser workload was unavailable. The improvement evidence is eliminated work:

- A content publication cycle now performs one recursive media/root enumeration, then reuses that snapshot for every media element and next/previous lookup. Previously the cycle enumerated media once and each media publication repeated deep control discovery.
- A command pass now uses one page snapshot for media lookup and page-control discovery.
- A stale-source sweep no longer rescans/scores every candidate for sources whose candidate set did not change.
- MediaRemote output processing scans line boundaries once and compacts the `Data` buffer once per incoming chunk, rather than searching and shifting for every complete line.

### Maintainability and testability

- App Chromium aggregate: **1,183 lines -> 161 policy + 105 installer + 113 messages + 808 state controller**. Mutable connection/request state remains intentionally in one controller rather than being duplicated across services.
- Native host aggregate: **373 lines -> 85 identity + 49 types/state + 36 framing + 133 routing + 77 process loop**.
- MV3 worker: **1,071 lines -> 867 Chrome lifecycle + 102 document authority + 144 media policy**.
- Nine formerly environment-blocked original semantic suites now execute on Linux. The untouched baseline passed 26 of 40 verifiers, with nine harnesses failing before execution and five tools unavailable; the final tree passes all 35 original executable verifiers plus three new focused verifiers, for 38 of 43.
- Architecture and Chromium documentation now specify layer direction, ownership, ordering, and stale-work rules for future changes.

## Validation commands and results

All commands were run from the repository root unless a package path is shown. Each `scripts/verify_*` command was executed independently and logged, so one unavailable tool did not suppress later results.

### Baseline comparison

| Tree | Verifiers | Passed | Harness/environment failures | Tool-unavailable |
| --- | ---: | ---: | ---: | ---: |
| Untouched uploaded archive | 40 | 26 | 9 | 5 |
| Refactored repository | 43 | 38 | 0 | 5 |

The three additional verifiers cover pure Chromium worker policy, native-host framing/routing/correlation, and delayed-task cancellation. The nine baseline harness failures were converted to test-only platform substitutes or focused parser compilation; production imports, package constraints, and target platforms were not changed.

### Repository semantic verifiers

| Exact command | Result |
| --- | --- |
| `scripts/verify_app_environment_external_input_semantics` | Passed |
| `scripts/verify_browser_audio_state_semantics` | Passed |
| `scripts/verify_chromium_content_script_semantics` | Passed |
| `scripts/verify_chromium_extension_semantics` | Passed |
| `scripts/verify_chromium_extension_transport_semantics` | Passed |
| `scripts/verify_chromium_generation_semantics` | Passed |
| `scripts/verify_chromium_native_host_input_semantics` | Passed |
| `scripts/verify_chromium_native_host_protocol_semantics` | Passed |
| `scripts/verify_chromium_service_worker_semantics` | Passed |
| `scripts/verify_chromium_worker_policy_semantics` | Passed |
| `scripts/verify_desktop_transport_semantics` | Passed |
| `scripts/verify_headphone_transfer_suggestion_semantics` | Unavailable: requires the `ast-grep` executable. |
| `scripts/verify_hitl_helium_playback_toggle_check_semantics` | Passed |
| `scripts/verify_hitl_playback_instant_reentry_check_semantics` | Passed |
| `scripts/verify_hitl_playback_routing_check_semantics` | Passed |
| `scripts/verify_media_chooser_guard_semantics` | Passed |
| `scripts/verify_media_remote_helper_process_semantics` | Passed |
| `scripts/verify_media_remote_refresh_gate_semantics` | Passed |
| `scripts/verify_media_routing_probe_semantics` | Unavailable: requires the `ast-grep` executable. |
| `scripts/verify_media_target_overlay_model_semantics` | Passed |
| `scripts/verify_media_transport_command_rules_semantics` | Passed |
| `scripts/verify_media_transport_route_source_semantics` | Passed |
| `scripts/verify_media_transport_target_resolver_semantics` | Passed |
| `scripts/verify_mediaremote_helper_pair_state` | Unavailable: requires Apple `xcrun` and the macOS SDK. |
| `scripts/verify_menubar_health_signal_semantics` | Passed |
| `scripts/verify_menubar_output_section_semantics` | Passed |
| `scripts/verify_menubar_source_first_semantics` | Unavailable: requires the `ast-grep` executable. |
| `scripts/verify_mixed_media_routing_semantics` | Unavailable: requires the `ast-grep` executable. |
| `scripts/verify_permission_onboarding_semantics` | Passed |
| `scripts/verify_playback_filter_semantics` | Passed |
| `scripts/verify_playback_output_selection_semantics` | Passed |
| `scripts/verify_playback_reentry_semantics` | Passed |
| `scripts/verify_playback_routing_invariants` | Passed |
| `scripts/verify_port_cli_argument_semantics` | Passed |
| `scripts/verify_settings_feature_semantics` | Passed |
| `scripts/verify_shortcut_event_parser_semantics` | Passed |
| `scripts/verify_shortcut_runtime_status_semantics` | Passed |
| `scripts/verify_shortcut_spotify_volume_semantics` | Passed |
| `scripts/verify_sonos_observation_authority_semantics` | Passed |
| `scripts/verify_source_focus_semantics` | Passed |
| `scripts/verify_source_store_semantics` | Passed |
| `scripts/verify_task_cancellation_semantics` | Passed |
| `scripts/verify_volume_hud_semantics` | Passed |

Summary: **38 passed; 5 unavailable; 0 executable verifier failures.**

### Static and format verification

| Command | Result |
| --- | --- |
| `for file in ChromiumExtension/*.js; do node --check "$file"; done` | Passed for 4 JavaScript modules. |
| `find . -type f -name '*.swift' ... | while ...; do swiftc -parse -enable-bare-slash-regex "$file"; done` | Passed for 180 Swift files. |
| Interpreter-aware `bash -n` loop over `scripts/` | Passed for 80 shell scripts. |
| `perl -c MediaRemoteHelper/keyway-mediaremote-helper.pl` | Passed. |
| `ruby -c scripts/generate_xcode_projects.rb` | Passed. |
| In-memory Python AST parse of Python verifier scripts | Passed. |
| Python `json.load` loop over repository JSON files | Passed for 5 JSON files. |
| `plutil -lint` over repository property lists and `project.pbxproj` | Passed for 2 property lists plus the Xcode project. |
| `swift package dump-package --package-path packages/SonosHandoffCore` | Passed. |
| Repository-wide trailing-whitespace and conflict-marker scan | Passed for 327 text files. |

### Build and generator attempts

| Command | Result |
| --- | --- |
| `swift build --disable-sandbox --package-path packages/SonosHandoffCore --product keyway-chromium-native-host` | Environment-blocked: target requires AppKit, which is unavailable on Linux. |
| `swift build --disable-sandbox --package-path packages/SonosHandoffCore --product sonos-handoff-port` | Environment-blocked: package source requires ApplicationServices, which is unavailable on Linux. |
| `swift test --disable-sandbox --package-path packages/SonosHandoffCore` | Environment-blocked for the same AppKit/ApplicationServices requirements. |
| `xcodebuild -version` | Environment-blocked: `xcodebuild` is not installed on Linux. |
| `ruby scripts/generate_xcode_projects.rb` in a temporary repository copy | Environment-blocked: the existing `xcodeproj` Ruby gem is not installed. The generator itself passes `ruby -c`. |

## Checks not run and precise reasons

- **macOS application/Xcode build, signing, notarization, installation, launch, menu/overlay/UI inspection:** requires macOS, Xcode, Apple SDKs, signing identities, and a window server.
- **Real Chrome/Chromium extension loading, MV3 suspension, tab/frame navigation, native-host kill/reconnect, and page-control smoke:** requires a supported macOS browser plus its native-messaging environment. The Node semantic harnesses ran, but they do not claim a live-browser result.
- **MediaRemote private-framework helper and pair-state check:** requires `xcrun`, macOS frameworks, and a live media session.
- **Sonos discovery/grouping/transport/volume:** requires Bonjour/local-network access and real Sonos devices.
- **Spotify auth, Desktop Connect token refresh, transfer, Web API playback/volume, and AppleEvents:** requires macOS Spotify, user credentials/tokens, network access, and a live account/device.
- **Accessibility, Input Monitoring, Carbon event taps, physical function/media keys, Touch Bar, and notification UX:** require macOS permissions and hardware/human interaction.
- **Four AST-based repository verifiers:** require `ast-grep`, absent from this container.

No result from the authoritative baseline's prior macOS verification is represented as having been rerun here. Those records remain in `docs/verification-log.md` for historical context.

## Remaining risks and deliberately rejected/deferred changes

1. **A macOS/Xcode build is still the release gate.** Static Swift parsing and portable semantic harnesses cannot validate linker availability, entitlements, bundle phases, signing, or runtime interactions with AppKit, ApplicationServices, DistributedNotificationCenter, MediaRemote, AppleEvents, or browser native messaging.
2. **Live MV3/browser timing remains environment-sensitive.** The generation and reconstruction policy is covered, but actual Chrome suspension timing, browser-specific frame behavior, and native-host restart need the existing live smoke on macOS.
3. **Large cohesive orchestration types were not split arbitrarily.** `PlaybackSyncController`, `MediaTransportActionController`, `SettingsFeature`, and the Objective-C MediaRemote shim remain substantial because the available evidence did not identify a safe behavior-preserving ownership split. Arbitrary line-count partitioning would create extra forwarding types and obscure state authority.
4. **The 808-line Chromium controller remains the single state machine.** Its installation, DTO, and policy concerns were removed; splitting mutable profile/connection/request state further would risk competing authority or pass-through wrappers. A future split should be driven by a proven independently owned lifecycle, not size alone.
5. **Spotify Web API calls were not consolidated behind a generic request wrapper.** Their auth refresh, status mapping, request bodies, and retry semantics differ; a convenience wrapper would conflict with `AGENTS.md` and could conceal behavior changes.
6. **No Linux compatibility layer was introduced.** Product imports, package platform, and macOS APIs remain authoritative. Test-only substitutes make policy verifiers portable without creating dual production implementations.
7. **No tool or dependency was installed into the repository.** Missing `ast-grep`, `xcrun`, `xcodeproj`, Xcode, browser, and hardware checks remain explicit rather than being bypassed or weakened.

## Compact file-by-file change inventory

| File | Change |
| --- | --- |
| `ChromiumExtension/content_script.js` | One-scan page snapshot, reused control lookup, async runtime-invalidation retirement. |
| `ChromiumExtension/document_authority.js` | New pure tab/frame/document generation authority. |
| `ChromiumExtension/media_source_selection.js` | New pure visibility, audibility, scoring, stickiness, and materialization policy. |
| `ChromiumExtension/service_worker.js` | Delegates pure policy, retains Chrome lifecycle/transport, avoids unchanged stale-sweep rescoring. |
| `ChromiumExtension/README.md` | Documents lifecycle, module ownership, suspension recovery, and correlation. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar.xcodeproj/project.pbxproj` | Adds new app/native-host Swift files and worker modules to checked-in build/resource phases. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar/App/ChromiumBrowserExtensionController.swift` | New sole app-side Chromium mutable state machine. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar/App/ChromiumBrowserExtensionMessages.swift` | New wire DTO and pending-request ownership. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar/App/ChromiumBrowserExtensionTransport.swift` | Reduced to protocol policy/constants and command mapping. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar/App/ChromiumNativeMessagingHostInstaller.swift` | New focused native-host manifest installer. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaRemoteController.swift` | Cancellation-safe snapshot/cache/command/route-shield timeout tasks. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar/App/MediaRemoteHelperProcess.swift` | Single-pass line framing/compaction and teardown-aware delivery. |
| `SonosHandoffMenuBar/SonosHandoffMenuBar/App/PlaybackSyncController.swift` | Cancellation-safe group-mutation observation retry. |
| `packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/HostBrowserIdentity.swift` | New focused browser-process identity extraction. |
| `packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/NativeMessageRouting.swift` | New JSON validation, enrichment, connection filtering, and result routing. |
| `packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/NativeMessageTypes.swift` | New native hello/snapshot DTOs and connection state. |
| `packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/NativeMessagingFraming.swift` | New native-message frame read/write ownership. |
| `packages/SonosHandoffCore/Sources/KeywayChromiumNativeHost/main.swift` | Reduced to process loop and distributed-notification bridge. |
| `scripts/build_notarized_app` | Includes the extracted worker policy modules in the packaged Chromium extension. |
| `scripts/generate_xcode_projects.rb` | Tracks every new host/app/extension source in generated metadata. |
| `scripts/verify_app_environment_external_input_semantics` | Includes split Chromium app sources in architecture verification. |
| `scripts/verify_browser_audio_state_semantics` | Test-only observable stubs; real production browser-audio policy runs on Linux. |
| `scripts/verify_chromium_content_script_semantics` | Covers one-scan publication and runtime-context retirement. |
| `scripts/verify_chromium_extension_semantics` | Verifies complete worker module/resource/project metadata set. |
| `scripts/verify_chromium_extension_transport_semantics` | Compiles/runs split production app-side Chromium state machine. |
| `scripts/verify_chromium_generation_semantics` | Loads extracted authority/selection modules with lifecycle harness. |
| `scripts/verify_chromium_native_host_input_semantics` | Validates all host source inputs rather than only `main.swift`. |
| `scripts/verify_chromium_native_host_protocol_semantics` | New production-source framing/routing/connection protocol harness. |
| `scripts/verify_chromium_service_worker_semantics` | Loads worker ES modules in suspension/transport harness. |
| `scripts/verify_chromium_worker_policy_semantics` | New deterministic document authority and candidate selection suite. |
| `scripts/verify_desktop_transport_semantics` | Test-only AppKit substitutes; real desktop routing policy runs on Linux. |
| `scripts/verify_media_remote_helper_process_semantics` | Adds multi-line and callback-teardown framing assertions. |
| `scripts/verify_media_target_overlay_model_semantics` | Test-only observable substitutes for portable production-model testing. |
| `scripts/verify_media_transport_target_resolver_semantics` | Test-only AppKit substitutes for focused-target/routing policy. |
| `scripts/verify_playback_routing_invariants` | Includes new split Chromium controller source. |
| `scripts/verify_port_cli_argument_semantics` | Tests production CLI parser directly with domain stubs. |
| `scripts/verify_shortcut_event_parser_semantics` | Test-only key/modifier substitutes for production parser. |
| `scripts/verify_source_focus_semantics` | Test-only workspace/application substitutes for production focus policy. |
| `scripts/verify_source_store_semantics` | Test-only observable substitutes for production store behavior. |
| `scripts/verify_task_cancellation_semantics` | New invariant checks for every corrected delayed task. |
| `docs/architecture.md` | Adds layer map, dependency rules, state owners, process ordering. |
| `CONTEXT-MAP.md` | Links architecture/refactor/Chromium references and process relationships. |
| `docs/verification-log.md` | Separates current Linux evidence from retained prior macOS evidence. |
| `docs/refactoring-2026-07-31.md` | This assessment, evidence, command log, risks, and inventory. |

## Technology-stack confirmation

`Package.swift`, `ChromiumExtension/manifest.json`, `ChromiumExtension/native-host-manifest.json`, and the application `Info.plist` are byte-for-byte unchanged from the uploaded baseline. No dependency, permission, origin, manifest version, package platform, language, process boundary, build system, or deployment mechanism was added or changed.

The technology stack was **not changed**. The repository still uses Swift, Swift Package Manager, Xcode project metadata, SwiftUI/AppKit, the existing Perl/Objective-C MediaRemote helper, Ruby project generation, shell tooling, and a JavaScript Manifest V3 Chromium extension. No dependency, framework, package manager, build system, code generator, runtime platform, protocol version, manifest version, deployment target, browser permission/origin, native-messaging architecture, Sonos/Spotify/MediaRemote approach, language, or third-party library was added, removed, upgraded, or downgraded.
