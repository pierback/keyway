import SonosHandoffCore

@MainActor
final class PlaybackGroupEditController {
    var onChange: (() -> Void)?
    private(set) var groupEditRows: [PlaybackGroupEditRow] = [] {
        didSet { notifyChange() }
    }

    private let groupingInspectionResolver = SonosGroupingInspectionResolver()
    private let groupSuggestionTracker = SonosGroupSuggestionTracker()
    private let groupSuggestionStore: PlaybackGroupSuggestionStore
    private let groupSuggestionPresenter: PlaybackGroupSuggestionPresenter

    init(
        groupSuggestionStore: PlaybackGroupSuggestionStore,
        groupSuggestionPresenter: PlaybackGroupSuggestionPresenter
    ) {
        self.groupSuggestionStore = groupSuggestionStore
        self.groupSuggestionPresenter = groupSuggestionPresenter
    }

    func setGroupEditRows(_ rows: [PlaybackGroupEditRow]) {
        guard groupEditRows != rows else { return }
        groupEditRows = rows
    }

    func refreshGroupEditRowsFromCurrentOutputs(
        currentGroupState: SonosGroupState,
        selectedRoomName: String?
    ) {
        let report = groupingInspectionResolver.report(
            in: currentGroupState,
            activeRoomName: selectedRoomName,
            spotifyPlaying: selectedRoomName != nil,
            previousSpeakerIDs: nil
        )
        setGroupEditRows(report.groupEditRows)
    }

    func refreshPendingGroupSuggestions(
        from refresh: PlaybackOutputRefresh,
        selectedRoomName: String?
    ) {
        guard !groupSuggestionStore.suggestions.isEmpty else { return }

        let update = groupSuggestionTracker.refresh(
            in: refresh.state,
            selectedRoomName: selectedRoomName,
            currentSuggestions: groupSuggestionStore.suggestions.map(\.reference)
        )
        groupSuggestionPresenter.apply(update)
    }

    func clearGroupSuggestions() {
        groupSuggestionPresenter.clearAll()
    }

    func clearSuggestionsCoveredByGroupEdit(_ row: PlaybackGroupEditRow) {
        let speakerIDs = row.joinSpeakers.isEmpty ? [row.speaker.id] : row.joinSpeakers.map(\.id)
        for speakerID in speakerIDs {
            groupSuggestionPresenter.clear(id: speakerID)
        }
    }

    private func notifyChange() {
        onChange?()
    }
}
