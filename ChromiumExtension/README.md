# Keyway Chromium Media Bridge

The extension makes browser media deterministic by giving Keyway one canonical source row for each browser tab/session:

```text
chromium-tab:<profile-guid>:<tab-id>
```

The profile GUID is minted once by the extension and persisted in `chrome.storage.local`, so a tab keeps the same Keyway identity across native-host process churn and service-worker restarts. The unpacked extension has a stable manifest key, so its runtime ID is deterministic metadata: `gmdpkggbaohimgacbclndlfjghgcbael`. The service worker keeps frame and media element IDs as private route state and sends commands to the selected element for the source. This avoids both OS media-key ambiguity and duplicate Keyway rows when one page exposes several media elements.

## Architecture

```text
page/frame content_script.js
          |
          v
DocumentAuthorityRegistry + media_source_selection.js
          |
          v
service_worker.js (Chrome lifecycle and native port)
          |
   Chrome native messaging
          |
          v
keyway-chromium-native-host
          |
 authenticated Unix socket
          |
          v
ChromiumBrowserExtensionController
```

- `content_script.js` owns one frame document. It discovers `video` and `audio` elements, assigns document-local media IDs, reports state, and applies commands to the selected element or a page-backed control. Each publication or command pass scans the document and open shadow roots once and reuses that snapshot. Re-injection is idempotent. An invalidated extension context disconnects the mutation observer and clears the heartbeat timer.
- `document_authority.js` is a pure `DocumentAuthorityRegistry`. It is the sole authority for tab, frame, browser-document, content-document, and monotonic document-generation matching. Navigated or retired documents cannot publish late state into a newer page.
- `media_source_selection.js` is pure policy for visibility, audibility, route stickiness, deterministic candidate scoring, source refresh, and target materialization. It has no Chrome API dependency and is exercised directly by Node semantic tests.
- `service_worker.js` owns all Chrome APIs and MV3 lifecycle: top-level listener registration, persisted profile GUID, native-port generation, snapshot epoch, suspension/reconnect recovery, tab/frame events, candidate maps, command routing, and snapshot publication. It delegates document authority and selection policy to the pure modules.
- `keyway-chromium-native-host` owns four-byte little-endian native-message framing, parent-browser identity, JSON validation/enrichment, private connection correlation, and translation onto the authenticated app bridge. It does not select media or own app state.
- `KeywayChromiumBridgeIPC` owns the private app/native-host Unix socket, bounded internal framing, reconnect buffering, and audit-token-bound mutual code-signature validation. The app accepts only the signed native-host code identifier; the host accepts only the signed Keyway bundle identifier; both require the canonical Apple team.
- `ChromiumBrowserExtensionController` is the app-side mutable authority for profile snapshots, native-host connection generations, pending command/focus requests, silence detection, stale-result rejection, and publication into Keyway's media target list.

The browser backend supports `play`, `pause`, `playPause`, `mute`, and volume delta. Browser `next` and `previous` are exposed only when the page provides a usable track control, such as Spotify Web or YouTube skip controls; generic `<audio>` and `<video>` elements still report those commands as unsupported.

## Identity, ordering, and recovery

The canonical app-visible target ID remains:

```text
chromium-tab:<profile-guid>:<tab-id>
```

The profile GUID is persisted in `chrome.storage.local`, so target identity survives service-worker suspension and native-host process churn. Frame IDs, browser document IDs, content document IDs, media IDs, and candidate keys remain private route state.

Every native-host process owns a private `connectionID` and a monotonic `connectionGeneration`. Snapshots and results are stamped with both values before they enter the app process. Commands must match the current connection ID; the host removes that private token before writing to Chrome. The app rejects stale generations and stale request IDs, so a late response from a retired browser/host connection cannot complete a newer request.

The app/native-host transport is not a trust boundary based only on filesystem permissions. Each accepted socket supplies a kernel audit token, which Security.framework validates against the expected code identifier, Apple generic anchor, and team identifier. The socket directory is mode `0700`, the endpoint is mode `0600`, and internal frames larger than 4 MiB are rejected. `DistributedNotificationCenter` is deliberately not part of this command path.

MV3 listeners remain registered synchronously at module evaluation. After suspension or worker restart, the worker reloads persisted profile/epoch metadata, opens a new native port generation, probes current tabs/frames, reconstructs media candidates from fresh content-script state, and republishes one canonical snapshot. Port disconnects consume Chrome's `runtime.lastError`, retire only that port generation, and reconnect with bounded exponential backoff from one to 30 seconds; a connection must remain stable for five seconds before the backoff resets. Callbacks from older generations are ignored. Neither the app nor the native host can reload the extension runtime.

