public struct SonosGroupSuggestionCandidate: Equatable, Sendable {
    public let speaker: SonosSpeaker
    public let coordinatorRoomName: String
    public let groupDisplayName: String

    public init(speaker: SonosSpeaker, coordinatorRoomName: String, groupDisplayName: String) {
        self.speaker = speaker
        self.coordinatorRoomName = coordinatorRoomName
        self.groupDisplayName = groupDisplayName
    }
}

public struct SonosGroupSuggestionResolver: Sendable {
    public init() {}

    public func suggestion(
        in state: SonosGroupState,
        selectedRoomName: String?,
        spotifyPlaying: Bool,
        previousSpeakerIDs: Set<String>?,
        excludingSpeakerIDs: Set<String> = []
    ) -> SonosGroupSuggestionCandidate? {
        guard spotifyPlaying,
              let selectedRoomName,
              let currentGroup = state.groups.first(where: { $0.contains(roomName: selectedRoomName) }),
              let coordinator = currentGroup.coordinator
        else {
            return nil
        }

        let currentGroupMemberIDs = Set(currentGroup.members.map(\.id))
        let eligibleSpeakerIDs = eligibleSpeakerIDs(
            in: state,
            previousSpeakerIDs: previousSpeakerIDs,
            currentGroupMemberIDs: currentGroupMemberIDs
        ).subtracting(excludingSpeakerIDs)
        guard !eligibleSpeakerIDs.isEmpty else {
            return nil
        }

        guard let speaker = standaloneSpeakers(in: state)
            .filter({ eligibleSpeakerIDs.contains($0.id) })
            .sorted(by: { left, right in
                left.roomName.localizedCaseInsensitiveCompare(right.roomName) == .orderedAscending
            })
            .first
        else {
            return nil
        }

        return SonosGroupSuggestionCandidate(
            speaker: speaker,
            coordinatorRoomName: coordinator.roomName,
            groupDisplayName: currentGroup.displayName
        )
    }

    public func suggestionStillValid(
        speakerID: String,
        coordinatorRoomName: String,
        in state: SonosGroupState,
        selectedRoomName: String?
    ) -> Bool {
        refreshedSuggestion(
            speakerID: speakerID,
            coordinatorRoomName: coordinatorRoomName,
            in: state,
            selectedRoomName: selectedRoomName
        ) != nil
    }

    public func refreshedSuggestion(
        speakerID: String,
        coordinatorRoomName: String,
        in state: SonosGroupState,
        selectedRoomName: String?
    ) -> SonosGroupSuggestionCandidate? {
        guard let selectedRoomName,
              let currentGroup = state.groups.first(where: { $0.contains(roomName: selectedRoomName) }),
              let coordinator = currentGroup.coordinator,
              currentGroup.contains(roomName: coordinatorRoomName),
              !currentGroup.members.contains(where: { $0.id == speakerID }),
              let speaker = standaloneSpeakers(in: state).first(where: { $0.id == speakerID })
        else {
            return nil
        }

        return SonosGroupSuggestionCandidate(
            speaker: speaker,
            coordinatorRoomName: coordinator.roomName,
            groupDisplayName: currentGroup.displayName
        )
    }

    public func seenSpeakerIDsAfterSuggestion(
        previousSpeakerIDs: Set<String>?,
        currentSpeakerIDs: Set<String>,
        suggestedSpeakerID: String?
    ) -> Set<String> {
        guard let suggestedSpeakerID else {
            return currentSpeakerIDs
        }

        var seenSpeakerIDs = previousSpeakerIDs ?? []
        seenSpeakerIDs.insert(suggestedSpeakerID)
        return seenSpeakerIDs.intersection(currentSpeakerIDs)
    }

    private func eligibleSpeakerIDs(
        in state: SonosGroupState,
        previousSpeakerIDs: Set<String>?,
        currentGroupMemberIDs: Set<String>
    ) -> Set<String> {
        let standaloneSpeakerIDs = Set(standaloneSpeakers(in: state).map(\.id))
            .subtracting(currentGroupMemberIDs)
        guard let previousSpeakerIDs else {
            return standaloneSpeakerIDs
        }

        return standaloneSpeakerIDs.intersection(Set(state.speakers.map(\.id)).subtracting(previousSpeakerIDs))
    }

    private func standaloneSpeakers(in state: SonosGroupState) -> [SonosSpeaker] {
        state.groups
            .filter { $0.members.count == 1 }
            .flatMap(\.members)
    }
}
