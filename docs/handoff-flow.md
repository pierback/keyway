# Handoff Flow

## Intended Runtime Flow

1. Resolve a saved alias to an exact Spotify/Sonos room name.
2. Discover the Sonos speaker on the local network and read its Spotify zeroconf metadata.
3. Refresh the stored Spotify Desktop Connect token.
4. Exchange the desktop token for a Spotify Connect authorization code scoped to Sonos.
5. Activate the Sonos Spotify Connect endpoint through `/spotifyzc`.
6. Ask Sonos to play, then verify through Spotify Web API that the active device is the target room.

## Transfer Strategy

### Transfer path

- Sonos local network discovery, zeroconf, and SOAP control
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
