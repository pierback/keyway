import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class PlaybackSyncController: ObservableObject {
    private static let coordinatorMigrationTarget = Duration.seconds(2)
    private static let groupMutationObservationAttemptsMax = 8
    private static let groupMutationObservationRetryNanoseconds: UInt64 = 500_000_000

    @Published private(set) var outputRows: [PlaybackOutputRow] = []
    @Published private(set) var selectedRoomName: String?
    @Published private(set) var loadingRoomName: String?
    @Published private(set) var groupLoadingRoomName: String?
    @Published private(set) var volumeState = SpeakerVolumeControlState()
    @Published private(set) var isRefreshingOutputs = false
    @Published private(set) var menuMessage: String?
    @Published private(set) var spotifyAuthRequired = false
    @Published private(set) var spotifyAuthMessage = "Spotify sign-in expired. Sign in again to sync playback."
    private let outputDirectory: PlaybackOutputDirectory
    private let outputSelectionResolver = SonosOutputSelectionResolver()
    private let outputSelection: PlaybackOutputSelection
    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let volumeMonitor: SonosVolumeMonitor
    private let volumeActions: PlaybackVolumeActionController
    private let transferActions: PlaybackTransferActionController
    private let groupingEditor: any SonosGroupingEditing
    private let groupMembershipChangePlanner = SonosGroupMembershipChangePlanner()
    let memberVolumeController: PlaybackMemberVolumeController
    let groupEditController: PlaybackGroupEditController
    private let shortcutLogger = os.Logger(subsystem: "com.fpieringer.Keyway", category: "Shortcuts")
    private var monitorCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var outputRefreshCancellable: AnyCancellable?
    private var cachedOutputRefreshCancellable: AnyCancellable?
    private var appearTask: Task<Void, Never>?
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var groupMutationTask: Task<Void, Never>?
    private var appearGeneration = 0
    private var isAppeared = false
    private var outputRefreshInProgress = false
    private var hasPendingOutputRefresh = false
    private var pendingOutputRefreshRoomName: String?
    private let sliderCommitter = PlaybackSliderCommitter()
    private let operationGate = PlaybackOperationGate()
    private var activeSpotifyRoomName: String?
    private var currentGroupState = SonosGroupState.empty

    init(
        outputDirectory: PlaybackOutputDirectory,
        outputSelection: PlaybackOutputSelection,
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        volumeService: any SpeakerVolumeAdjusting,
        roomHandoffService: any RoomHandoffPerforming,
        groupingEditor: any SonosGroupingEditing,
        groupSuggestionStore: PlaybackGroupSuggestionStore,
        groupSuggestionPresenter: PlaybackGroupSuggestionPresenter,
        volumeMonitor: SonosVolumeMonitor = .shared,
        volumeActions: PlaybackVolumeActionController? = nil,
        transferActions: PlaybackTransferActionController? = nil
    ) {
        let resolvedVolumeActions = volumeActions ?? PlaybackVolumeActionController(
            volumeService: volumeService,
            volumeMonitor: volumeMonitor
        )
        let resolvedTransferActions = transferActions ?? PlaybackTransferActionController(
            roomHandoffService: roomHandoffService
        )

        self.outputDirectory = outputDirectory
        self.outputSelection = outputSelection
        self.activePlaybackObserver = activePlaybackObserver
        self.volumeMonitor = volumeMonitor
        self.volumeActions = resolvedVolumeActions
        self.transferActions = resolvedTransferActions
        self.groupingEditor = groupingEditor
        self.memberVolumeController = PlaybackMemberVolumeController(
            volumeActions: resolvedVolumeActions
        )
        self.groupEditController = PlaybackGroupEditController(
            groupSuggestionStore: groupSuggestionStore,
            groupSuggestionPresenter: groupSuggestionPresenter
        )
        self.memberVolumeController.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        self.groupEditController.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
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
        self.outputRefreshCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffRefreshOutputs)
            .sink { [weak self] notification in
                let currentRoomName = notification.object as? String
                self?.runAppearanceTask { controller in
                    await controller.refreshOutputs(showLoading: false, currentRoomName: currentRoomName)
                }
            }
        self.cachedOutputRefreshCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffApplyCachedOutputs)
            .sink { [weak self] notification in
                let currentRoomName = notification.object as? String
                self?.runAppearanceTask { controller in
                    _ = await controller.applyCachedOutputs(
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

    func hasActiveSpotifyConnection(to row: PlaybackOutputRow) -> Bool {
        guard let activeSpotifyRoomName else {
            return false
        }
        return row.contains(roomName: activeSpotifyRoomName)
    }

    func commitMemberVolume(rowID: String) {
        memberVolumeController.commitMemberVolume(rowID: rowID) { [weak self] message in
            self?.menuMessage = message
        }
    }

    func appear() {
        appearGeneration += 1
        isAppeared = true
        let generation = appearGeneration
        appearTask?.cancel()
        if selectedRoomName == nil {
            applyExternalOutputSelection(outputSelection.roomName)
        }
        applyMonitoredVolume(volumeMonitor.snapshot)
        appearTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let cachedRefresh = await outputDirectory.cachedRefresh(
                currentRoomName: preferredCurrentRoomName(),
            )
            guard isCurrentAppearance(generation) else {
                return
            }
            let hasCachedOutputs = cachedRefresh != nil
            if let cachedRefresh {
                applyOutputRefresh(cachedRefresh)
            }
            await outputDirectory.startBackgroundRefresh()
            guard isCurrentAppearance(generation) else {
                return
            }
            await syncActiveSpotifyOutput(generation: generation)
            guard isCurrentAppearance(generation) else {
                return
            }
            await refreshOutputs(
                showLoading: !hasCachedOutputs,
                waitForBackgroundRefresh: hasCachedOutputs
            )
        }
    }

    func disappear() {
        isAppeared = false
        appearGeneration += 1
        appearTask?.cancel()
        appearTask = nil
        for notificationTask in notificationTasks.values {
            notificationTask.cancel()
        }
        notificationTasks.removeAll()
    }

    func stop() {
        disappear()
        groupMutationTask?.cancel()
        groupMutationTask = nil
        sliderCommitter.cancel()
        operationGate.cancelVolume()
        operationGate.cancelTransfer()
        monitorCancellable?.cancel()
        monitorCancellable = nil
        outputSelectionCancellable?.cancel()
        outputSelectionCancellable = nil
        outputRefreshCancellable?.cancel()
        outputRefreshCancellable = nil
        cachedOutputRefreshCancellable?.cancel()
        cachedOutputRefreshCancellable = nil
    }

    private func runAppearanceTask(
        _ operation: @escaping @MainActor (PlaybackSyncController) async -> Void
    ) {
        guard isAppeared else {
            return
        }
        let id = UUID()
        let generation = appearGeneration
        notificationTasks[id] = Task { @MainActor [weak self] in
            guard let self, isCurrentAppearance(generation) else {
                return
            }
            await operation(self)
            notificationTasks[id] = nil
        }
    }

    func setSliderEditing(_ editing: Bool) {
        sliderCommitter.setEditing(editing)
    }

    func setVolumeFromSlider(locationX: CGFloat, width: CGFloat) {
        volumeState.setSliderValue(locationX: Double(locationX), width: Double(width))
        if let selectedRoomName, volumeState.hasStatus {
            StatusHUD.shared.showVolume(roomName: selectedRoomName, volume: volumeState.roundedValue, dismissAfter: 1.6)
        }
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
                guard let self else {
                    return
                }
                self.commitSliderVolume(
                    roomName: roomName,
                    scope: self.volumeScope(for: roomName),
                    desiredVolume: desiredVolume,
                    markBusy: false,
                    applyResultWhileEditing: false,
                    source: "slider_drag"
                )
            }
        )
    }

    func refreshOutputs(
        showLoading: Bool = true,
        currentRoomName: String? = nil,
        waitForBackgroundRefresh: Bool = false,
        preserveMenuMessage: Bool = false
    ) async {
        guard !Task.isCancelled else {
            return
        }
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
            guard !Task.isCancelled else {
                return
            }
            if !preserveMenuMessage {
                clearMenuMessageIfAuthenticated()
            }

            do {
                let currentRoomName = refreshRoomName ?? preferredCurrentRoomName()
                let refresh: PlaybackOutputRefresh
                if waitForBackgroundRefresh {
                    refresh = try await outputDirectory.refreshAfterBackgroundRefresh(currentRoomName: currentRoomName)
                } else {
                    refresh = try await outputDirectory.refresh(currentRoomName: currentRoomName)
                }
                guard !Task.isCancelled else {
                    return
                }
                applyOutputRefresh(refresh)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                setOutputRows([])
                currentGroupState = .empty
                selectRoomName(nil, source: .reset)
                clearGroupSuggestions()
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

    private func isCurrentAppearance(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == appearGeneration
    }

    private func applyCachedOutputs(currentRoomName: String?, fallbackToPreferredRoom: Bool) async -> Bool {
        let roomName = currentRoomName ?? (fallbackToPreferredRoom ? preferredCurrentRoomName() : nil)
        guard let refresh = await outputDirectory.cachedRefresh(
            currentRoomName: roomName
        ) else {
            return false
        }
        guard !Task.isCancelled else {
            return false
        }

        applyOutputRefresh(refresh)
        return true
    }

    private func syncActiveSpotifyOutput(generation: Int) async {
        do {
            let status = try await activePlaybackObserver.activePlaybackDeviceStatus()
            guard isCurrentAppearance(generation) else {
                return
            }
            guard let status,
                  let roomName = SonosRoomName.normalized(status.deviceName)
            else {
                activeSpotifyRoomName = nil
                clearSpotifyAuthRequired()
                return
            }

            guard status.isPlaying else {
                activeSpotifyRoomName = nil
                clearSpotifyAuthRequired()
                return
            }

            activeSpotifyRoomName = roomName
            clearSpotifyAuthRequired()
            if let observedRoomName = selectedRoomName(forActiveSpotifyRoomName: roomName) {
                selectRoomName(observedRoomName, source: .activePlaybackObservation)
                if let effectiveRoomName = selectedRoomName {
                    refreshVolumeStatus(roomName: effectiveRoomName)
                }
            }
        } catch {
            guard isCurrentAppearance(generation) else {
                return
            }
            if SpotifyAuthRecovery.isAuthRequired(error) {
                requireSpotifyAuth(error)
                return
            }

            activeSpotifyRoomName = nil
            shortcutLogger.info("SonosHandoffSpotifyActiveDevice result=unavailable error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyOutputRefresh(_ refresh: PlaybackOutputRefresh) {
        applyOutputRefresh(refresh, selectedRoomName: refresh.selectedRoomName)
    }

    private func applyOutputRefresh(_ refresh: PlaybackOutputRefresh, selectedRoomName resolvedSelectedRoomName: String?) {
        let resolvedSelectedRoomName = outputSelectionResolver.selectedRoomName(
            currentRoomName: selectedRoomName ?? outputSelection.roomName,
            directoryRoomName: resolvedSelectedRoomName,
            groups: refresh.state.groups
        )
        setOutputRows(refresh.rows)
        currentGroupState = refresh.state
        selectRoomName(resolvedSelectedRoomName, source: .directoryRefresh)
        let effectiveSelectedRoomName = selectedRoomName
        groupEditController.setGroupEditRows(refresh.groupEditRows)
        refreshPinnedMixerRows()
        groupEditController.refreshPendingGroupSuggestions(
            from: refresh,
            selectedRoomName: effectiveSelectedRoomName
        )

        if let selectedRoomName = effectiveSelectedRoomName {
            refreshVolumeStatus(roomName: selectedRoomName)
        } else {
            operationGate.cancelVolume()
            volumeState.clearStatus()
            clearMenuMessageIfAuthenticated(refresh.menuMessage)
        }
    }

    private func preferredCurrentRoomName() -> String? {
        activeSpotifyRoomName ?? selectedRoomName ?? outputSelection.roomName
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
        let scope = volumeScope(for: roomName)

        volumeState.setBusy()
        menuMessage = nil
        volumeActions.noteLocalChange(roomName: roomName)

        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let volume = try await volumeActions.adjustVolume(roomName: roomName, scope: scope, direction: direction)
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
        let scope = volumeScope(for: roomName)

        volumeState.setBusy()
        menuMessage = nil
        volumeActions.noteLocalChange(roomName: roomName)

        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let muted = try await volumeActions.toggleMute(roomName: roomName, scope: scope)
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

    func transferSpotifyPlayback(source: MediaRemoteTarget, to row: PlaybackOutputRow) {
        guard source.isSpotify, groupLoadingRoomName == nil else {
            return
        }
        transfer(to: row.coordinator)
    }

    func connectSpotify(to row: PlaybackOutputRow) {
        guard groupLoadingRoomName == nil else {
            return
        }
        transfer(to: row.coordinator, verification: .connectOnly)
    }

    func selectSpeaker(row: PlaybackOutputRow) {
        let roomName = row.coordinator.roomName
        selectRoomName(roomName, source: .userSelection)
        refreshVolumeStatus(roomName: roomName)
    }

    func toggleGroupMembership(_ row: PlaybackGroupEditRow) {
        guard row.canToggle, groupMutationTask == nil else {
            return
        }
        guard let group = selectedOutputGroup else {
            return
        }
        let change = groupMembershipChangePlanner.change(for: row, in: group)

        groupLoadingRoomName = row.displayName
        menuMessage = nil

        groupMutationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                groupMutationTask = nil
            }
            do {
                let outcome = try await applyGroupMembershipChange(change)
                guard !Task.isCancelled else {
                    return
                }
                groupLoadingRoomName = nil
                if let message = outcome.menuMessage {
                    menuMessage = message
                }
                if outcome.shouldRefreshOutputs {
                    groupEditController.clearSuggestionsCoveredByGroupEdit(row)
                    let optimisticRoomName = optimisticSelectedRoomName(after: change, previousGroup: group)
                    if let observedRefresh = await refreshAfterGroupMutation(change, row: row) {
                        guard !Task.isCancelled else {
                            return
                        }
                        applyOutputRefresh(
                            observedRefresh,
                            selectedRoomName: observedRefresh.selectedRoomName ?? optimisticRoomName
                        )
                    } else {
                        await refreshOutputs(
                            showLoading: false,
                            currentRoomName: optimisticRoomName,
                            preserveMenuMessage: outcome.menuMessage != nil
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                groupLoadingRoomName = nil
                menuMessage = groupEditMessage(for: row.displayName, error: error)
                shortcutLogger.error("SonosHandoffGroupEdit result=failure target=\(row.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await refreshOutputs(showLoading: false, preserveMenuMessage: true)
            }
        }
    }

    private func clearGroupSuggestions() {
        groupEditController.clearGroupSuggestions()
        objectWillChange.send()
    }

    private func transfer(to speaker: SonosSpeaker, verification: RoomHandoffVerificationMode = .full) {
        let roomName = speaker.roomName
        loadingRoomName = roomName
        menuMessage = nil
        operationGate.cancelVolume()

        operationGate.runTransfer(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            let outcome = await transferActions.transfer(to: speaker, verification: verification)
            guard operationGate.isCurrentTransfer(ticket, loadingRoomName: loadingRoomName) else {
                return
            }

            loadingRoomName = nil
            switch outcome.result {
            case .success:
                activeSpotifyRoomName = outcome.roomName
                selectRoomName(outcome.roomName, source: .playbackTransaction)
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
        _ change: SonosGroupMembershipChange
    ) async throws -> PlaybackGroupEditOutcome {
        switch change {
        case .none:
            return .unchanged
        case .join(let speakers, let coordinatorRoomName):
            try await groupingEditor.join(
                roomNames: speakers.map(\.roomName),
                toCoordinatorRoomName: coordinatorRoomName
            )
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
                activeSpotifyRoomName = replacement.roomName
                selectRoomName(replacement.roomName, source: .playbackTransaction)
                clearSpotifyAuthRequired()
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

            shortcutLogger.info("SonosHandoffGroupEdit result=removed_coordinator_and_transferred oldCoordinator=\(coordinatorRoomName, privacy: .public) newCoordinator=\(replacement.roomName, privacy: .public) transferElapsed=\(String(describing: transferElapsed), privacy: .public)")
            if transferElapsed > Self.coordinatorMigrationTarget {
                return .changed(
                    message: "Moved coordinator to \(replacement.roomName), but migration took longer than 2 seconds."
                )
            }
            return .changed()
        }
    }

    private func refreshAfterGroupMutation(
        _ change: SonosGroupMembershipChange,
        row: PlaybackGroupEditRow
    ) async -> PlaybackOutputRefresh? {
        let currentRoomName = preferredCurrentRoomName() ?? selectedRoomName
        let visibleSpeakers = currentGroupState.speakers

        for attempt in 1 ... Self.groupMutationObservationAttemptsMax {
            do {
                let refresh: PlaybackOutputRefresh
                if visibleSpeakers.isEmpty {
                    refresh = try await outputDirectory.refresh(currentRoomName: currentRoomName)
                } else {
                    refresh = try await outputDirectory.refresh(
                        currentRoomName: currentRoomName,
                        visibleSpeakers: visibleSpeakers
                    )
                }
                if groupMutationObserved(change, in: refresh.state) {
                    if attempt > 1 {
                        shortcutLogger.info("SonosHandoffGroupEdit observation=ready target=\(row.displayName, privacy: .public) attempts=\(attempt, privacy: .public)")
                    }
                    return refresh
                }
            } catch {
                shortcutLogger.info("SonosHandoffGroupEdit observation=refresh_failed target=\(row.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }

            guard attempt < Self.groupMutationObservationAttemptsMax else {
                break
            }
            try? await Task.sleep(nanoseconds: Self.groupMutationObservationRetryNanoseconds)
        }

        shortcutLogger.info("SonosHandoffGroupEdit observation=timeout target=\(row.displayName, privacy: .public)")
        return nil
    }

    private func optimisticSelectedRoomName(
        after change: SonosGroupMembershipChange,
        previousGroup: SonosSpeakerGroup
    ) -> String? {
        switch change {
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

    private func groupMutationObserved(
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

    private func refreshVolumeStatus(roomName: String? = nil) {
        guard let roomName = roomName ?? selectedRoomName else {
            return
        }
        let scope = volumeScope(for: roomName)

        volumeState.setBusy()
        operationGate.runVolume(roomName: roomName) { [weak self] ticket in
            guard let self else {
                return
            }

            do {
                let status = try await volumeActions.volumeStatus(roomName: roomName, scope: scope)
                guard isCurrentVolumeOperation(ticket) else {
                    return
                }
                volumeState.applyStatus(status)
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
        let scope = volumeScope(for: roomName)
        commitSliderVolume(
            roomName: roomName,
            scope: scope,
            desiredVolume: desiredVolume,
            markBusy: true,
            applyResultWhileEditing: true,
            source: "slider"
        )
    }

    private func commitSliderVolume(
        roomName: String,
        scope: PlaybackVolumeScope,
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
                let volume = try await volumeActions.setVolume(roomName: roomName, scope: scope, volume: desiredVolume)
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
        StatusHUD.shared.showVolume(roomName: roomName, volume: volume, dismissAfter: 1.6)
    }

    private func selectRoomName(_ roomName: String?, source: PlaybackOutputSelection.UpdateSource) {
        outputSelection.update(
            roomName: roomName,
            group: roomName.flatMap(groupContaining),
            source: source
        )
    }

    private func applyExternalOutputSelection(_ roomName: String?) {
        guard !SonosRoomName.matches(selectedRoomName, roomName) else {
            return
        }

        sliderCommitter.cancel()
        selectedRoomName = SonosRoomName.normalized(roomName)
        refreshGroupEditRowsFromCurrentOutputs()
        clearPinnedMixerIfSelectionChanged()
        if let selectedRoomName {
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
        spotifyAuthRequired = true
        spotifyAuthMessage = message
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
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
        groupEditController.refreshGroupEditRowsFromCurrentOutputs(
            currentGroupState: currentGroupState,
            selectedRoomName: selectedRoomName
        )
    }

    private func volumeScope(for roomName: String) -> PlaybackVolumeScope {
        guard let group = currentGroupState.groups.first(where: { $0.contains(roomName: roomName) }),
              group.members.count > 1
        else {
            return .member
        }

        return .group
    }

    private func clearPinnedMixerIfSelectionChanged() {
        memberVolumeController.clearPinnedMixerIfSelectionChanged(selectedOutputGroup: selectedOutputGroup)
    }

    private func refreshPinnedMixerRows() {
        memberVolumeController.refreshPinnedMixerRows(outputRows: outputRows, selectedRoomName: selectedRoomName)
    }

    private func groupContaining(roomName: String) -> SonosSpeakerGroup? {
        currentGroupState.groups.first { $0.contains(roomName: roomName) }
    }

    private func setOutputRows(_ rows: [PlaybackOutputRow]) {
        guard outputRows != rows else {
            return
        }

        outputRows = rows
    }

    private func isCurrentVolumeOperation(_ ticket: PlaybackOperationTicket) -> Bool {
        operationGate.isCurrentVolume(ticket, selectedRoomName: selectedRoomName)
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

struct PlaybackGroupEditError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct PlaybackMemberVolumeRow: Identifiable, Equatable {
    let groupID: String
    let speaker: SonosSpeaker
    var state: SpeakerVolumeControlState
    var confirmedState: SpeakerVolumeControlState? = nil

    var id: String {
        speaker.id
    }

    mutating func restoreConfirmedState() {
        if let confirmedState {
            state = confirmedState
        } else {
            state.clearStatus()
        }
    }
}
