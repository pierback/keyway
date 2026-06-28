# Keyway

Keyway is a macOS menu bar utility that routes transport keys and media controls to the intended app, session, or output.

## Language

**Keyway**:
A macOS menu bar utility for routing transport keys and media controls to the intended target.
_Avoid_: Sonos Handoff, Baton, Cue

**Media Target Router**:
A Keyway capability that routes a hardware media command to a selected active media session.
_Avoid_: Media chooser, media switcher, media controller

**Media Target Chooser**:
A transient UI state where the user selects the media session that should receive a pending media command.
_Avoid_: Modal app, player list

**Media Overlay**:
The centered transient UI that can appear in compact command-routing form or expand to expose richer controls.
_Avoid_: Modal, popup, panel

**Command Palette Overlay**:
The Raycast-like visual form of the Media Overlay, centered on the Overlay Display.
_Avoid_: Alcove-like overlay, notch overlay

**Command Header**:
The non-editable header text that names the pending routing action in the Command Palette Overlay.
_Avoid_: Search field, filter input

**Routing Confirmation**:
A brief non-interactive visual acknowledgement shown after automatic routing.
_Avoid_: Notification, toast

**Keyway Settings**:
A normal macOS settings window for configuring Keyway capabilities and permissions.
_Avoid_: Settings overlay, preferences popover

**Menu Bar Item**:
The always-visible status item that provides access to Keyway status, settings, and recovery actions.
_Avoid_: Hidden agent

**Config Import**:
A one-time copy of existing Sonos Handoff local configuration into Keyway's application support directory.
_Avoid_: Shared config, migration

**Distinct App Transition**:
The development period where Keyway and the old Sonos Handoff app are treated as separate applications.
_Avoid_: In-place migration, shared runtime

**Sonos Capability Regression Boundary**:
The existing Sonos handoff and Sonos volume behavior that Keyway must preserve while it rebrands and expands the app.
_Avoid_: Best-effort preservation

**Media Target**:
An app-level media session that macOS exposes through Now Playing and can plausibly receive media commands.
_Avoid_: Audio source, browser tab, output stream

**Current Media Target**:
The only actively playing Media Target when exactly one target is playing, used for automatic routing before focus or recent fallback.
_Avoid_: Default player, active app

**Focused Target**:
The Media Target most likely intended by the user because its app or window currently has foreground attention.
_Avoid_: Frontmost media app, active screen app

**Foreground App Target**:
A Media Target whose application is the current global foreground app.
_Avoid_: Active app

**Prominent Window Target**:
A Media Target whose window is visibly prominent on the active display when no Foreground App Target exists.
_Avoid_: Visible app, active screen app

**Recent Target**:
The most recently selected Media Target that remains available for routing future ambiguous commands.
_Avoid_: Sticky target, default app

**Target Selection Policy**:
The ordered decision process that chooses a Media Target before falling back to the chooser.
_Avoid_: Heuristic, routing guess

**Pending Command**:
A hardware media command being held until the router chooses or receives a Media Target.
_Avoid_: Shortcut, action

**Transport Key**:
A hardware key for play/pause, next, or previous.
_Avoid_: Media key, volume key

**Expanded Controls**:
The richer Media Overlay state for inspecting targets and adjusting controls beyond routing a Pending Command.
_Avoid_: Separate mixer, volume modal

**Audio Target Control**:
Target-specific volume or mute control exposed inside Expanded Controls.
_Avoid_: Browser volume routing, system volume control

**MediaRemote Helper**:
The isolated helper backend that loads Keyway's private MediaRemote bridge through `/usr/bin/perl`.
_Avoid_: Native MediaRemote client, direct private API calls

**Helper Message**:
A newline-delimited JSON message exchanged between Keyway and the MediaRemote Helper.
_Avoid_: XPC message, ad hoc stdout

**Spotify Active Device Volume**:
The volume of the current Spotify playback device as controlled through Spotify or the active Sonos Output.
_Avoid_: Spotify app volume

**Overlay Display**:
The display where the Media Overlay appears.
_Avoid_: Active screen

## Relationships

