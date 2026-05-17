public struct SonosGroupingInspectionReport: Equatable, Sendable {
    public let outputRows: [SonosOutputRow]
    public let selectedRoomName: String?
    public let selectedGroup: SonosSpeakerGroup?
    public let groupEditRows: [SonosGroupMembershipRow]
    public let suggestionCandidate: SonosGroupSuggestionCandidate?

    public init(
        outputRows: [SonosOutputRow],
        selectedRoomName: String?,
        selectedGroup: SonosSpeakerGroup?,
        groupEditRows: [SonosGroupMembershipRow],
        suggestionCandidate: SonosGroupSuggestionCandidate?
    ) {
        self.outputRows = outputRows
        self.selectedRoomName = selectedRoomName
        self.selectedGroup = selectedGroup
        self.groupEditRows = groupEditRows
        self.suggestionCandidate = suggestionCandidate
    }
}

public struct SonosGroupingInspectionResolver: Sendable {
    private let outputGroupOrderingResolver = SonosOutputGroupOrderingResolver()
    private let outputSelectionResolver = SonosOutputSelectionResolver()
    private let groupMembershipResolver = SonosGroupMembershipResolver()
    private let groupSuggestionResolver = SonosGroupSuggestionResolver()

    public init() {}

    public func report(
        in state: SonosGroupState,
        activeRoomName: String?,
        spotifyPlaying: Bool,
        previousSpeakerIDs: Set<String>?
    ) -> SonosGroupingInspectionReport {
        let selectedRoomName = outputSelectionResolver.selectedRoomName(
            currentRoomName: activeRoomName,
            groups: state.groups
        )
        let orderedGroups = outputGroupOrderingResolver.orderedGroups(
            state.groups,
            currentRoomName: activeRoomName
        )
        let outputRows = orderedGroups.compactMap(SonosOutputRow.init(group:))
        let selectedGroup = selectedRoomName.flatMap { roomName in
            state.groups.first { $0.contains(roomName: roomName) }
        }
        let groupEditRows = groupMembershipResolver.rows(
            groups: state.groups,
            selectedGroup: selectedGroup
        )
        let suggestionCandidate = groupSuggestionResolver.suggestion(
            in: state,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: previousSpeakerIDs
        )

        return SonosGroupingInspectionReport(
            outputRows: outputRows,
            selectedRoomName: selectedRoomName,
            selectedGroup: selectedGroup,
            groupEditRows: groupEditRows,
            suggestionCandidate: suggestionCandidate
        )
    }
}
