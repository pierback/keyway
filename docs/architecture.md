# Architecture

## Overview

The repository is split into three layers:

```text
Menu Bar App  ----\
                    >  SonosHandoffCore
CLI            ----/
```

## Responsibilities

### `SonosHandoffMenuBar`

- owns the native macOS status item lifecycle
- exposes transfer, doctor, settings, Port volume, and Port mute actions
- logs and displays the Port's reported volume and fixed-output state for volume troubleshooting
- registers Carbon global hotkeys for `Shift+F10/F11/F12`
- enables the held `fn+F10/F11/F12` key-intercept path only after Accessibility permission allows the app to intercept and suppress native media/function-key events
- delegates all non-UI work to `SonosHandoffCore`

### `SonosHandoffCLI`

- exposes scriptable subcommands
- delegates auth, target management, transfer, and diagnostics to `SonosHandoffCore`
- returns stable text output and exit codes

### `SonosHandoffCore`

- shared models and errors
- config loading and saving
- keychain abstraction
- Spotify token status and playback-state verification boundaries
- Accessibility automation boundary
- handoff orchestration
- Sonos local-network control for Spotify Connect activation, volume, and volume status
- diagnostics aggregation

## Why Spotify Available-Device Transfer Is Excluded

The product goal is to keep Spotify as the controller after handoff. The Spotify Web API available-devices endpoint can omit Sonos speakers, so the core flow does not rely on Spotify Web API device discovery or Web API transfer:

1. resolve a saved target alias
2. discover the Sonos speaker locally
3. activate its Spotify Connect endpoint
4. verify that Spotify reports playback on the target

The Sonos calls are limited to activating Spotify Connect and adjusting volume. Track control remains in Spotify after handoff.
