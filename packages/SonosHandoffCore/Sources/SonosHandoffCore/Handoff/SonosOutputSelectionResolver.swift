public struct SonosOutputSelectionResolver: Sendable {
    public init() {}

    public func selectedRoomName(
        currentRoomName: String?,
        groups: [SonosSpeakerGroup]
    ) -> String? {
        guard let currentRoomName = SonosRoomName.normalized(currentRoomName) else {
            return nil
        }

        if let matchingGroup = groups.first(where: { $0.contains(roomName: currentRoomName) }) {
            return matchingGroup.coordinator?.roomName
        }

        // A selected output is active Spotify-on-Sonos playback, not a configured fallback target.
        return nil
    }
}
