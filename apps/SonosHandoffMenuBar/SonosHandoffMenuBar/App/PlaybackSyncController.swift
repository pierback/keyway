import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class PlaybackSyncController: ObservableObject {
    private static let coordinatorMigrationTarget = Duration.seconds(2)

    @Published private(set) var outputRows: [PlaybackOutputRow] = []
    @Published private(set) var selectedRoomName: String?
    @Published private(set) var loadingRoomName: String?
    @Published private(set) var groupLoadingRoomName: String?
    @Published private(set) var volumeState = SpeakerVolumeControlState()
    @Published private(set) var isRefreshingOutputs = false
    @Published private(set) var menuMessage: String?
    @Published private(set) var spotifyAuthRequired = false
    @Published private(set) var spotifyAuthMessage = "Spotify sign-in expired. Sign in again to sync playback."
    @Published private(set) var groupSuggestions: [PlaybackGroupSuggestion] = []
    @Published private(set) var groupEditRows: [PlaybackGroupEditRow] = []

    private let outputDirectory: PlaybackOutputDirectory
    private let groupingInspectionResolver = SonosGroupingInspectionResolver()
    private let groupMembershipChangePlanner = SonosGroupMembershipChangePlanner()
    private let groupSuggestionTracker = SonosGroupSuggestionTracker()
    private let groupSuggestionAcceptanceResolver = SonosGroupSuggestionAcceptanceResolver()
    private let groupSuggestionAcceptRefreshResolver = SonosGroupSuggestionAcceptRefreshResolver()
    private let outputSelectionResolver = SonosOutputSelectionResolver()
    private let outputSelection: PlaybackOutputSelection
    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let volumeMonitor: SonosVolumeMonitor
    private let groupingEditor: any SonosGroupingEditing
    private let volumeActions: PlaybackVolumeActionController
    private let transferActions: PlaybackTransferActionController
    private let groupSuggestionStore: PlaybackGroupSuggestionStore
    private let groupSuggestionNotifier: PlaybackGroupSuggestionNotifier
    private let shortcutLogger = os.Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Shortcuts")
    private var monitorCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var groupSuggestionCancellable: AnyCancellable?
    private var outputRefreshCancellable: AnyCancellable?
    private var cachedOutputRefreshCancellable: AnyCancellable?
    private var outputRefreshInProgress = false
    private var hasPendingOutputRefresh = false
    private var pendingOutputRefreshRoomName: String?
    private let sliderCommitter = PlaybackSliderCommitter()
    private let operationGate = PlaybackOperationGate()
    private var activeSpotifyRoomName: String?
    private var currentGroupState = SonosGroupState.empty

    init(
        environment: AppEnvironment,
        outputDirectory: PlaybackOutputDirectory? = nil,
        volumeMonitor: SonosVolumeMonitor = .shared,
        volumeActions: PlaybackVolumeActionController? = nil,
        transferActions: PlaybackTransferActionController? = nil
    ) {
        self.outputDirectory = outputDirectory ?? environment.outputDirectory
        self.outputSelection = environment.outputSelection
        self.activePlaybackObserver = environment.activePlaybackObserver
        self.volumeMonitor = volumeMonitor
        self.groupingEditor = environment.groupingEditor
        self.groupSuggestionStore = environment.groupSuggestionStore
        self.groupSuggestionNotifier = environment.groupSuggestionNotifier
        self.volumeActions = volumeActions ?? PlaybackVolumeActionController(
            environment: environment,
            volumeMonitor: volumeMonitor
        )
        self.transferActions = transferActions ?? PlaybackTransferActionController(environment: environment)
        self.monitorCancellable = volumeMonitor.$snapshot.sink { [weak self] snapshot in
            guard let self else {
                return
            }
            self.applyMonitoredVolume(snapshot)
        }
        self.outputSelectionCancellable = outputSelection.$roomName.sink { [weak self] roomName in
            guard let self else {
                return
            }
            self.applyExternalOutputSelection(roomName)
        }
        self.groupSuggestionCancellable = groupSuggestionStore.$suggestions.sink { [weak self] suggestions in
            self?.groupSuggestions = suggestions
        }
        self.outputRefreshCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffRefreshOutputs)
            .sink { [weak self] notification in
                let currentRoomName = notification.object as? String
                Task { @MainActor [weak self] in
                    await self?.refreshOutputs(showLoading: false, currentRoomName: currentRoomName)
                }
            }
        self.cachedOutputRefreshCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffApplyCachedOutputs)
            .sink { [weak self] notification in
                let currentRoomName = notification.object as? String
                Task { @MainActor [weak self] in
                    _ = await self?.applyCachedOutputs(
                        currentRoomName: currentRoomName,
                        fallbackToPreferredRoom: false
                    )
                }
            }
    }

    var canControlVolume: Bool {
        selectedRoomName != nil && volumeState.hasStatus && !volumeState.isBusy && loadingRoomName == nil
    }

    var selectedOutputGroup: SonosSpeakerGroup? {
        currentGroupState.groups.first { $0.contains(roomName: selectedRoomName) }
    }

    func appear() {
        if selectedRoomName == nil {
            selectRoomName(outputSelection.roomName)
        }
        applyMonitoredVolume(volumeMonitor.snapshot)
        Task {
            let hasCachedOutputs = await applyCachedOutputs(
                currentRoomName: preferredCurrentRoomName(),
                fallbackToPreferredRoom: true
            )
            await outputDirectory.startBackgroundRefresh()
            await syncActiveSpotifyOutput()
            await refreshOutputs(showLoading: !hasCachedOutputs)
        }
    }

    func setSliderEditing(_ editing: Bool) {
        sliderCommitter.setEditing(editing)
    }

    func setVolumeFromSlider(locationX: CGFloat, width: CGFloat) {
        volumeState.setSliderValue(locationX: Double(locationX), width: Double(width))
    }

    func commitSliderVolumeImmediately() {
        sliderCommitter.cancel()
        commitSliderVolume()
    }

    func commitSliderVolumeDebounced() {
        guard volumeState.hasStatus, let roomName = selectedRoomName else {
            return
        }

        let desiredVolume = volumeState.roundedValue
        volumeActions.noteLocalChange(roomName: roomName, volume: desiredVolume, muted: false)
        sliderCommitter.schedule(
            roomName: roomName,
            desiredVolume: desiredVolume,
            roomStillSelected: { [weak self] roomName in
                guard let self else {
                    return false
                }
                return SonosRoomName.matches(self.selectedRoomName, roomName)
            },
            commit: { [weak self] roomName, desiredVolume in
                self?.commitSliderVolume(
                    roomName: roomName,
                    desiredVolume: desiredVolume,
                    markBusy: false,
                    applyResultWhileEditing: false,
                    source: "slider_drag"
                )
            }
        )
    }

    func refreshOutputs(showLoading: Bool = true, currentRoomName: String? = nil) async {
        let requestedRoomName = SonosRoomName.normalized(currentRoomName)
        guard !outputRefreshInProgress else {
            hasPendingOutputRefresh = true
            pendingOutputRefreshRoomName = requestedRoomName
            return
        }

        outputRefreshInProgress = true
        if showLoading {
            isRefreshingOutputs = true
        }
        defer {
            outputRefreshInProgress = false
            isRefreshingOutputs = false
        }

        var refreshRoomName = requestedRoomName
        while true {
            clearMenuMessageIfAuthenticated()

            do {
                let refresh = try await outputDirectory.refresh(
                    currentRoomName: refreshRoomName ?? preferredCurrentRoomName()
                )
                applyOutputRefresh(refresh)
            } catch {
                outputRows = []
                currentGroupState = .empty
                selectRoomName(nil)
                operationGate.cancelVolume()
                volumeState.clearStatus()
                menuMessage = "Could not search for Sonos speakers."
                shortcutLogger.error("SonosHandoffDiscovery result=failure error=\(error.localizedDescription, privacy: .public)")
            }

            guard hasPendingOutputRefresh else {
                return
            }
            hasPendingOutputRefresh = false
            refreshRoomName = pendingOutputRefreshRoomName
            pendingOutputRefreshRoomName = nil
        }
    }

    private func applyCachedOutputs(currentRoomName: String?, fallbackToPreferredRoom: Bool) async -> Bool {
        let roomName = currentRoomName ?? (fallbackToPreferredRoom ? preferredCurrentRoomName() : nil)
        guard let refresh = await outputDirectory.cachedRefresh(
            currentRoomName: roomName
        ) else {
            return false
        }

        applyOutputRefresh(refresh)
        return true
    }

    private func syncActiveSpotifyOutput() async {
        do {
            guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                  let roomName = SonosRoomName.normalized(status.deviceName)
            else {
                activeSpotifyRoomName = nil
                selectRoomName(nil)
                clearSpotifyAuthRequired()
                return
            }

            guard status.isPlaying else {
                activeSpotifyRoomName = nil
                selectRoomName(nil)
                clearSpotifyAuthRequired()
                return
            }

            activeSpotifyRoomName = roomName
            clearSpotifyAuthRequired()
            if let selectedRoomName = selectedRoomName(forActiveSpotifyRoomName: roomName) {
                selectRoomName(selectedRoomName)
                refreshVolumeStatus(roomName: selectedRoomName)
            }
        } catch {
            if SpotifyAuthRecovery.isAuthRequired(error) {
                requireSpotifyAuth(error)
                return
            }

            activeSpotifyRoomName = nil
            selectRoomName(nil)
            shortcutLogger.info("SonosHandoffSpotifyActiveDevice result=unavailable error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyOutputRefresh(_ refresh: PlaybackOutputRefresh) {
        applyOutputRefresh(refresh, selectedRoomName: refresh.selectedRoomName)
    }

    private func applyOutputRefresh(_ refresh: PlaybackOutputRefresh, selectedRoomName resolvedSelectedRoomName: String?) {
        outputRows = refresh.rows
        currentGroupState = refresh.state
        selectRoomName(resolvedSelectedRoomName)
        groupEditRows = refresh.groupEditRows
        refreshPendingGroupSuggestions(from: refresh, selectedRoomName: resolvedSelectedRoomName)

        if let selectedRoomName = resolvedSelectedRoomName {
            clearSpotifyAuthRequired()
            refreshVolumeStatus(roomName: selectedRoomName)
        } else {
            operationGate.cancelVolume()
            volumeState.clearStatus()
            clearMenuMessageIfAuthenticated(refresh.menuMessage)
        }
    }

    private func refreshPendingGroupSuggestions(from refresh: PlaybackOutputRefresh, selectedRoomName: String?) {
        guard !groupSuggestionStore.suggestions.isEmpty else {
            return
        }

        let update = groupSuggestionTracker.refresh(
            in: refresh.state,
            selectedRoomName: selectedRoomName,
            currentSuggestions: groupSuggestionStore.suggestions.map(\.reference)
        )
        groupSuggestionStore.clear(ids: update.staleSuggestionIDs)
        groupSuggestionNotifier.cancelSuggestions(ids: update.staleSuggestionIDs)
        let refreshedSuggestions = groupSuggestionStore.refresh(update.refreshedSuggestions)
        for suggestion in refreshedSuggestions {
            groupSuggestionNotifier.deliverSuggestion(suggestion)
        }
    }

    private func preferredCurrentRoomName() -> String? {
        activeSpotifyRoomName
    }

    private func selectedRoomName(forActiveSpotifyRoomName roomName: String) -> String? {
        if let selectedRoomName = outputSelectionResolver.selectedRoomName(
            currentRoomName: roomName,
            groups: currentGroupState.groups
        ) {
            return selectedRoomName
        }

        return currentGroupState.speakers
            .first(where: { SonosRoomName.matches($0.roomName, roomName) })?
            .roomName
    }

    func adjustVolume(_ direction: VolumeDirection) {
        guard let roomName = selectedRoomName else {
            return
        }

        volumeState.setBusy()
        menuMessage = nil
        volumeActions.noteLocalChange(roomName: roomName)

        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let volume = try await volumeActions.adjustVolume(roomName: roomName, direction: direction)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                applyLocalVolume(roomName: roomName, volume: volume, muted: false)
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.clearStatus()
                menuMessage = "Could not change \(roomName) volume."
                refreshVolumeStatus(roomName: roomName)
            }
        }
    }

    func toggleMute() {
        guard let roomName = selectedRoomName else {
            return
        }

        volumeState.setBusy()
        menuMessage = nil
        volumeActions.noteLocalChange(roomName: roomName)

        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let muted = try await volumeActions.toggleMute(roomName: roomName)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.applyMute(muted)
                volumeActions.noteLocalChange(roomName: roomName, muted: muted)
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.clearStatus()
                menuMessage = "Could not toggle \(roomName) mute."
                refreshVolumeStatus(roomName: roomName)
            }
        }
    }

    func transfer(to row: PlaybackOutputRow) {
        guard groupLoadingRoomName == nil else {
            return
        }
        transfer(to: row.coordinator)
    }

    func toggleGroupMembership(_ row: PlaybackGroupEditRow) {
        guard row.canToggle else {
            return
        }
        guard let group = selectedOutputGroup else {
            return
        }

        groupLoadingRoomName = row.displayName
        menuMessage = nil

        Task { @MainActor in
            do {
                let outcome = try await applyGroupMembershipChange(row, group: group)
                groupLoadingRoomName = nil
                if let message = outcome.menuMessage {
                    menuMessage = message
                }
                if outcome.shouldRefreshOutputs {
                    clearSuggestionsCoveredByGroupEdit(row)
                    await refreshOutputs(showLoading: false)
                }
            } catch {
                groupLoadingRoomName = nil
                menuMessage = groupEditMessage(for: row.displayName, error: error)
                shortcutLogger.error("SonosHandoffGroupEdit result=failure target=\(row.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await refreshOutputs(showLoading: false)
            }
        }
    }

    private func clearSuggestionsCoveredByGroupEdit(_ row: PlaybackGroupEditRow) {
        let speakerIDs = row.joinSpeakers.isEmpty ? [row.speaker.id] : row.joinSpeakers.map(\.id)
        for speakerID in speakerIDs {
            groupSuggestionStore.clear(id: speakerID)
            groupSuggestionNotifier.cancelSuggestion(id: speakerID)
        }
    }

    func acceptGroupSuggestion(id: String) {
        guard let suggestion = groupSuggestions.first(where: { $0.matches(identifier: id) })
        else {
            return
        }

        groupLoadingRoomName = suggestion.speaker.roomName
        menuMessage = nil

        Task { @MainActor in
            do {
                guard let activeRoomName = await activePlaybackRoomNameForGroupSuggestionRefresh() else {
                    groupLoadingRoomName = nil
                    guard !spotifyAuthRequired else {
                        return
                    }

                    groupSuggestionStore.clear(id: suggestion.id)
                    groupSuggestionNotifier.cancelSuggestion(id: suggestion.id)
                    menuMessage = "Spotify is not playing on a Sonos group."
                    return
                }

                let refresh = try await outputDirectory.refresh(currentRoomName: activeRoomName)
                switch groupSuggestionAcceptanceResolver.decision(
                    for: suggestion,
                    selectedGroup: refresh.selectedGroup
                ) {
                case .accept(let coordinatorRoomName):
                    try await groupingEditor.join(
                        roomName: suggestion.speaker.roomName,
                        toCoordinatorRoomName: coordinatorRoomName
                    )
                    groupSuggestionStore.clear(id: suggestion.id)
                    groupSuggestionNotifier.cancelSuggestion(id: suggestion.id)
                    groupLoadingRoomName = nil
                    shortcutLogger.info("SonosHandoffGroupSuggestion result=accepted room=\(suggestion.speaker.roomName, privacy: .public) coordinator=\(coordinatorRoomName, privacy: .public)")
                    await refreshOutputsAfterGroupSuggestionAccept(fallbackRoomName: coordinatorRoomName)
                case .reject(let rejection):
                    groupSuggestionStore.clear(id: suggestion.id)
                    groupSuggestionNotifier.cancelSuggestion(id: suggestion.id)
                    groupLoadingRoomName = nil
                    menuMessage = groupSuggestionRejectionMessage(rejection)
                    applyOutputRefresh(refresh)
                    shortcutLogger.info("SonosHandoffGroupSuggestion result=rejected room=\(suggestion.speaker.roomName, privacy: .public) reason=\(String(describing: rejection), privacy: .public)")
                }
            } catch {
                groupLoadingRoomName = nil
                menuMessage = "Could not add \(suggestion.speaker.roomName) to group."
                shortcutLogger.error("SonosHandoffGroupSuggestion result=failure room=\(suggestion.speaker.roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await refreshOutputs(showLoading: false)
            }
        }
    }

    func ignoreGroupSuggestion(id: String) {
        guard groupSuggestions.contains(where: { $0.matches(identifier: id) }) else {
            return
        }

        groupSuggestionStore.clear(id: id)
        groupSuggestionNotifier.cancelSuggestion(id: id)
        shortcutLogger.info("SonosHandoffGroupSuggestion result=ignored source=menu id=\(id, privacy: .public)")
    }

    private func groupSuggestionRejectionMessage(_ rejection: SonosGroupSuggestionAcceptanceRejection) -> String {
        switch rejection {
        case .noActiveSonosGroup:
            return "Spotify is not playing on a Sonos group."
        case .targetGroupChanged:
            return "Spotify playback moved before grouping."
        case .speakerAlreadyGrouped:
            return "Speaker is already in the active group."
        }
    }

    private func refreshOutputsAfterGroupSuggestionAccept(fallbackRoomName: String) async {
        let activeRoomName = await activePlaybackRoomNameForGroupSuggestionRefresh()
        let preRefreshPlan = groupSuggestionAcceptRefreshResolver.plan(
            activeRoomName: activeRoomName,
            outputSelectedRoomName: nil,
            fallbackRoomName: fallbackRoomName
        )

        do {
            let refresh = try await outputDirectory.refresh(currentRoomName: preRefreshPlan.discoveryRoomName)
            let plan = groupSuggestionAcceptRefreshResolver.plan(
                activeRoomName: activeRoomName,
                outputSelectedRoomName: refresh.selectedRoomName,
                fallbackRoomName: fallbackRoomName
            )
            applyOutputRefresh(refresh, selectedRoomName: plan.selectedRoomName)
        } catch {
            outputRows = []
            currentGroupState = .empty
            selectRoomName(nil)
            operationGate.cancelVolume()
            volumeState.clearStatus()
            menuMessage = "Could not search for Sonos speakers."
            shortcutLogger.error("SonosHandoffDiscovery result=failure source=group_suggestion_accept error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func activePlaybackRoomNameForGroupSuggestionRefresh() async -> String? {
        do {
            guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                  status.isPlaying
            else {
                activeSpotifyRoomName = nil
                return nil
            }

            let roomName = SonosRoomName.normalized(status.deviceName)
            activeSpotifyRoomName = roomName
            clearSpotifyAuthRequired()
            return roomName
        } catch {
            if SpotifyAuthRecovery.isAuthRequired(error) {
                requireSpotifyAuth(error)
                return nil
            }

            activeSpotifyRoomName = nil
            shortcutLogger.info("SonosHandoffGroupSuggestion active_playback=unavailable error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func transfer(to speaker: SonosSpeaker) {
        let roomName = speaker.roomName
        loadingRoomName = roomName
        menuMessage = nil
        operationGate.cancelVolume()

        operationGate.runTransfer(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            let outcome = await transferActions.transfer(to: speaker)
            guard isCurrentTransferOperation(ticket) else {
                return
            }

            loadingRoomName = nil
            switch outcome.result {
            case .success:
                activeSpotifyRoomName = outcome.roomName
                selectRoomName(outcome.roomName)
                clearSpotifyAuthRequired()
                refreshVolumeStatus(roomName: outcome.roomName)
            case .failure(let code, _):
                if code == .authRequired {
                    requireSpotifyAuth(message: outcome.failureMessage)
                    return
                }

                menuMessage = outcome.failureMessage
                if let selectedRoomName {
                    refreshVolumeStatus(roomName: selectedRoomName)
                } else {
                    volumeState.clearStatus()
                }
            }
        }
    }

    private func applyGroupMembershipChange(
        _ row: PlaybackGroupEditRow,
        group: SonosSpeakerGroup
    ) async throws -> PlaybackGroupEditOutcome {
        switch groupMembershipChangePlanner.change(for: row, in: group) {
        case .none:
            return .unchanged
        case .join(let speakers, let coordinatorRoomName):
            try await joinSpeakers(speakers, toCoordinatorRoomName: coordinatorRoomName)
            let joinedRoomNames = speakers.map(\.roomName).joined(separator: ",")
            shortcutLogger.info("SonosHandoffGroupEdit result=joined rooms=\(joinedRoomNames, privacy: .public) coordinator=\(coordinatorRoomName, privacy: .public)")
            return .changed()
        case .remove(let roomName):
            try await groupingEditor.removeFromGroup(roomName: roomName)
            shortcutLogger.info("SonosHandoffGroupEdit result=removed room=\(roomName, privacy: .public)")
            return .changed()
        case .removeCoordinator(let group, let coordinatorRoomName, let replacement):
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
                break
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
                    requireSpotifyAuth(message: transferOutcome.failureMessage)
                    return .changed()
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

            activeSpotifyRoomName = replacement.roomName
            selectRoomName(replacement.roomName)
            clearSpotifyAuthRequired()
            shortcutLogger.info("SonosHandoffGroupEdit result=removed_coordinator_and_transferred oldCoordinator=\(coordinatorRoomName, privacy: .public) newCoordinator=\(replacement.roomName, privacy: .public) transferElapsed=\(String(describing: transferElapsed), privacy: .public)")
            if transferElapsed > Self.coordinatorMigrationTarget {
                return .changed(
                    message: "Moved coordinator to \(replacement.roomName), but migration took longer than 2 seconds."
                )
            }
            return .changed()
        }
    }

    private func joinSpeakers(
        _ speakers: [SonosSpeaker],
        toCoordinatorRoomName coordinatorRoomName: String
    ) async throws {
        try await groupingEditor.join(
            roomNames: speakers.map(\.roomName),
            toCoordinatorRoomName: coordinatorRoomName
        )
    }

    private func groupEditMessage(for roomName: String, error: Error) -> String {
        if let groupEditError = error as? PlaybackGroupEditError {
            return groupEditError.message
        }

        return "Could not update \(roomName) group."
    }

    private func refreshVolumeStatus(roomName: String? = nil) {
        guard let roomName = roomName ?? selectedRoomName else {
            return
        }

        volumeState.setBusy()
        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let status = try await volumeActions.volumeStatus(roomName: roomName)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                applyVolumeStatus(status)
                shortcutLogger.info("SonosHandoffVolumeStatus room=\(status.roomName, privacy: .public) host=\(status.host, privacy: .public) volume=\(status.volume, privacy: .public) muted=\(status.muted, privacy: .public) outputFixed=\(status.outputFixed, privacy: .public)")
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.clearStatus()
                menuMessage = "Could not read \(roomName) volume."
                shortcutLogger.error("SonosHandoffVolumeStatus result=failure room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyMonitoredVolume(_ snapshot: SpeakerVolumeSnapshot?) {
        guard let snapshot, !volumeState.isBusy, !sliderCommitter.isEditing else {
            return
        }
        guard let selectedRoomName,
              SonosRoomName.matches(selectedRoomName, snapshot.roomName)
        else {
            return
        }

        volumeState.applySnapshot(snapshot)
    }

    private func commitSliderVolume() {
        guard volumeState.hasStatus, let roomName = selectedRoomName else {
            refreshVolumeStatus()
            return
        }

        let desiredVolume = volumeState.roundedValue
        commitSliderVolume(
            roomName: roomName,
            desiredVolume: desiredVolume,
            markBusy: true,
            applyResultWhileEditing: true,
            source: "slider"
        )
    }

    private func commitSliderVolume(
        roomName: String,
        desiredVolume: Int,
        markBusy: Bool,
        applyResultWhileEditing: Bool,
        source: String
    ) {
        volumeActions.noteLocalChange(roomName: roomName, volume: desiredVolume, muted: false)
        if markBusy {
            volumeState.setBusy()
        }
        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let volume = try await volumeActions.setVolume(roomName: roomName, volume: desiredVolume)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                if applyResultWhileEditing || !sliderCommitter.isEditing {
                    applyLocalVolume(roomName: roomName, volume: volume, muted: false)
                } else {
                    volumeActions.noteLocalChange(roomName: roomName, volume: volume, muted: false)
                }
                menuMessage = nil
                shortcutLogger.info("SonosHandoffVolumeSet result=success source=\(source, privacy: .public) room=\(roomName, privacy: .public) volume=\(volume, privacy: .public)")
            } catch {
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                menuMessage = "Could not set \(roomName) volume."
                shortcutLogger.error("SonosHandoffVolumeSet result=failure source=\(source, privacy: .public) room=\(roomName, privacy: .public) volume=\(desiredVolume, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                if !sliderCommitter.isEditing {
                    refreshVolumeStatus(roomName: roomName)
                }
            }
        }
    }

    private func applyLocalVolume(roomName: String, volume: Int, muted: Bool) {
        volumeState.applyLocalVolume(volume, muted: muted)
        volumeActions.noteLocalChange(roomName: roomName, volume: volume, muted: muted)
    }

    private func applyVolumeStatus(_ status: SpeakerVolumeStatus) {
        volumeState.applyStatus(status)
    }

    private func selectRoomName(_ roomName: String?) {
        if !SonosRoomName.matches(selectedRoomName, roomName) {
            sliderCommitter.cancel()
        }
        selectedRoomName = roomName
        outputSelection.setRoomName(roomName)
        volumeMonitor.setRoomName(roomName)
        refreshGroupEditRowsFromCurrentOutputs()
    }

    private func applyExternalOutputSelection(_ roomName: String?) {
        guard !SonosRoomName.matches(selectedRoomName, roomName) else {
            return
        }

        sliderCommitter.cancel()
        selectedRoomName = SonosRoomName.normalized(roomName)
        volumeMonitor.setRoomName(selectedRoomName)
        refreshGroupEditRowsFromCurrentOutputs()
        if let selectedRoomName {
            clearSpotifyAuthRequired()
            refreshVolumeStatus(roomName: selectedRoomName)
        } else {
            operationGate.cancelVolume()
            volumeState.clearStatus()
        }
    }

    private func requireSpotifyAuth(_ error: Error) {
        requireSpotifyAuth(message: SpotifyAuthRecovery.message(for: error))
    }

    private func requireSpotifyAuth(message: String?) {
        activeSpotifyRoomName = nil
        selectRoomName(nil)
        operationGate.cancelVolume()
        volumeState.clearStatus()
        spotifyAuthRequired = true
        spotifyAuthMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Spotify sign-in expired. Sign in again to sync playback."
        menuMessage = spotifyAuthMessage
        shortcutLogger.info("SonosHandoffSpotifyAuth state=required message=\(self.spotifyAuthMessage, privacy: .public)")
    }

    private func clearSpotifyAuthRequired() {
        let previousMessage = spotifyAuthMessage
        spotifyAuthRequired = false
        spotifyAuthMessage = "Spotify sign-in expired. Sign in again to sync playback."
        if menuMessage == previousMessage {
            menuMessage = nil
        }
    }

    private func clearMenuMessageIfAuthenticated(_ nextMessage: String? = nil) {
        guard !spotifyAuthRequired else {
            return
        }

        menuMessage = nextMessage
    }

    private func refreshGroupEditRowsFromCurrentOutputs() {
        let report = groupingInspectionResolver.report(
            in: currentGroupState,
            activeRoomName: selectedRoomName,
            spotifyPlaying: selectedRoomName != nil,
            previousSpeakerIDs: nil
        )
        groupEditRows = report.groupEditRows
    }

    private func isCurrentVolumeOperation(_ ticket: PlaybackOperationTicket) -> Bool {
        operationGate.isCurrentVolume(ticket, selectedRoomName: selectedRoomName)
    }

    private func isCurrentTransferOperation(_ ticket: PlaybackOperationTicket) -> Bool {
        operationGate.isCurrentTransfer(ticket, loadingRoomName: loadingRoomName)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum PlaybackGroupEditOutcome {
    case unchanged
    case changed(message: String? = nil)

    var shouldRefreshOutputs: Bool {
        switch self {
        case .unchanged:
            return false
        case .changed:
            return true
        }
    }

    var menuMessage: String? {
        switch self {
        case .unchanged:
            return nil
        case .changed(let message):
            return message
        }
    }
}

private struct PlaybackGroupEditError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
