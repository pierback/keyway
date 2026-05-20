# Context Map

## Contexts

- [Keyway](./CONTEXT.md) — product-level language for transport-key routing, media target selection, overlays, settings, and shared capabilities.
- [Sonos Handoff](./docs/contexts/sonos-handoff/CONTEXT.md) — capability language for Sonos Outputs, Spotify Connect handoff, Sonos volume, and existing menu bar runtime behavior.

## Relationships

- **Keyway → Sonos Handoff**: Keyway includes Sonos Handoff as a capability, not as the product identity.
- **Sonos Handoff → Keyway**: Sonos Handoff contributes existing menu bar, shortcut, HUD, Spotify, and Sonos infrastructure to the broader Keyway app.
- **Keyway ↔ Sonos Handoff**: Shared settings, shortcut runtime, and overlay/HUD infrastructure must keep product-level language distinct from Sonos-specific Output and handoff language.
