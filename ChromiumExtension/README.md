# Keyway Chromium Media Bridge

The extension makes browser media deterministic by giving Keyway one canonical source row for each browser tab/session:

```text
chromium-tab:<profile-guid>:<tab-id>
```

The profile GUID is minted once by the extension and persisted in `chrome.storage.local`, so a tab keeps the same Keyway identity across native-host process churn and service-worker restarts. The unpacked extension has a stable manifest key, so its runtime ID is deterministic metadata: `gmdpkggbaohimgacbclndlfjghgcbael`. The service worker keeps frame and media element IDs as private route state and sends commands to the selected element for the source. This avoids both OS media-key ambiguity and duplicate Keyway rows when one page exposes several media elements.

## Architecture

- `content_script.js` discovers `video` and `audio` elements in each page/frame and reports title, page title, URL, playback state, duration, and elapsed time.
- `service_worker.js` aggregates media candidates into one live source per tab/session and talks to Chrome native messaging.
- `keyway-chromium-native-host` bridges native messages into Keyway with distributed notifications.
- `ChromiumBrowserExtensionController` merges browser targets into Keyway's existing media target list and routes browser commands back through the native host.

The browser backend supports `play`, `pause`, `playPause`, `mute`, and volume delta. Browser `next` and `previous` are exposed only when the page provides a usable track control, such as Spotify Web or YouTube skip controls; generic `<audio>` and `<video>` elements still report those commands as unsupported.

## Local Install

1. Open Keyway once. The app installs or repairs the native host manifest at launch, pointing Chrome-family browsers at the helper bundled in `Keyway.app/Contents/Helpers`.

2. In Keyway Settings -> Transport Routing, use:

- `Repair Bridge` to reinstall the native host manifests.
- `Reveal Extension` to show the bundled `Keyway.app/Contents/Resources/ChromiumExtension` folder.
- `Open Extensions` to open `chrome://extensions`.

3. Enable Developer Mode in the target browser and load the revealed `ChromiumExtension` folder as an unpacked extension.

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

The app and script install the host for common Chromium-family browsers on macOS, including Arc, Google Chrome, Chrome Canary, Chromium, Brave channels, Microsoft Edge channels, Vivaldi, Opera, Opera GX, and Helium. The script reads the extension ID from the manifest key; pass an explicit ID only when testing a different unpacked extension build. When `Keyway.app` is installed, the script points browser manifests at the bundled helper; otherwise it builds and registers the source-tree debug helper for local smoke testing.

## Smoke Test

The live smoke test launches a temporary Brave or Chrome profile with this unpacked extension, opens two local media tabs, sends exact-target commands through the native host, and verifies exact-tab focus by switching the active tab for each source:

```bash
scripts/smoke_chromium_extension_transport
```

For Helium specifically:

```bash
scripts/smoke_helium_chromium_extension_transport
```

Set `KEYWAY_CHROMIUM_EXTENSION_ITERATIONS=10` for a shorter local pass. The regression gate runs this smoke only when `KEYWAY_CHROMIUM_EXTENSION_SMOKE=1` is set.
