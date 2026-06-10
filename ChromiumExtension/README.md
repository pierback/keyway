# Keyway Chromium Media Bridge

The extension makes browser media deterministic by giving Keyway an exact target address:

```text
chromium-extension:<browser-runtime>:<window-id>:<tab-id>:<frame-id>:<media-id>
```

The browser runtime component includes the detected Chrome-family browser and extension runtime ID, so Chromium-family targets do not collapse into the same identity when tab IDs overlap. The unpacked extension has a stable manifest key, so its runtime ID is deterministic: `gmdpkggbaohimgacbclndlfjghgcbael`. The address lets the Swift app send a command to the same browser tab, frame, and media element that reported playback. This avoids the OS media-key ambiguity where Chromium, Spotify, and Helium compete for the same global transport commands.

## Architecture

- `content_script.js` discovers `video` and `audio` elements in each page/frame and reports title, page title, URL, playback state, duration, and elapsed time.
- `service_worker.js` keeps a live target map and talks to Chrome native messaging.
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

The live smoke test launches a temporary Brave or Chrome profile with this unpacked extension, opens two local media tabs, and sends exact-target `mute` commands through the native host:

```bash
scripts/smoke_chromium_extension_transport
```

For Helium specifically:

```bash
scripts/smoke_helium_chromium_extension_transport
```

Set `KEYWAY_CHROMIUM_EXTENSION_ITERATIONS=10` for a shorter local pass. The regression gate runs this smoke only when `KEYWAY_CHROMIUM_EXTENSION_SMOKE=1` is set.