- **Keyway** contains the **Media Target Router** capability.
- **Keyway** may contain a Sonos handoff capability without making Sonos the product identity.
- Sonos Outputs are playback destinations for the Sonos handoff capability, not top-level **Media Targets** unless macOS exposes them as Now Playing clients.
- A **Media Target Router** may show a **Media Target Chooser** when more than one media session can receive a command.
- A **Media Target Chooser** is the compact command-routing form of the **Media Overlay**.
- The **Media Overlay** uses a **Command Palette Overlay** visual direction rather than an Alcove-style notch surface.
- The **Command Palette Overlay** does not include search; it uses a **Command Header** instead.
- A **Media Target** is included because it is visible to Now Playing, not because it is merely producing audio.
- The **Target Selection Policy** prefers a single **Media Target**, then a **Current Media Target** when exactly one target is actively playing, then a **Focused Target**, then a **Recent Target**, then the **Media Target Chooser**.
- A **Current Media Target** is automatic when exactly one target is actively playing.
- A new **Media Target Chooser** session starts with row 1 selected.
- The **Media Overlay** lists currently playing targets before inactive targets, and **Recent Target** memory can lift a target ahead of peers with the same playback state.
- **Recent Target** is not displayed as its own group; it may explain why a target appears earlier in the list.
- A **Recent Target** is automatic within the current Keyway run: selecting or focusing a target updates it, and it is used only while that exact **Media Target** remains available.
- A **Focused Target** is first resolved as a **Foreground App Target**, then as a **Prominent Window Target**.
- A **Media Target Chooser** resolves a **Pending Command**; selecting a target dispatches that command to the target.
- Cancelling the **Media Target Chooser** discards the **Pending Command**.
- **Expanded Controls** are reached from the **Media Overlay** by an explicit shortcut, not by hardware volume keys.
- In compact command-routing form, the **Media Overlay** uses up/down to change target, enter to dispatch the **Pending Command**, escape to cancel, and tab to toggle **Expanded Controls**.
- In compact command-routing form, plain number keys `1` through `9` immediately dispatch the **Pending Command** to the corresponding visible target.
- In **Expanded Controls**, `Command+Up` and `Command+Down` adjust the selected target's volume when supported, and mute is exposed through target-specific controls where available.
- In **Expanded Controls**, number keys change selection without immediately dispatching a **Pending Command**.
- **Audio Target Control** is required for Sonos and Spotify where controllable without companion browser software.
- Spotify **Audio Target Control** means **Spotify Active Device Volume**, not a Mac app-local volume.
- Browser **Media Target** transport routing is required, but browser **Audio Target Control** may be disabled when it would require a browser extension.
- Keyway uses the **MediaRemote Helper** for private Now Playing session access.
- The **MediaRemote Helper** is a long-running process so target snapshots and command dispatch stay low-latency.
- Keyway and the **MediaRemote Helper** communicate using **Helper Messages**.
- A **Routing Confirmation** appears only when routing succeeds without showing the **Media Overlay**.
- **Keyway Settings** behaves like a normal Dock-visible app while the settings window is visible, even though Keyway is menu-bar-first by default.
- Keyway always shows a **Menu Bar Item**.
- **Config Import** copies from the old Sonos Handoff support directory into Keyway's support directory without modifying the old files.
- During the **Distinct App Transition**, Keyway uses its own bundle identity and does not manage the old Sonos Handoff app process.
- The **Sonos Capability Regression Boundary** protects existing Sonos handoff and volume behavior; visual presentation may change, but core behavior must remain intact.
- When enabled, the **Media Target Router** suppresses original **Transport Key** events and dispatches the resulting **Pending Command** itself.
- Hardware volume and mute keys are not **Transport Keys** in v1.
- The **Overlay Display** is the display containing the mouse pointer, falling back to the main display.

## Example dialogue

> **Dev:** "When the play/pause key is pressed, should the **Media Target Router** always show the **Media Target Chooser**?"
> **Domain expert:** "No. Show the **Media Target Chooser** only when there is more than one plausible target."

> **Dev:** "Is this still Sonos Handoff?"
> **Domain expert:** "No. The broader product is **Keyway**; Sonos handoff can become one capability inside it."

> **Dev:** "Should a Sonos room appear next to Spotify and QuickTime in the compact routing list?"
> **Domain expert:** "No. Sonos Outputs appear under expanded Spotify/Sonos controls, not as top-level **Media Targets**."

> **Dev:** "Should QuickTime Player be a **Media Target**?"
> **Domain expert:** "Yes, when QuickTime exposes its playback through Now Playing; an app that only produces audio is not enough."

> **Dev:** "Spotify was selected last, but QuickTime is the foreground app. Which receives play/pause?"
> **Domain expert:** "QuickTime, because the **Focused Target** wins before the **Recent Target**."

