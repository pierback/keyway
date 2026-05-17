public enum SonosGroupMembershipChange: Equatable, Sendable {
    case none
    case join(speakers: [SonosSpeaker], coordinatorRoomName: String)
    case remove(roomName: String)
    case removeCoordinator(
        group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacement: SonosSpeaker
    )
}

public struct SonosGroupMembershipChangePlanner: Sendable {
    private let coordinatorReplacementResolver = SonosCoordinatorReplacementResolver()

    public init() {}

    public func change(
        for row: SonosGroupMembershipRow,
        in group: SonosSpeakerGroup
    ) -> SonosGroupMembershipChange {
        guard row.canToggle else {
            return .none
        }

        switch row.membership {
        case .available, .availableGroup:
            guard let coordinator = group.coordinator else {
                return .none
            }
            return .join(
                speakers: row.joinSpeakers,
                coordinatorRoomName: coordinator.roomName
            )
        case .member:
            return .remove(roomName: row.speaker.roomName)
        case .coordinator:
            guard let replacement = coordinatorReplacementResolver.replacement(
                in: group,
                removingCoordinatorID: row.speaker.id
            ) else {
                return .none
            }
            return .removeCoordinator(
                group: group,
                coordinatorRoomName: row.speaker.roomName,
                replacement: replacement
            )
        }
    }
}
