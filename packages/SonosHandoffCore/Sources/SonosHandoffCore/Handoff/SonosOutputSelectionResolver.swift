public struct SonosOutputSelectionResolver: Sendable {
    public init() {}

    public func selectedRoomName(
        currentRoomName: String?,
        groups: [SonosSpeakerGroup]
    ) -> String? {
        guard let currentRoomName = SonosRoomName.normalized(currentRoomName) else {
            return nil
        }

        if let visibleCurrent = groups
            .flatMap(\.members)
            .first(where: { SonosRoomName.matches($0.roomName, currentRoomName) }) {
            return visibleCurrent.roomName
        }

        if let matchingGroup = groups.first(where: { group in
            guard group.members.count > 1, let coordinator = group.coordinator else {
                return false
            }
            return SonosRoomName.matches(group.displayName, currentRoomName)
                || SonosRoomName.matchesSpotifyDeviceName(currentRoomName, roomName: coordinator.roomName)
        }) {
            return matchingGroup.coordinator?.roomName
        }

        // A selected output is active Spotify-on-Sonos playback, not a configured fallback target.
        return nil
    }
}
