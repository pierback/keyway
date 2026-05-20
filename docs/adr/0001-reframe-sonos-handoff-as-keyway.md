# Reframe Sonos Handoff as Keyway

We decided to reframe the existing `sonos-handoff` app and repository into **Keyway** rather than starting a separate project. The existing app already owns the macOS menu bar shell, Accessibility-gated event tap, shortcut runtime, signing/install flow, and HUD infrastructure, while Sonos handoff becomes one capability alongside Media Target Routing instead of the product identity.

**Considered Options**

- Start a new Keyway repo and migrate Sonos Handoff later.
- Keep Sonos Handoff as the product name and add Media Target Routing inside it.
- Reframe the existing app as Keyway and keep Sonos-specific modules as a capability boundary.

**Consequences**

- Product-facing names move to Keyway through a hard cutover.
- Sonos-specific code can keep Sonos names where it still represents the Sonos handoff capability.
- Shared macOS infrastructure should be extracted or renamed only when capability boundaries require it, not by a broad mechanical rename first.
