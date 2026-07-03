# Do Not Require a Browser Extension for Volume

**Superseded by ADR 0005.** The extension is now load-bearing for browser-tab capabilities; this ADR's core concern — transport routing must never depend on the extension — survives there as a hard invariant.

We decided that Keyway will not require a companion browser extension for the full implementation milestone. Browser Media Targets must support transport routing through Now Playing where possible, but browser volume controls may be disabled because reliable per-tab volume would require a separate browser integration that changes installation, permissions, and maintenance scope.

**Consequences**

- Sonos and Spotify Audio Target Control remain required where controllable through app-owned or existing platform backends.
- Browser targets can appear in Expanded Controls with disabled or unsupported volume affordances.
- A browser extension can be reconsidered later as a separate capability, not as part of the initial Keyway cutover.
