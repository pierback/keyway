# Keyway Chromium Media Bridge

The extension makes browser media deterministic by giving Keyway an exact target address:

```text
chromium-extension:<browser-runtime>:<window-id>:<tab-id>:<frame-id>:<media-id>
```

The browser runtime component includes the detected Chrome-family browser and extension runtime ID, so Chrome, Chromium, Brave, and Edge targets do not collapse into the same identity when tab IDs overlap. The unpacked extension has a stable manifest key, so its runtime ID is deterministic: `gmdpkggbaohimgacbclndlfjghgcbael`. The address lets the Swift app send a command to the same browser tab, frame, and media element that reported playback. This avoids the OS media-key ambiguity where Chromium, Spotify, and Helium compete for the same global transport commands.

## Architecture

- `content_script.js` discovers `video` and `audio` elements in each page/frame and reports title, page title, URL, playback state, duration, and elapsed time.
- `service_worker.js` keeps a live target map and talks to Chrome native messaging.
- `keyway-chromium-native-host` bridges native messages into Keyway with distributed notifications.
- `ChromiumBrowserExtensionController` merges browser targets into Keyway's existing media target list and routes browser commands back through the native host.

The browser backend supports `play`, `pause`, `playPause`, `mute`, and volume delta. Generic browser `next` and `previous` are intentionally unsupported until site-specific adapters exist.

## Local Install

1. Install the native host manifest:

```bash
scripts/install_chromium_native_host
```

2. Open `chrome://extensions`, enable Developer Mode, and load this `ChromiumExtension` directory as an unpacked extension.

The script installs the host for Google Chrome, Chromium, Brave, and Microsoft Edge on macOS. It reads the extension ID from the manifest key; pass an explicit ID only when testing a different unpacked extension build.

## Smoke Test

The live smoke test launches a temporary Brave or Chrome profile with this unpacked extension, opens two local media tabs, and sends exact-target `mute` commands through the native host:

```bash
scripts/smoke_chromium_extension_transport
```

Set `KEYWAY_CHROMIUM_EXTENSION_ITERATIONS=10` for a shorter local pass. The regression gate runs this smoke only when `KEYWAY_CHROMIUM_EXTENSION_SMOKE=1` is set.