> **Dev:** "Spotify is the only actively playing target, but QuickTime is frontmost and paused. Which receives next?"
> **Domain expert:** "Spotify, because the **Current Media Target** wins before **Focused Target** or **Recent Target** when exactly one target is actively playing."

> **Dev:** "If nothing is actively playing, should the router remember that Spotify was chosen last?"
> **Domain expert:** "Yes, as a weak **Recent Target** fallback."

> **Dev:** "What row is selected when the chooser opens?"
> **Domain expert:** "A new chooser session starts with row 1 selected."

> **Dev:** "What happens if the remembered Spotify target disappears?"
> **Domain expert:** "The **Recent Target** is used only while that exact **Media Target** remains available."

> **Dev:** "Do we intercept volume keys too?"
> **Domain expert:** "No. v1 owns **Transport Keys** only; volume and mute keys remain system behavior."

> **Dev:** "Where should the overlay appear with multiple monitors?"
> **Domain expert:** "Use the **Overlay Display**, which is the display currently containing the pointer."

> **Dev:** "Should the overlay look like Alcove around the menu bar?"
> **Domain expert:** "No. Use a centered **Command Palette Overlay** closer to Raycast."

> **Dev:** "Should the Raycast-like overlay have a search box?"
> **Domain expert:** "No. Use the Raycast visual style, but replace search with a **Command Header**."

> **Dev:** "If the router automatically sends play/pause to Spotify, should anything appear?"
> **Domain expert:** "Yes, show a brief **Routing Confirmation** so the user knows which target received the command."

> **Dev:** "Should settings be another overlay?"
> **Domain expert:** "No. **Keyway Settings** is a normal macOS settings window and should be reachable through Cmd-Tab while visible."

> **Dev:** "Can Keyway hide completely and rely only on shortcuts?"
> **Domain expert:** "No. The **Menu Bar Item** is always visible so permissions and routing state are recoverable."

> **Dev:** "Should Keyway keep using the old Sonos Handoff config directory?"
> **Domain expert:** "No. Use **Config Import** so the old app remains usable while Keyway owns its own state."

> **Dev:** "Can Keyway and old Sonos Handoff coexist while Keyway is unfinished?"
> **Domain expert:** "Yes. During the **Distinct App Transition**, they are separate apps with separate identity and state."

> **Dev:** "Can Keyway redesign the old Sonos menu?"
> **Domain expert:** "Yes, but the **Sonos Capability Regression Boundary** means existing Sonos handoff and volume behavior must still work."

> **Dev:** "Zed is foreground, Spotify is playing, and Helium video is visibly floating on the display. Which target wins?"
> **Domain expert:** "Helium can win as the **Prominent Window Target** if there is no **Foreground App Target**."

> **Dev:** "If the chooser appears after pressing play/pause, does selecting Spotify only set a future preference?"
> **Domain expert:** "No, it sends the current **Pending Command** to Spotify immediately."

> **Dev:** "Should volume controls appear every time a hardware media key needs routing?"
> **Domain expert:** "No, the **Media Overlay** starts compact and can reveal **Expanded Controls** only when explicitly requested."

> **Dev:** "Should browser targets expose volume sliders?"
> **Domain expert:** "Only if Keyway can control them without a browser extension; browser transport routing remains required."

> **Dev:** "Why does Keyway use `/usr/bin/perl` for media sessions?"
> **Domain expert:** "Because direct third-party MediaRemote calls are filtered, so private API access is isolated in the **MediaRemote Helper**."

> **Dev:** "Should the helper launch once per media key?"
> **Domain expert:** "No. The **MediaRemote Helper** is long-running and streams state to Keyway."

> **Dev:** "How should Keyway talk to the helper?"
> **Domain expert:** "Use **Helper Messages** as newline-delimited JSON over standard input and output."

> **Dev:** "Does the Spotify slider control the Mac app's private volume?"
> **Domain expert:** "No. It controls **Spotify Active Device Volume**."

## Flagged ambiguities

- "Chooser" was used to describe the whole app, but the resolved product concept is **Media Target Router**; **Media Target Chooser** is only the temporary selection UI.
- "Audio source" was considered as a target concept, but the resolved term is **Media Target**; targets are Now Playing sessions, not arbitrary audible processes.
- "Frontmost on the active screen" was narrowed to **Focused Target**, because macOS has one frontmost app while displays, spaces, and windows add ambiguity.
