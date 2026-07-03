# Scope Tab-Level Capabilities to Extension-Backed Browsers

We decided that tab-scoped capabilities (tab focus, per-tab mute, per-tab media targets) are delivered only through a browser-extension pipeline, one per browser platform — never through OS-level guessing. The shipped pipeline covers the Chromium family (Chrome, Brave, Edge, Arc, Helium, Vivaldi, Opera) via one MV3 extension and one native-messaging host. The user's confirmed browser set is Chromium-family daily plus Safari as desired; Safari support is a separate platform port (Safari Web Extension inside a signed containing app) to be scoped by its own spike, not an extension of this pipeline. Firefox is out of scope. "Any browser" via generic OS automation is rejected: there is no honest OS-level route to tab identity, and pretending otherwise produced the stale-row and false-flag bugs this redesign eliminated.

**Consequences**

- Degradation is capability-driven and never silent: a source without a live extension route offers `focusApp` (whole-app activation), not a tab-focus affordance that lies. Chromium targets on a suspect route degrade to `focusApp` too.
- Safari, if pursued, gets its own ADR and pipeline; nothing in the Chromium pipeline may assume it is the only extension family.
- Non-extension browsers still appear as sources through MediaRemote, with app-level capabilities only.
