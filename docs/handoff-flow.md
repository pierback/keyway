# Handoff Flow

## Transfer Runtime Flow

1. Resolve a saved alias to an exact Spotify/Sonos room name.
2. Discover the Sonos speaker on the local network and read its Spotify zeroconf metadata.
3. Refresh the stored Spotify Desktop Connect token.
4. Exchange the desktop token for a Spotify Connect authorization code scoped to Sonos.
5. Activate the Sonos Spotify Connect endpoint through `/spotifyzc`.
6. Ask Sonos to play, then verify through Spotify Web API that the active device is the target room.

## Grouped Output Runtime Flow

1. Discover visible Sonos speakers through DNS-SD.
2. Read `ZoneGroupTopology.GetZoneGroupState` from Sonos and parse the visible speakers into `SonosGroupState`.
3. Render each `SonosSpeakerGroup` as one Output row using Spotify-style group names such as `Kitchen + Port` or `Kitchen + 2`.
4. Select the group coordinator when the active Spotify device matches a group member, a pair group name, or a count-suffix group name.
5. Transfer to a grouped row through the coordinator, keeping Spotify as the controller after handoff.

## Option-Mode Group Editing Flow

1. While the menu is open, hold Option to switch the Output section into group editing.
2. Build membership rows for the currently selected Spotify-on-Sonos group.
3. Clicking a standalone speaker joins it to the selected group's coordinator.
4. Clicking a non-coordinator member removes it from the group.
5. Clicking a coordinator in a multi-speaker group removes the coordinator by selecting a replacement member, rebuilding the remaining group around that replacement, and transferring Spotify playback to the replacement with coordinator-migration verification.

## Background Group Suggestion Flow

1. Background playback sync polls the active Spotify device and refreshes cached Sonos group state.
2. If Spotify is playing on a visible Sonos Output and a standalone Sonos speaker newly appears, `SonosGroupSuggestionTracker` produces one current suggestion.
3. The app stores that suggestion for the in-menu fallback row and delivers a macOS notification with a `Group` action.
4. Accepting from the notification or the menu joins the suggested speaker to the active group's coordinator, clears the suggestion, and refreshes the Output list.
5. If playback stops, auth is required, the suggested speaker disappears, or the speaker joins another group, the suggestion is cleared.

## Safe Grouping Validation Flow

1. Run `sonos-handoff-safe-grouping-check` without flags to inspect discovered groups and readiness without mutating volume, mute, playback, or groups.
2. Run `sonos-handoff-safe-grouping-check --prepare-silent` to mute every discovered speaker and set every discovered speaker to volume `0`, then verify that safety state.
3. Run `sonos-handoff-safe-grouping-check --mutate --i-understand-this-mutates-sonos-groups` only after the dry-run is ready. Mutation mode always performs the same silent preparation before touching groups.
4. Mutation mode validates standalone join/remove and coordinator removal. Coordinator migration fails if the remove-and-transfer path takes longer than 2 seconds.

## Transfer Strategy

### Transfer path

- Sonos local network discovery, zeroconf, and SOAP control
- Sonos ZoneGroupTopology discovery for grouped Output rows and group editing
- Spotify token exchange for Sonos Connect activation
- Spotify Web API active-device verification after handoff

### Explicitly excluded

- Spotify Web API available-device transfer
- Spotify Web API playback preflight
- Spotify desktop UI automation as the primary transfer path

Spotify Web API available-device transfer remains excluded because `/me/player/devices` can omit Sonos speakers.

## Expected Failure Codes

- `noActivePlayback`
- `targetNotConfigured`
- `targetNotVisible`
- `spotifyAppNotInstalled`
- `spotifyAppNotRunning`
- `accessibilityNotGranted`
- `authRequired`
- `transferVerificationFailed`
- `unsupported`
