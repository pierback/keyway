import Foundation
import os
import SonosHandoffCore

@MainActor
final class PlaybackGroupEditController {
    var onChange: (() -> Void)?
    var groupLoadingRoomName: String? {
        didSet { notifyChange() }
    }
    private(set) var groupEditRows: [PlaybackGroupEditRow] = [] {
        didSet { notifyChange() }
    }

    private let groupingInspectionResolver = SonosGroupingInspectionResolver()
    let groupMembershipChangePlanner = SonosGroupMembershipChangePlanner()
    private let groupSuggestionTracker = SonosGroupSuggestionTracker()
    let groupingEditor: any SonosGroupingEditing
    private let groupSuggestionStore: PlaybackGroupSuggestionStore
    let groupSuggestionPresenter: PlaybackGroupSuggestionPresenter
    private let transferActions: PlaybackTransferActionController
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Shortcuts")

    init(
        groupingEditor: any SonosGroupingEditing,
        groupSuggestionStore: PlaybackGroupSuggestionStore,
        groupSuggestionPresenter: PlaybackGroupSuggestionPresenter,
        transferActions: PlaybackTransferActionController
    ) {
        self.groupingEditor = groupingEditor
        self.groupSuggestionStore = groupSuggestionStore
        self.groupSuggestionPresenter = groupSuggestionPresenter
        self.transferActions = transferActions
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
        selectedRoomName: String?,
        currentGroupState: SonosGroupState
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

    struct GroupMembershipToggleResult {
        let outcome: GroupEditOutcome
        let groupMutation: SonosGroupMembershipChange
        let previousGroup: SonosSpeakerGroup
    }

    enum GroupEditOutcome {
        case unchanged
        case changed(message: String? = nil)
        case transferCompleted(activeRoomName: String, selectedRoomName: String)
        case authRequired(message: String?)
        case error(String)
    }

    func toggleGroupMembership(
        _ row: PlaybackGroupEditRow,
        selectedOutputGroup: SonosSpeakerGroup?,
        onStateChange: @escaping (String?, String?) -> Void
    ) {
        guard row.canToggle, let group = selectedOutputGroup else { return }

        groupLoadingRoomName = row.displayName
        onStateChange(nil, nil)

        Task { @MainActor in
            do {
                let outcome = try await applyGroupMembershipChange(row, group: group, onStateChange: onStateChange)
                groupLoadingRoomName = nil
                if let message = outcome.message {
                    onStateChange(nil, message)
                }
                if outcome.shouldRefreshOutputs {
                    clearSuggestionsCoveredByGroupEdit(row)
                    let optimisticRoomName = optimisticSelectedRoomNameAfterGroupMutation(row, previousGroup: group)
                    onStateChange(optimisticRoomName, outcome.message)
                }
            } catch {
                groupLoadingRoomName = nil
                let message = groupEditMessage(for: row.displayName, error: error)
                onStateChange(nil, message)
                logger.error("SonosHandoffGroupEdit result=failure target=\(row.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func groupMutationObserved(
        _ row: PlaybackGroupEditRow,
        previousGroup: SonosSpeakerGroup,
        in state: SonosGroupState
    ) -> Bool {
        let change = groupMembershipChangePlanner.change(for: row, in: previousGroup)
        return groupMutationIsVisible(change, in: state)
    }

    func optimisticSelectedRoomNameAfterGroupMutation(
        _ row: PlaybackGroupEditRow,
        previousGroup: SonosSpeakerGroup
    ) -> String? {
        switch groupMembershipChangePlanner.change(for: row, in: previousGroup) {
        case .none:
            return nil
        case .join(_, let coordinatorRoomName):
            return coordinatorRoomName
        case .remove:
            return previousGroup.coordinator?.roomName
        case .removeCoordinator(_, _, let replacement):
            return replacement.roomName
        }
    }

    private func applyGroupMembershipChange(
        _ row: PlaybackGroupEditRow,
        group: SonosSpeakerGroup,
        onStateChange: @escaping (String?, String?) -> Void
    ) async throws -> GroupChangeOutcome {
        switch groupMembershipChangePlanner.change(for: row, in: group) {
        case .none:
            return .unchanged
        case .join(let speakers, let coordinatorRoomName):
            try await groupingEditor.join(
                roomNames: speakers.map(\.roomName),
                toCoordinatorRoomName: coordinatorRoomName
            )
            let joinedRoomNames = speakers.map(\.roomName).joined(separator: ",")
            logger.info("SonosHandoffGroupEdit result=joined rooms=\(joinedRoomNames, privacy: .public) coordinator=\(coordinatorRoomName, privacy: .public)")
            return .changed()
        case .remove(let roomName):
            try await groupingEditor.removeFromGroup(roomName: roomName)
            logger.info("SonosHandoffGroupEdit result=removed room=\(roomName, privacy: .public)")
            return .changed()
        case .removeCoordinator(let group, let coordinatorRoomName, let replacement):
            return try await removeCoordinator(
                group: group,
                coordinatorRoomName: coordinatorRoomName,
                replacement: replacement,
                onStateChange: onStateChange
            )
        }
    }

    private func removeCoordinator(
        group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacement: SonosSpeaker,
        onStateChange: @escaping (String?, String?) -> Void
    ) async throws -> GroupChangeOutcome {
        let startedAt = ContinuousClock.now
        try await groupingEditor.prepareCoordinatorRemoval(
            in: group,
            coordinatorRoomName: coordinatorRoomName,
            replacementRoomName: replacement.roomName
        )
        let transferOutcome = await transferActions.transfer(
            to: replacement,
            verification: .coordinatorMigration
        )
        let transferElapsed = startedAt.duration(to: .now)
        switch transferOutcome.result {
        case .success:
            onStateChange(replacement.roomName, nil)
        case .failure(let code, _):
            do {
                try await groupingEditor.join(
                    roomName: replacement.roomName,
                    toCoordinatorRoomName: coordinatorRoomName
                )
            } catch {
                throw PlaybackGroupEditError(
                    "Spotify playback did not transfer to \(replacement.roomName), and \(replacement.roomName) could not rejoin \(coordinatorRoomName)."
                )
            }

            if code == .authRequired {
                return .authRequired(message: transferOutcome.failureMessage)
            }

            throw PlaybackGroupEditError(
                "Spotify playback did not transfer to \(replacement.roomName)."
            )
        }

        do {
            try await groupingEditor.finishCoordinatorRemoval(
                in: group,
                coordinatorRoomName: coordinatorRoomName,
                replacementRoomName: replacement.roomName
            )
        } catch {
            throw PlaybackGroupEditError(
                "Moved playback to \(replacement.roomName), but could not finish grouping."
            )
        }

        logger.info("SonosHandoffGroupEdit result=removed_coordinator_and_transferred oldCoordinator=\(coordinatorRoomName, privacy: .public) newCoordinator=\(replacement.roomName, privacy: .public) transferElapsed=\(String(describing: transferElapsed), privacy: .public)")
        if transferElapsed > Duration.seconds(2) {
            return .changed(
                message: "Moved coordinator to \(replacement.roomName), but migration took longer than 2 seconds."
            )
        }
        return .changed()
    }

    func clearSuggestionsCoveredByGroupEdit(_ row: PlaybackGroupEditRow) {
        let speakerIDs = row.joinSpeakers.isEmpty ? [row.speaker.id] : row.joinSpeakers.map(\.id)
        for speakerID in speakerIDs {
            groupSuggestionPresenter.clear(id: speakerID)
        }
    }

    private func groupMutationIsVisible(
        _ change: SonosGroupMembershipChange,
        in state: SonosGroupState
    ) -> Bool {
        switch change {
        case .none:
            return true
        case .join(let speakers, let coordinatorRoomName):
            return SonosGroupMutationObservation.groupContains(
                in: state,
                coordinatorRoomName: coordinatorRoomName,
                memberRoomNames: speakers.map(\.roomName)
            )
        case .remove(let roomName):
            return SonosGroupMutationObservation.speakerIsStandalone(
                in: state,
                roomName: roomName
            )
        case .removeCoordinator(_, let coordinatorRoomName, let replacement):
            return SonosGroupMutationObservation.coordinatorWasRemoved(
                in: state,
                oldCoordinatorRoomName: coordinatorRoomName,
                replacement: replacement
            )
        }
    }

    private func groupEditMessage(for roomName: String, error: Error) -> String {
        if let groupEditError = error as? PlaybackGroupEditError {
            return groupEditError.message
        }
        return "Could not update \(roomName) group."
    }

    func groupSuggestionRejectionMessage(_ rejection: SonosGroupSuggestionAcceptanceRejection) -> String {
        switch rejection {
        case .noActiveSonosGroup:
            return "Spotify is not playing on a Sonos group."
        case .targetGroupChanged:
            return "Spotify playback moved before grouping."
        case .speakerAlreadyGrouped:
            return "Speaker is already in the active group."
        }
    }

    private func notifyChange() {
        onChange?()
    }
}

private enum GroupChangeOutcome {
    case unchanged
    case changed(message: String? = nil)
    case authRequired(message: String?)

    var shouldRefreshOutputs: Bool {
        switch self {
        case .unchanged: return false
        case .changed, .authRequired: return true
        }
    }

    var message: String? {
        switch self {
        case .unchanged: return nil
        case .changed(let message): return message
        case .authRequired(let message): return message
        }
    }
}
