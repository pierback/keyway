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

        return orderedSpeakers(speakers, selectedGroup: selectedGroup).map { speaker in
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

    private func orderedSpeakers(
        _ speakers: [SonosSpeaker],
        selectedGroup: SonosSpeakerGroup
    ) -> [SonosSpeaker] {
        var speakerByID: [String: SonosSpeaker] = [:]
        for speaker in speakers where speakerByID[speaker.id] == nil {
            speakerByID[speaker.id] = speaker
        }
        let selectedMemberIDs = Set(selectedGroup.members.map(\.id))
        var ordered: [SonosSpeaker] = []
        var emittedIDs: Set<String> = []

        if let coordinator = selectedGroup.coordinator,
           let speaker = speakerByID[coordinator.id] ?? selectedGroup.members.first(where: { $0.id == coordinator.id }) {
            ordered.append(speaker)
            emittedIDs.insert(speaker.id)
        }

        let selectedMembers = selectedGroup.members
            .filter { $0.id != selectedGroup.coordinatorID }
            .sorted(by: roomNameAscending)
        for member in selectedMembers where !emittedIDs.contains(member.id) {
            ordered.append(speakerByID[member.id] ?? member)
            emittedIDs.insert(member.id)
        }

        let availableSpeakers = speakers
            .filter { !selectedMemberIDs.contains($0.id) }
            .sorted(by: roomNameAscending)
        for speaker in availableSpeakers where !emittedIDs.contains(speaker.id) {
            ordered.append(speaker)
            emittedIDs.insert(speaker.id)
        }

        return ordered
    }

    private func roomNameAscending(_ left: SonosSpeaker, _ right: SonosSpeaker) -> Bool {
        left.roomName.localizedCaseInsensitiveCompare(right.roomName) == .orderedAscending
    }
}
