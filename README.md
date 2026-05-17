# sonos-handoff

`sonos-handoff` is a native macOS menu bar app for handing off the current Spotify playback session to a Sonos speaker while keeping Spotify as the playback controller.

## Current Status

Current transfer behavior:

- the app and `sonos-handoff-port` activate Spotify Connect on the Sonos speaker through the Sonos local network endpoint
- the menu bar Output list renders Sonos groups as one selectable Output row and exposes Option-held group editing for the selected Spotify-on-Sonos group
- group editing can add standalone speakers, remove group members, and remove the coordinator by migrating playback to a replacement member
- background sync prompts for newly visible standalone Sonos speakers when Spotify is already playing on a Sonos Output, with a notification action and in-menu fallback row
- volume control talks directly to the Sonos speaker over local SOAP and defaults to 5 percent steps; CLI step overrides are clamped to 5...25
- Spotify Web API is used only to verify that playback becomes active on the target after handoff
- the menu bar app registers `Shift+F10/F11/F12` for Port mute/down/up, and enables held `Shift+fn+F10/F11/F12` control only when Accessibility permission allows key interception
- handoff requires the desktop Connect token and Web API token files in `~/Library/Application Support/sonos-handoff`

## Prerequisites

- macOS with Xcode 26.2 or newer
- Swift 6.2 or newer
- Ruby with the `xcodeproj` gem available if you need to regenerate project files

## Project Layout

- `apps/SonosHandoffMenuBar`: native macOS status item app
- `apps/SonosHandoffCLI`: command-line interface
- `packages/SonosHandoffCore`: shared types and services
- `docs`: architecture and runtime flow notes

## Open the Workspace

Open [SonosHandoff.xcworkspace](/Users/f.pieringer/projects/sonos-handoff/SonosHandoff.xcworkspace) in Xcode.

## Bootstrap

Bootstrap the full scaffold from a fresh checkout:

```bash
/Users/f.pieringer/projects/sonos-handoff/scripts/bootstrap
```

This script:

- ensures the `xcodeproj` Ruby gem is available
- regenerates the Xcode workspace and projects
- builds and tests `SonosHandoffCore`
- builds and tests the CLI target
- builds the menu bar app target

## Build

Build the shared package:

```bash
cd /Users/f.pieringer/projects/sonos-handoff/packages/SonosHandoffCore
swift build
```

Run package tests:

```bash
cd /Users/f.pieringer/projects/sonos-handoff/packages/SonosHandoffCore
swift test
```

Build the CLI from Xcode:

```bash
xcodebuild -workspace /Users/f.pieringer/projects/sonos-handoff/SonosHandoff.xcworkspace -scheme SonosHandoffCLI build
```

Build the menu bar app from Xcode:

```bash
xcodebuild -workspace /Users/f.pieringer/projects/sonos-handoff/SonosHandoff.xcworkspace -scheme SonosHandoffMenuBar build
```

Install the menu bar app:

```bash
/Users/f.pieringer/projects/sonos-handoff/scripts/install_menubar_app
```

The installer prefers the first available Apple Development code-signing identity so macOS Accessibility permission can persist across rebuilds. If no identity exists, it falls back to ad-hoc signing and Accessibility may need to be granted again after each rebuild.

## CLI Commands

```text
sonos-handoff target add <alias>
sonos-handoff target list
sonos-handoff transfer <alias>
sonos-handoff doctor
sonos-handoff-port handoff Port
sonos-handoff-port volume-status Port
sonos-handoff-port volume-down Port
sonos-handoff-port volume-up Port
sonos-handoff-port volume-up Port --step 10
sonos-handoff-safe-grouping-check
sonos-handoff-safe-grouping-check --prepare-silent
sonos-handoff-safe-grouping-check --mutate --i-understand-this-mutates-sonos-groups
/Users/f.pieringer/projects/sonos-handoff/scripts/smoke_cli_transfer port
/Users/f.pieringer/projects/sonos-handoff/scripts/smoke_cli_handoff Port
/Users/f.pieringer/projects/sonos-handoff/scripts/smoke_menubar_handoff Port
/Users/f.pieringer/projects/sonos-handoff/scripts/smoke_menubar_hotkey Port
```

## Runtime Setup

1. Ensure these files exist in `~/Library/Application Support/sonos-handoff`:
   - `spotify-desktop-connect-tokens.json`
   - `project-webapi-token.json`
2. Save a target alias and exact Spotify/Sonos room name in the app settings.
3. Run `sonos-handoff doctor` and confirm both token checks and saved targets are valid.
4. Keep Spotify actively playing before handoff.

The menu has `Check Shortcut Status` and volume status actions. Physical `Shift+fn+F10/F11/F12` uses the Mac media/function keys, so the installed app must be enabled in Accessibility before held repeat is reliable; otherwise the app leaves the `Shift+fn` path disabled and shows a permission HUD. Plain `Shift+F10/F11/F12` remains the Carbon fallback for mute/down/up.

Grant Accessibility to the installed app at:

```text
/Users/f.pieringer/Applications/Sonos Handoff.app
```

After granting permission, restart the app or click `Check Shortcut Status`. Logs should change from `event_tap_create_failed accessibility=false` to `mediaFallback=enabled events=systemDefined`.

## Grouping Validation

Run the grouping checker without flags first. Dry-run mode discovers Sonos groups and reports whether the current network is ready for a live grouping test. It does not change volume, mute state, playback, or groups.

```bash
cd /Users/f.pieringer/projects/sonos-handoff
swift run --package-path packages/SonosHandoffCore sonos-handoff-safe-grouping-check
```

For live validation, first prepare silent mode or use mutation mode, which always mutes every discovered speaker and sets every discovered speaker to volume `0` before touching groups. Mutation mode then validates standalone join/remove and coordinator removal with the `<2s` migration timing gate.

## Notes

- `sonos-handoff doctor` treats Spotify as authenticated only when both token files required by the current handoff path are present.
- Grouping validation requires at least one visible Spotify-on-Sonos Output and enough visible speakers for the selected grouping scenario.
- The app does not use Spotify Web API available-device transfer because `/me/player/devices` can omit Sonos speakers.