## Verification

Focused semantics are covered by:

```bash
scripts/verify_chromium_content_script_semantics
scripts/verify_chromium_worker_policy_semantics
scripts/verify_chromium_service_worker_semantics
scripts/verify_chromium_generation_semantics
scripts/verify_chromium_native_host_protocol_semantics
scripts/verify_chromium_extension_transport_semantics
scripts/verify_chromium_bridge_contract
swift test --package-path packages/SonosHandoffCore --filter KeywayChromiumBridgeIPCTests
```

These tests exercise page-snapshot reuse, context retirement, navigation authority, candidate selection and stickiness, service-worker suspension/reconstruction, stale-port rejection, native framing/correlation, and app-side stale-result handling. Live browser/native-host smoke still requires macOS and a supported Chromium browser.

## Distribution

Public macOS distribution goes through the Chrome Web Store. Chrome and Chromium browsers allow an unpacked extension for local development, but ordinary macOS users cannot install a self-hosted extension directly; self-hosting is limited to managed enterprise browsers.

The notarized release builder creates both deliverables:

```bash
scripts/build_notarized_app
```

Upload `.build/distribution/Keyway-Chromium-Extension-<version>.zip` in the Chrome Developer Dashboard. The ZIP contains `manifest.json` at its root, as required by the store.

Before the first public submission, compare the dashboard Item ID with `extensionID` in `ChromiumBridgeProtocol/contract.json`. If they differ, copy the dashboard public key into `manifest.json`, update the canonical contract to the resulting Item ID, run `scripts/generate_chromium_bridge_contract`, and rebuild both release archives. The generator verifies that the contract ID matches the manifest key. The IDs must match because Chrome native-messaging manifests accept explicit extension origins and do not allow a wildcard.

## Local Install

1. Open Keyway once. The app installs or repairs the native host manifest at launch, pointing Chrome-family browsers at the helper bundled in `Keyway.app/Contents/Helpers`.

2. In Keyway Settings -> Browser Extension, choose `Set Up Browsers`. Keyway copies the unpacked extension to a stable folder at:

```text
~/Library/Application Support/Keyway/ChromiumExtension
```

It then copies that path and opens the selected browser's extension page. Use `Show Folder` in the wizard if you need Finder.

For manual repair, use:

- `Repair Bridge` to reinstall the native host manifests.
- `Reveal Extension` to refresh and show the managed extension folder.
- `Open Extensions` to open `chrome://extensions` (it prefers Helium when Helium is installed; use the script below to target a specific browser deterministically).

3. Enable Developer Mode in the target browser, choose `Load unpacked`, and select the revealed `ChromiumExtension` folder. Keyway completes setup automatically when that browser profile connects.

For local source-tree testing, this script installs or repairs the native host, reveals the source extension folder, and opens the target browser's extension page:

```bash
scripts/setup_chromium_extension "/Applications/Helium.app"
scripts/setup_chromium_extension "/Applications/Google Chrome.app"
scripts/setup_chromium_extension "/Applications/Brave Browser.app"
```

To repair only the native host manifests from the source tree, run:

```bash
scripts/install_chromium_native_host
```

The app and script install the host for common Chromium-family browsers on macOS, including Arc, Google Chrome, Chrome Canary, Chromium, Brave channels, Microsoft Edge channels, Vivaldi, Opera, Opera GX, and Helium. The script reads the one supported extension ID from `ChromiumBridgeProtocol/contract.json`; divergent IDs are not accepted. When `Keyway.app` is installed, the script points browser manifests at the bundled helper; otherwise it builds and registers the source-tree debug helper for local smoke testing.

## Smoke Test

The live smoke requires Playwright to be resolvable by Node.js. It launches a temporary Brave or Chrome profile with this unpacked extension, a signed isolated app-bridge peer, and two local media tabs. It then verifies mutual bridge authentication, exact-tab focus, Play/Pause, reflected mute, isolated volume, and page-backed Next/Previous through the native host without using the installed app's live socket:

```bash
scripts/smoke_chromium_extension_transport
```

For Helium specifically:

```bash
scripts/smoke_helium_chromium_extension_transport
```

Quit Helium before this smoke. If Helium is already running, set `KEYWAY_HELIUM_SMOKE_RESTART=1` to allow the script to quit it for the isolated run and restore it afterward.

Set `KEYWAY_CHROMIUM_EXTENSION_ITERATIONS=10` for a shorter local pass. The regression gate runs this smoke only when `KEYWAY_CHROMIUM_EXTENSION_SMOKE=1` is set.
