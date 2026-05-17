public enum SonosGroupMembership: Equatable, Sendable {
    case coordinator
    case member
    case available
    case availableGroup
}

public struct SonosGroupMembershipRow: Identifiable, Equatable, Sendable {
    public let speaker: SonosSpeaker
    public let membership: SonosGroupMembership
    public let coordinatorRemovalAvailable: Bool
    public let sourceGroup: SonosSpeakerGroup?

    public init(
        speaker: SonosSpeaker,
        membership: SonosGroupMembership,
        coordinatorRemovalAvailable: Bool,
        sourceGroup: SonosSpeakerGroup? = nil
    ) {
        self.speaker = speaker
        self.membership = membership
        self.coordinatorRemovalAvailable = coordinatorRemovalAvailable
        self.sourceGroup = sourceGroup
    }

    public var id: String {
        sourceGroup?.id ?? speaker.id
    }

    public var displayName: String {
        sourceGroup?.displayName ?? speaker.roomName
    }

    public var joinSpeakers: [SonosSpeaker] {
        guard membership == .available || membership == .availableGroup else {
            return []
        }

        return sourceGroup?.members ?? [speaker]
    }

    public var isInGroup: Bool {
        membership == .coordinator || membership == .member
    }

    public var isCoordinator: Bool {
        membership == .coordinator
    }

    public var isGroup: Bool {
        sourceGroup?.members.count ?? 1 > 1
    }

    public var canToggle: Bool {
        !isCoordinator || coordinatorRemovalAvailable
    }
}

public struct SonosGroupMembershipResolver: Sendable {
    public init() {}

    public func rows(
        groups: [SonosSpeakerGroup],
        selectedGroup: SonosSpeakerGroup?
    ) -> [SonosGroupMembershipRow] {
        guard let selectedGroup else {
            return []
        }

        return orderedRows(groups: groups, selectedGroup: selectedGroup)
    }

    private func orderedRows(
        groups: [SonosSpeakerGroup],
        selectedGroup: SonosSpeakerGroup
    ) -> [SonosGroupMembershipRow] {
        var speakerByID: [String: SonosSpeaker] = [:]
        for speaker in groups.flatMap(\.members) where speakerByID[speaker.id] == nil {
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

        var rows = ordered.map { speaker in
            let membership: SonosGroupMembership
            if speaker.id == selectedGroup.coordinator?.id {
                membership = .coordinator
            } else {
                membership = .member
            }

            return SonosGroupMembershipRow(
                speaker: speaker,
                membership: membership,
                coordinatorRemovalAvailable: selectedGroup.members.count > 1
            )
        }

        let availableGroups = groups
            .filter { group in
                !group.members.isEmpty
                    && group.members.allSatisfy { !selectedMemberIDs.contains($0.id) }
            }
            .sorted(by: groupDisplayNameAscending)
        for group in availableGroups {
            guard let coordinator = group.coordinator,
                  group.members.allSatisfy({ !emittedIDs.contains($0.id) })
            else {
                continue
            }

            rows.append(SonosGroupMembershipRow(
                speaker: coordinator,
                membership: group.members.count > 1 ? .availableGroup : .available,
                coordinatorRemovalAvailable: true,
                sourceGroup: group.members.count > 1 ? group : nil
            ))
            for speaker in group.members {
                emittedIDs.insert(speaker.id)
            }
        }

        return rows
    }

    private func groupDisplayNameAscending(_ left: SonosSpeakerGroup, _ right: SonosSpeakerGroup) -> Bool {
        left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
    }

    private func roomNameAscending(_ left: SonosSpeaker, _ right: SonosSpeaker) -> Bool {
        left.roomName.localizedCaseInsensitiveCompare(right.roomName) == .orderedAscending
    }
}
