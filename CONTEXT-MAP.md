# Context Map

## Contexts

- [Keyway](./CONTEXT.md) — product-level language for transport-key routing, media target selection, overlays, settings, and shared capabilities.
- [Sonos Handoff](./docs/contexts/sonos-handoff/CONTEXT.md) — capability language for Sonos Outputs, Spotify Connect handoff, Sonos volume, and existing menu-bar runtime behavior.
- [System architecture](./docs/architecture.md) — layer direction, process boundaries, mutable-state authority, and cross-process ordering rules.
- [Chromium media bridge](./ChromiumExtension/README.md) — content-script, MV3 worker, native-host, and app-controller ownership and recovery semantics.
- [2026-07-31 refactoring report](./docs/refactoring-2026-07-31.md) — evidence-backed changes, verification results, remaining risks, and file inventory for the current refactor.

## Relationships

- **Keyway -> Sonos Handoff**: Keyway includes Sonos Handoff as a capability, not as the product identity.
- **Sonos Handoff -> Keyway**: Sonos Handoff contributes existing menu bar, shortcut, HUD, Spotify, and Sonos infrastructure to the broader Keyway app.
- **Keyway <-> Sonos Handoff**: Shared settings, shortcut runtime, and overlay/HUD infrastructure must keep product-level language distinct from Sonos-specific Output and handoff language.
- **Presentation -> application orchestration -> core policy/integrations**: SwiftUI and AppKit render state and send intent; app controllers own lifecycle and correlation; `SonosHandoffCore` owns shared deterministic and integration policy. Dependencies do not point back toward presentation.
- **Keyway app <-> MediaRemote helper pair**: The app supervises snapshot and command helpers as one generation over newline-delimited JSON. Helpers expose MediaRemote state and commands but do not own target-selection or UI policy.
- **Keyway app <-> Chromium native host**: Distributed notifications carry bounded snapshot, command, focus, and result payloads. The app owns profile/connection state; the native host owns framing, browser identity, and one connection generation.
- **Chromium native host <-> MV3 service worker**: Chrome native messaging preserves the existing four-byte little-endian framing and JSON schema. Private connection correlation prevents stale hosts from routing commands or results.
- **MV3 service worker <-> content scripts**: The worker owns tab/frame authority and canonical tab sources; each content script owns only its current frame document and media elements. Navigation generations reject late messages from retired documents.
- **Service worker -> pure extension policy**: `service_worker.js` may depend on `document_authority.js` and `media_source_selection.js`; those modules must remain deterministic and Chrome-API-free.
