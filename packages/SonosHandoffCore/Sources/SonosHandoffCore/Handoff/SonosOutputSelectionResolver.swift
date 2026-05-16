public struct SonosOutputSelectionResolver: Sendable {
    public init() {}

    public func selectedRoomName(
        currentRoomName: String?,
        speakers: [SonosSpeaker]
    ) -> String? {
        if let currentRoomName = SonosRoomName.normalized(currentRoomName),
           let visibleCurrent = speakers.first(where: { SonosRoomName.matches($0.roomName, currentRoomName) }) {
            return visibleCurrent.roomName
        }

        // A selected output is active Spotify-on-Sonos playback, not a configured fallback target.
        return nil
    }
}
