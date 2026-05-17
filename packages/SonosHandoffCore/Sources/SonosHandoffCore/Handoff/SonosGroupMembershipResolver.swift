public enum SonosGroupMembership: Equatable, Sendable {
    case coordinator
    case member
    case available
}

public struct SonosGroupMembershipRow: Identifiable, Equatable, Sendable {
    public let speaker: SonosSpeaker
    public let membership: SonosGroupMembership
    public let coordinatorRemovalAvailable: Bool

    public init(
        speaker: SonosSpeaker,
        membership: SonosGroupMembership,
        coordinatorRemovalAvailable: Bool
    ) {
        self.speaker = speaker
        self.membership = membership
        self.coordinatorRemovalAvailable = coordinatorRemovalAvailable
    }

    public var id: String {
        speaker.id
    }

    public var isInGroup: Bool {
        membership == .coordinator || membership == .member
    }

    public var isCoordinator: Bool {
        membership == .coordinator
    }

    public var canToggle: Bool {
        !isCoordinator || coordinatorRemovalAvailable
    }
}

public struct SonosGroupMembershipResolver: Sendable {
    public init() {}

    public func rows(
        speakers: [SonosSpeaker],
        selectedGroup: SonosSpeakerGroup?
    ) -> [SonosGroupMembershipRow] {
        guard let selectedGroup else {
            return []
        }

        return speakers.map { speaker in
            let membership: SonosGroupMembership
            if speaker.id == selectedGroup.coordinatorID {
                membership = .coordinator
            } else if selectedGroup.members.contains(where: { $0.id == speaker.id }) {
                membership = .member
            } else {
                membership = .available
            }

            return SonosGroupMembershipRow(
                speaker: speaker,
                membership: membership,
                coordinatorRemovalAvailable: selectedGroup.members.count > 1
            )
        }
    }
}
