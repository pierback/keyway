# Extension Is Load-Bearing for Browser Capabilities

Supersedes ADR 0002. We decided the Chromium extension is a required, load-bearing component for every browser-tab capability: per-tab media targets, tab focus, per-tab mute with reflected state, and per-tab volume. There is no MediaRemote or AppleScript route to per-tab audio, so ADR 0002's "extension optional" stance is impossible to keep while delivering mute reflection; the extension is already installed at launch and covered by the regression gate.

ADR 0002's real concern is preserved as a hard invariant rather than dropped: **transport routing must never depend on the extension.** Play/Pause/Next/Previous via MediaRemote and Sonos work with the extension absent, browser capabilities disappear cleanly (capability-driven, per ADR 0004) rather than erroring, and the menu-bar dot stays green with the extension absent while MediaRemote routing is live — a missing extension is a reduced feature set, not a degraded transport.

**Consequences**

- Extension lifecycle failures (worker suspension, native-host death, browser quit) must degrade to hidden-or-suspect rows, never to blocked transport routing or a false global health warning.
- The regression gate keeps both worlds honest: extension semantics are verified on every run, and MediaRemote-only routing paths must keep passing with no extension state present.
- Per-tab volume remains element-level best-effort (no tabs-API equivalent); tab-level mute is the reflected source of truth.
