import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class PlaybackBackgroundSync {
    private static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let discoveryRefreshInterval: TimeInterval = 20

    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let roomHandoffService: any RoomHandoffPerforming
    private let groupingEditor: any SonosGroupingEditing
    private let outputDirectory: PlaybackOutputDirectory
    private let outputSelection: PlaybackOutputSelection
    private let groupSuggestionStore: PlaybackGroupSuggestionStore
    private let groupSuggestionPresenter: PlaybackGroupSuggestionPresenter
    private let transferSuggestionStore: PlaybackTransferSuggestionStore
    private let transferSuggestionPresenter: PlaybackTransferSuggestionPresenter
    private let headphoneTransferSuggestionStore: HeadphoneTransferSuggestionStore
    private let headphoneTransferSuggestionPresenter: HeadphoneTransferSuggestionPresenter
    private let macAudioOutputMonitor: MacAudioOutputMonitor
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Playback")
    private let groupSuggestionTracker = SonosGroupSuggestionTracker()
    private let transferSuggestionTracker = SonosTransferSuggestionTracker()
    private let groupSuggestionAcceptanceResolver = SonosGroupSuggestionAcceptanceResolver()
    private let groupSuggestionAcceptRefreshResolver = SonosGroupSuggestionAcceptRefreshResolver()
    private var task: Task<Void, Never>?
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private var lastDiscoveryRefresh = Date.distantPast
    private var lastSeenGroupSuggestionSpeakerIDs: Set<String>?
    private var lastSeenTransferSuggestionSpeakerIDs: Set<String>?
    private var acceptingGroupSuggestionIDs: Set<String> = []
    private var acceptingTransferSuggestionIDs: Set<String> = []
    private var acceptingHeadphoneTransferSuggestionIDs: Set<String> = []
    private var hasShownAuthPrompt = false
    private var suggestionActionCancellables: [AnyCancellable] = []
    private var macAudioOutputCancellable: AnyCancellable?
    private var hasAudioOutputBaseline = false
    private var lastObservedAudioOutput: MacAudioOutputDevice?
    private var pendingHeadphoneConnectionOutputID: UInt32?

    init(
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        roomHandoffService: any RoomHandoffPerforming,
        groupingEditor: any SonosGroupingEditing,
        outputDirectory: PlaybackOutputDirectory,
        outputSelection: PlaybackOutputSelection,
        groupSuggestionStore: PlaybackGroupSuggestionStore,
        groupSuggestionPresenter: PlaybackGroupSuggestionPresenter,
        transferSuggestionStore: PlaybackTransferSuggestionStore,
        transferSuggestionPresenter: PlaybackTransferSuggestionPresenter,
        headphoneTransferSuggestionStore: HeadphoneTransferSuggestionStore,
        headphoneTransferSuggestionPresenter: HeadphoneTransferSuggestionPresenter,
        macAudioOutputMonitor: MacAudioOutputMonitor
    ) {
        self.activePlaybackObserver = activePlaybackObserver
        self.roomHandoffService = roomHandoffService
        self.groupingEditor = groupingEditor
        self.outputDirectory = outputDirectory
        self.outputSelection = outputSelection
        self.groupSuggestionStore = groupSuggestionStore
        self.groupSuggestionPresenter = groupSuggestionPresenter
        self.transferSuggestionStore = transferSuggestionStore
        self.transferSuggestionPresenter = transferSuggestionPresenter
        self.headphoneTransferSuggestionStore = headphoneTransferSuggestionStore
        self.headphoneTransferSuggestionPresenter = headphoneTransferSuggestionPresenter
        self.macAudioOutputMonitor = macAudioOutputMonitor
    }

    private func bindRuntimeEvents() {
        suggestionActionCancellables = [
            bindSuggestionAction(.sonosHandoffAcceptGroupSuggestion) { sync, suggestionID in
                await sync.acceptGroupSuggestion(id: suggestionID)
            },
            bindSuggestionAction(.sonosHandoffIgnoreGroupSuggestion) { sync, suggestionID in
                sync.ignoreGroupSuggestion(id: suggestionID)
            },
            bindSuggestionAction(.sonosHandoffAcceptTransferSuggestion) { sync, suggestionID in
                await sync.acceptTransferSuggestion(id: suggestionID)
            },
            bindSuggestionAction(.sonosHandoffIgnoreTransferSuggestion) { sync, suggestionID in
                sync.ignoreTransferSuggestion(id: suggestionID)
            },
            bindSuggestionAction(.sonosHandoffAcceptHeadphoneTransferSuggestion) { sync, suggestionID in
                await sync.acceptHeadphoneTransferSuggestion(id: suggestionID)
            },
            bindSuggestionAction(.sonosHandoffIgnoreHeadphoneTransferSuggestion) { sync, suggestionID in
                sync.ignoreHeadphoneTransferSuggestion(id: suggestionID)
            },
        ]
        macAudioOutputCancellable = macAudioOutputMonitor.$output
            .dropFirst()
            .sink { [weak self] output in
                self?.runEventTask { sync in
                    sync.recordMacAudioOutputChange(output)
                    await sync.syncOnce()
                }
            }
    }

    private func bindSuggestionAction(
        _ notificationName: Notification.Name,
        action: @escaping (PlaybackBackgroundSync, String) async -> Void
    ) -> AnyCancellable {
        NotificationCenter.default
            .publisher(for: notificationName)
            .sink { [weak self] notification in
                let suggestionID = notification.object as! String

                self?.runEventTask { sync in
                    await action(sync, suggestionID)
                }
            }
    }

    private func runEventTask(
        _ operation: @escaping @MainActor (PlaybackBackgroundSync) async -> Void
    ) {
        let id = UUID()
        eventTasks[id] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else {
                return
            }
            await operation(self)
            eventTasks[id] = nil
        }
    }

    func start() {
        guard task == nil else {
            return
        }

        bindRuntimeEvents()
        macAudioOutputMonitor.start()
        establishMacAudioOutputBaselineIfNeeded(macAudioOutputMonitor.output)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        for eventTask in eventTasks.values {
            eventTask.cancel()
        }
        eventTasks.removeAll()
        suggestionActionCancellables.removeAll()
        macAudioOutputCancellable?.cancel()
        macAudioOutputCancellable = nil
        macAudioOutputMonitor.stop()
        lastDiscoveryRefresh = .distantPast
        lastSeenGroupSuggestionSpeakerIDs = nil
        lastSeenTransferSuggestionSpeakerIDs = nil
        acceptingGroupSuggestionIDs.removeAll()
        acceptingTransferSuggestionIDs.removeAll()
        acceptingHeadphoneTransferSuggestionIDs.removeAll()
        hasShownAuthPrompt = false
        hasAudioOutputBaseline = false
        lastObservedAudioOutput = nil
        pendingHeadphoneConnectionOutputID = nil
    }

    private func syncOnce() async {
        guard !Task.isCancelled else {
            return
        }
        let cachedTransferBaselineSpeakerIDs = await cachedTransferSuggestionBaselineSpeakerIDs()
        guard !Task.isCancelled else {
            return
        }
        let discoveryRefreshStarted = await refreshDiscoveryCacheIfNeeded()
        guard !Task.isCancelled else {
            return
        }

        do {
            guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                  let activeRoomName = SonosRoomName.normalized(status.deviceName)
            else {
                guard !Task.isCancelled else {
                    return
                }
                hasShownAuthPrompt = false
                clearSuggestions(currentHeadphoneOutputID: nil)
                await refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: discoveryRefreshStarted)
                return
            }

            guard !Task.isCancelled else {
                return
            }
            guard status.isPlaying else {
                hasShownAuthPrompt = false
                clearSuggestions(currentHeadphoneOutputID: nil)
                await refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: discoveryRefreshStarted)
                return
            }

            let refresh = try await outputRefresh(
                currentRoomName: activeRoomName,
                forceRefresh: discoveryRefreshStarted
            )
            guard !Task.isCancelled else {
                return
            }
            guard let selectedRoomName = refresh.selectedRoomName else {
                updateGroupSuggestion(refresh: refresh, selectedRoomName: nil, spotifyPlaying: status.isPlaying)
                updateTransferSuggestion(
                    refresh: refresh,
                    activeDeviceName: status.deviceName,
                    selectedRoomName: nil,
                    spotifyPlaying: status.isPlaying,
                    cachedBaselineSpeakerIDs: cachedTransferBaselineSpeakerIDs
                )
                clearHeadphoneTransferSuggestion(currentHeadphoneOutputID: nil)
                notifyOpenMenuAfterDiscoveryRefresh(
                    discoveryRefreshStarted: discoveryRefreshStarted,
                    currentRoomName: activeRoomName
                )
                logger.info("SonosHandoffPlaybackSync state=unmatched activeDevice=\(activeRoomName, privacy: .public)")
                return
            }

            selectRoomName(
                selectedRoomName,
                selectedGroup: refresh.selectedGroup,
                source: .activePlaybackObservation
            )
            updateTransferSuggestion(
                refresh: refresh,
                activeDeviceName: status.deviceName,
                selectedRoomName: selectedRoomName,
                spotifyPlaying: status.isPlaying,
                cachedBaselineSpeakerIDs: cachedTransferBaselineSpeakerIDs
            )
            updateGroupSuggestion(refresh: refresh, selectedRoomName: selectedRoomName, spotifyPlaying: status.isPlaying)
            try await updateHeadphoneTransferSuggestion(activeRoomName: selectedRoomName)
            guard !Task.isCancelled else {
                return
            }
            notifyOpenMenuAfterDiscoveryRefresh(
                discoveryRefreshStarted: discoveryRefreshStarted,
                currentRoomName: selectedRoomName
            )
            hasShownAuthPrompt = false
            logger.info("SonosHandoffPlaybackSync state=selected room=\(selectedRoomName, privacy: .public) spotifyVolume=\(status.volumePercent ?? -1, privacy: .public)")
        } catch {
            guard !Task.isCancelled else {
                return
            }
            if SpotifyAuthRecovery.isAuthRequired(error) {
                clearSuggestions(currentHeadphoneOutputID: nil)
                showAuthPromptIfNeeded(error)
                return
            }

            clearSuggestions(currentHeadphoneOutputID: nil)
            logger.info("SonosHandoffPlaybackSync state=unavailable error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func establishMacAudioOutputBaselineIfNeeded(_ output: MacAudioOutputDevice?) {
        guard !hasAudioOutputBaseline else {
            return
        }

        hasAudioOutputBaseline = true
        lastObservedAudioOutput = output
        if let output {
            logger.info("SonosHandoffHeadphoneTransferSuggestion state=audio_output_baseline output=\(output.name, privacy: .public) headphones=\(output.isHeadphones, privacy: .public)")
        } else {
            logger.info("SonosHandoffHeadphoneTransferSuggestion state=audio_output_baseline output=none")
        }
    }

    private func recordMacAudioOutputChange(_ output: MacAudioOutputDevice?) {
        guard hasAudioOutputBaseline else {
            establishMacAudioOutputBaselineIfNeeded(output)
            return
        }

        let previousOutput = lastObservedAudioOutput
        lastObservedAudioOutput = output

        guard let output else {
            pendingHeadphoneConnectionOutputID = nil
            headphoneTransferSuggestionPresenter.clearUnavailable(currentHeadphoneOutputID: nil)
            logger.info("SonosHandoffHeadphoneTransferSuggestion state=audio_output_unavailable")
            return
        }

        guard output.isHeadphones else {
            pendingHeadphoneConnectionOutputID = nil
            headphoneTransferSuggestionPresenter.clearUnavailable(currentHeadphoneOutputID: nil)
            logger.info("SonosHandoffHeadphoneTransferSuggestion state=audio_output_non_headphones output=\(output.name, privacy: .public)")
            return
        }

        headphoneTransferSuggestionPresenter.clearUnavailable(currentHeadphoneOutputID: output.id)
        guard previousOutput?.isHeadphones != true || previousOutput?.id != output.id else {
            return
        }

        pendingHeadphoneConnectionOutputID = output.id
        logger.info("SonosHandoffHeadphoneTransferSuggestion state=headphones_connected output=\(output.name, privacy: .public)")
    }

    private func outputRefresh(currentRoomName: String, forceRefresh: Bool) async throws -> PlaybackOutputRefresh {
        if forceRefresh {
            return try await outputDirectory.refreshAfterBackgroundRefresh(currentRoomName: currentRoomName)
        }

        let shouldRefreshDiscovery = Date().timeIntervalSince(lastDiscoveryRefresh) >= Self.discoveryRefreshInterval
        if !shouldRefreshDiscovery,
           let cachedRefresh = await outputDirectory.cachedRefresh(currentRoomName: currentRoomName) {
            return cachedRefresh
        }

        lastDiscoveryRefresh = Date()
        return try await outputDirectory.refresh(currentRoomName: currentRoomName)
    }

    private func updateGroupSuggestion(
        refresh: PlaybackOutputRefresh,
        selectedRoomName: String?,
        spotifyPlaying: Bool
    ) {
        guard let previousSpeakerIDs = lastSeenGroupSuggestionSpeakerIDs else {
            lastSeenGroupSuggestionSpeakerIDs = Set(refresh.state.speakers.map(\.id))
            let refresh = groupSuggestionTracker.refresh(
                in: refresh.state,
                selectedRoomName: selectedRoomName,
                currentSuggestions: groupSuggestionStore.suggestions.map(\.reference)
            )
            groupSuggestionPresenter.apply(refresh)
            return
        }

        let update = groupSuggestionTracker.update(
            in: refresh.state,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: previousSpeakerIDs,
            currentSuggestions: groupSuggestionStore.suggestions.map(\.reference)
        )
        lastSeenGroupSuggestionSpeakerIDs = update.seenSpeakerIDs
        let suggestion = groupSuggestionPresenter.apply(update)
        if let suggestion {
            logger.info("SonosHandoffGroupSuggestion state=prompted room=\(suggestion.speaker.roomName, privacy: .public) group=\(suggestion.groupDisplayName, privacy: .public)")
        }
    }

    private func updateTransferSuggestion(
        refresh: PlaybackOutputRefresh,
        activeDeviceName: String?,
        selectedRoomName: String?,
        spotifyPlaying: Bool,
        cachedBaselineSpeakerIDs: Set<String>? = nil
    ) {
        if selectedRoomName != nil {
            lastSeenTransferSuggestionSpeakerIDs = Set(refresh.state.speakers.map(\.id))
            clearTransferSuggestions()
            return
        }

        let update = transferSuggestionTracker.update(
            in: refresh.state,
            activeDeviceName: activeDeviceName,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: lastSeenTransferSuggestionSpeakerIDs ?? cachedBaselineSpeakerIDs,
            currentSuggestions: transferSuggestionStore.suggestions.map(\.reference)
        )
        lastSeenTransferSuggestionSpeakerIDs = update.seenSpeakerIDs
        let suggestion = transferSuggestionPresenter.apply(update)
        if let suggestion {
            logger.info("SonosHandoffTransferSuggestion state=prompted room=\(suggestion.speaker.roomName, privacy: .public) source=\(suggestion.sourceDeviceName, privacy: .public)")
        }
    }

    private func updateHeadphoneTransferSuggestion(activeRoomName: String) async throws {
        guard let output = macAudioOutputMonitor.output else {
            clearHeadphoneTransferSuggestion(currentHeadphoneOutputID: nil)
            return
        }

        guard output.isHeadphones else {
            clearHeadphoneTransferSuggestion(currentHeadphoneOutputID: nil)
            return
        }

        guard pendingHeadphoneConnectionOutputID == output.id else {
            clearHeadphoneTransferSuggestion(currentHeadphoneOutputID: output.id)
            return
        }
        pendingHeadphoneConnectionOutputID = nil

        guard let spotifyDeviceName = try await localSpotifyComputerPlaybackDeviceName() else {
            guard !Task.isCancelled else {
                return
            }
            headphoneTransferSuggestionPresenter.clearAll()
            logger.info("SonosHandoffHeadphoneTransferSuggestion state=unavailable reason=no_spotify_computer_device output=\(output.name, privacy: .public)")
            return
        }
        guard !Task.isCancelled else {
            return
        }

        let suggestion = HeadphoneTransferSuggestion(
            output: output,
            activeRoomName: activeRoomName
        )
        if headphoneTransferSuggestionPresenter.presentIfNeeded(suggestion) {
            logger.info("SonosHandoffHeadphoneTransferSuggestion state=prompted output=\(output.name, privacy: .public) spotifyDeviceName=\(spotifyDeviceName, privacy: .public) room=\(activeRoomName, privacy: .public)")
        }
    }

    private func localSpotifyComputerPlaybackDeviceName() async throws -> String? {
        let localNames = Self.localSpotifyComputerDeviceNames()
        guard !localNames.isEmpty else {
            return nil
        }

        let devices = try await activePlaybackObserver.availablePlaybackDevices()
        return devices.first { device in
            !device.isRestricted
                && device.type.caseInsensitiveCompare("Computer") == .orderedSame
                && localNames.contains { Self.normalizedSpotifyDeviceName($0) == Self.normalizedSpotifyDeviceName(device.name) }
        }?.name
    }

    private static func localSpotifyComputerDeviceNames() -> [String] {
        let host = Host.current()
        let hostName = ProcessInfo.processInfo.hostName
        let rawCandidates = [
            host.localizedName,
            host.name,
            hostName,
            hostName.split(separator: ".").first.map(String.init),
        ]
        var seenNames = Set<String>()
        return rawCandidates.compactMap { candidate in
            guard let name = SonosRoomName.normalized(candidate) else {

                return nil
            }
            guard seenNames.insert(normalizedSpotifyDeviceName(name)).inserted else {

                return nil
            }

            return name
        }
    }

    private static func normalizedSpotifyDeviceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }

    private func cachedTransferSuggestionBaselineSpeakerIDs() async -> Set<String>? {
        guard lastSeenTransferSuggestionSpeakerIDs == nil,
              let refresh = await outputDirectory.cachedRefresh(currentRoomName: nil)
        else {
            return nil
        }

        let speakerIDs = Set(refresh.state.speakers.map(\.id))
        return speakerIDs.isEmpty ? nil : speakerIDs
    }

    private func notifyOpenMenuAfterDiscoveryRefresh(discoveryRefreshStarted: Bool, currentRoomName: String?) {
        guard discoveryRefreshStarted else {
            return
        }

        NotificationCenter.default.post(name: .sonosHandoffApplyCachedOutputs, object: currentRoomName)
    }

    private func clearSuggestions(currentHeadphoneOutputID: UInt32?) {
        clearGroupSuggestions()
        clearTransferSuggestions()
        clearHeadphoneTransferSuggestion(currentHeadphoneOutputID: currentHeadphoneOutputID)
    }

    private func clearGroupSuggestions() {
        groupSuggestionPresenter.clearAll()
    }

    private func clearTransferSuggestions() {
        transferSuggestionPresenter.clearAll()
    }

    private func clearHeadphoneTransferSuggestion(currentHeadphoneOutputID: UInt32?) {
        if pendingHeadphoneConnectionOutputID != currentHeadphoneOutputID {
            pendingHeadphoneConnectionOutputID = nil
        }
        headphoneTransferSuggestionPresenter.clearUnavailable(
            currentHeadphoneOutputID: currentHeadphoneOutputID
        )
    }

    private func refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: Bool) async {
        guard discoveryRefreshStarted else {
            return
        }

        do {
            let refresh = try await outputDirectory.refreshAfterBackgroundRefresh(currentRoomName: nil)
            guard !Task.isCancelled else {
                return
            }
            updateGroupSuggestion(refresh: refresh, selectedRoomName: nil, spotifyPlaying: false)
            updateTransferSuggestion(
                refresh: refresh,
                activeDeviceName: nil,
                selectedRoomName: nil,
                spotifyPlaying: false
            )
            notifyOpenMenuAfterDiscoveryRefresh(discoveryRefreshStarted: true, currentRoomName: nil)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            logger.info("SonosHandoffPlaybackSync output_cache_refresh=failed reason=no_active_playback error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func acceptGroupSuggestion(id: String) async {
        guard !Task.isCancelled else {
            return
        }
        guard let suggestion = groupSuggestionStore.suggestions.first(where: { $0.matches(identifier: id) })
        else {
            return
        }

        guard acceptingGroupSuggestionIDs.insert(suggestion.id).inserted else {
            logger.info("SonosHandoffGroupSuggestion result=ignored_duplicate_accept id=\(id, privacy: .public)")
            return
        }
        defer {
            acceptingGroupSuggestionIDs.remove(suggestion.id)
        }

        do {
            let activeRoomName = await activePlaybackRoomNameForSuggestionRefresh()
            guard !Task.isCancelled else {
                return
            }
            guard let activeRoomName else {
                groupSuggestionPresenter.clear(id: suggestion.id)
                logger.info("SonosHandoffGroupSuggestion result=notification_rejected room=\(suggestion.speaker.roomName, privacy: .public) reason=no_active_sonos_group")
                return
            }

            let preRefreshPlan = groupSuggestionAcceptRefreshResolver.plan(
                activeRoomName: activeRoomName,
                outputSelectedRoomName: nil,
                fallbackRoomName: suggestion.coordinatorRoomName
            )
            let refresh = try await outputDirectory.refresh(
                currentRoomName: preRefreshPlan.discoveryRoomName
            )
            guard !Task.isCancelled else {
                return
            }
            let decision = groupSuggestionAcceptanceResolver.decision(
                for: suggestion,
                selectedGroup: refresh.selectedGroup
            )
            guard case .accept(let coordinatorRoomName) = decision else {
                groupSuggestionPresenter.clear(id: suggestion.id)
                updateGroupSuggestion(
                    refresh: refresh,
                    selectedRoomName: refresh.selectedRoomName,
                    spotifyPlaying: refresh.selectedRoomName != nil
                )
                NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: refresh.selectedRoomName)
                logger.info("SonosHandoffGroupSuggestion result=notification_rejected room=\(suggestion.speaker.roomName, privacy: .public) decision=\(String(describing: decision), privacy: .public)")
                return
            }

            do {
                try await groupingEditor.join(
                    roomName: suggestion.speaker.roomName,
                    toCoordinatorRoomName: coordinatorRoomName
                )
                guard !Task.isCancelled else {
                    return
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                logger.error("SonosHandoffGroupSuggestion result=notification_join_failure room=\(suggestion.speaker.roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                groupSuggestionPresenter.deliverFailure(suggestion)
                return
            }

            groupSuggestionPresenter.clear(id: suggestion.id)
            let postRefreshPlan = groupSuggestionAcceptRefreshResolver.plan(
                activeRoomName: activeRoomName,
                outputSelectedRoomName: nil,
                fallbackRoomName: coordinatorRoomName
            )
            let postRefresh: PlaybackOutputRefresh
            do {
                postRefresh = try await outputDirectory.refresh(
                    currentRoomName: postRefreshPlan.discoveryRoomName
                )
                guard !Task.isCancelled else {
                    return
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                lastDiscoveryRefresh = Date.distantPast
                selectRoomName(
                    coordinatorRoomName,
                    selectedGroup: nil,
                    source: .activePlaybackObservation
                )
                NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: coordinatorRoomName)
                logger.error("SonosHandoffGroupSuggestion result=notification_accepted_refresh_failure room=\(suggestion.speaker.roomName, privacy: .public) coordinator=\(coordinatorRoomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return
            }

            let plan = groupSuggestionAcceptRefreshResolver.plan(
                activeRoomName: activeRoomName,
                outputSelectedRoomName: postRefresh.selectedRoomName,
                fallbackRoomName: coordinatorRoomName
            )
            lastDiscoveryRefresh = Date()
            if let selectedRoomName = plan.selectedRoomName {
                selectRoomName(
                    selectedRoomName,
                    selectedGroup: postRefresh.selectedGroup,
                    source: .activePlaybackObservation
                )
            } else if let clearReason = plan.clearReason {
                clearSelection(reason: clearReason.rawValue)
            }
            updateGroupSuggestion(
                refresh: postRefresh,
                selectedRoomName: plan.selectedRoomName,
                spotifyPlaying: plan.spotifyPlaying
            )
            NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: plan.menuRefreshRoomName)
            logger.info("SonosHandoffGroupSuggestion result=notification_accepted room=\(suggestion.speaker.roomName, privacy: .public) coordinator=\(coordinatorRoomName, privacy: .public)")
        } catch {
            guard !Task.isCancelled else {
                return
            }
            logger.error("SonosHandoffGroupSuggestion result=notification_failure room=\(suggestion.speaker.roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            groupSuggestionPresenter.deliverFailure(suggestion)
        }
    }

    private func ignoreGroupSuggestion(id: String) {
        groupSuggestionPresenter.clear(id: id)
        logger.info("SonosHandoffGroupSuggestion result=ignored id=\(id, privacy: .public)")
    }

    private func acceptTransferSuggestion(id: String) async {
        guard !Task.isCancelled else {
            return
        }
        guard let suggestion = transferSuggestionStore.suggestions.first(where: { $0.matches(identifier: id) })
        else {
            return
        }

        guard acceptingTransferSuggestionIDs.insert(suggestion.id).inserted else {
            logger.info("SonosHandoffTransferSuggestion result=ignored_duplicate_accept id=\(id, privacy: .public)")
            return
        }
        defer {
            acceptingTransferSuggestionIDs.remove(suggestion.id)
        }

        transferSuggestionPresenter.clear(id: suggestion.id)
        let result = await roomHandoffService.transfer(
            toRoomName: suggestion.speaker.roomName,
            verification: .full
        )
        guard !Task.isCancelled else {
            return
        }
        switch result {
        case .success:
            await applyAcceptedTransferSuggestion(suggestion)
        case .failure(let code, let message):
            let failureMessage = transferFailureMessage(
                roomName: suggestion.speaker.roomName,
                message: message
            )
            transferSuggestionPresenter.deliverFailure(suggestion, message: failureMessage)
            if code == .authRequired {
                showAuthPromptIfNeeded(PlaybackTransferSuggestionError(message: failureMessage))
            }
            logger.error("SonosHandoffTransferSuggestion result=notification_failure room=\(suggestion.speaker.roomName, privacy: .public) code=\(code.rawValue, privacy: .public) message=\(failureMessage, privacy: .public)")
        }
    }

    private func applyAcceptedTransferSuggestion(_ suggestion: PlaybackTransferSuggestion) async {
        let roomName = suggestion.speaker.roomName

        do {
            let refresh = try await outputDirectory.refresh(currentRoomName: roomName)
            guard !Task.isCancelled else {
                return
            }
            lastDiscoveryRefresh = Date()
            let selectedRoomName = refresh.selectedRoomName ?? roomName
            selectRoomName(
                selectedRoomName,
                selectedGroup: refresh.selectedGroup,
                source: .playbackTransaction
            )
            updateTransferSuggestion(
                refresh: refresh,
                activeDeviceName: roomName,
                selectedRoomName: selectedRoomName,
                spotifyPlaying: true
            )
            updateGroupSuggestion(
                refresh: refresh,
                selectedRoomName: selectedRoomName,
                spotifyPlaying: true
            )
            NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: selectedRoomName)
            logger.info("SonosHandoffTransferSuggestion result=notification_accepted room=\(roomName, privacy: .public)")
        } catch {
            guard !Task.isCancelled else {
                return
            }
            lastDiscoveryRefresh = Date.distantPast
            selectRoomName(
                roomName,
                selectedGroup: nil,
                source: .playbackTransaction
            )
            NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: roomName)
            logger.error("SonosHandoffTransferSuggestion result=notification_accepted_refresh_failure room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func ignoreTransferSuggestion(id: String) {
        transferSuggestionPresenter.clear(id: id)
        logger.info("SonosHandoffTransferSuggestion result=ignored id=\(id, privacy: .public)")
    }

    private func acceptHeadphoneTransferSuggestion(id: String) async {
        guard !Task.isCancelled else {
            return
        }
        guard let suggestion = headphoneTransferSuggestionStore.suggestion,
              suggestion.matches(identifier: id)
        else {
            return
        }

        guard acceptingHeadphoneTransferSuggestionIDs.insert(suggestion.id).inserted else {
            logger.info("SonosHandoffHeadphoneTransferSuggestion result=ignored_duplicate_accept id=\(id, privacy: .public)")
            return
        }
        defer {
            acceptingHeadphoneTransferSuggestionIDs.remove(suggestion.id)
        }

        headphoneTransferSuggestionPresenter.suppress(id: suggestion.id)
        do {
            guard let deviceName = try await localSpotifyComputerPlaybackDeviceName() else {
                guard !Task.isCancelled else {
                    return
                }
                let message = headphoneTransferFailureMessage(suggestion: suggestion)
                headphoneTransferSuggestionPresenter.deliverFailure(suggestion, message: message)
                logger.error("SonosHandoffHeadphoneTransferSuggestion result=notification_failure output=\(suggestion.outputName, privacy: .public) reason=local_spotify_computer_unavailable")
                return
            }
            try await activePlaybackObserver.transferActivePlayback(
                deviceName: deviceName,
                deviceType: "Computer",
                play: true
            )
            guard !Task.isCancelled else {
                return
            }
            clearSelection(reason: "spotify_transferred_to_mac")
            NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: nil)
            logger.info("SonosHandoffHeadphoneTransferSuggestion result=notification_accepted output=\(suggestion.outputName, privacy: .public) spotifyDeviceName=\(deviceName, privacy: .public)")
        } catch {
            guard !Task.isCancelled else {
                return
            }
            let message = headphoneTransferFailureMessage(suggestion: suggestion)
            headphoneTransferSuggestionPresenter.deliverFailure(suggestion, message: message)
            if SpotifyAuthRecovery.isAuthRequired(error) {
                showAuthPromptIfNeeded(error)
            }
            logger.error("SonosHandoffHeadphoneTransferSuggestion result=notification_failure output=\(suggestion.outputName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func ignoreHeadphoneTransferSuggestion(id: String) {
        headphoneTransferSuggestionPresenter.suppress(id: id)
        logger.info("SonosHandoffHeadphoneTransferSuggestion result=ignored id=\(id, privacy: .public)")
    }

    private func transferFailureMessage(roomName: String, message: String) -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)

        return message.isEmpty ? "Could not move Spotify playback to \(roomName)." : message
    }

    private func headphoneTransferFailureMessage(suggestion: HeadphoneTransferSuggestion) -> String {
        "Could not move Spotify playback to this Mac."
    }

    private func activePlaybackRoomNameForSuggestionRefresh() async -> String? {
        do {
            guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                  status.isPlaying
            else {
                guard !Task.isCancelled else {
                    return nil
                }
                return nil
            }
            guard !Task.isCancelled else {
                return nil
            }

            return SonosRoomName.normalized(status.deviceName)
        } catch {
            guard !Task.isCancelled else {
                return nil
            }
            if SpotifyAuthRecovery.isAuthRequired(error) {
                clearSuggestions(currentHeadphoneOutputID: nil)
                showAuthPromptIfNeeded(error)
                return nil
            }

            logger.info("SonosHandoffGroupSuggestion active_playback=unavailable error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func refreshDiscoveryCacheIfNeeded() async -> Bool {
        guard Date().timeIntervalSince(lastDiscoveryRefresh) >= Self.discoveryRefreshInterval else {
            return false
        }

        lastDiscoveryRefresh = Date()
        await outputDirectory.startBackgroundRefresh()
        return true
    }

    private func selectRoomName(
        _ roomName: String,
        selectedGroup: SonosSpeakerGroup?,
        source: PlaybackOutputSelection.UpdateSource
    ) {
        outputSelection.update(
            roomName: roomName,
            group: selectedGroup,
            source: source
        )
    }

    private func clearSelection(reason: String) {
        guard outputSelection.roomName != nil else {
            return
        }

        outputSelection.update(roomName: nil, group: nil, source: .reset)
        logger.info("SonosHandoffPlaybackSync state=cleared reason=\(reason, privacy: .public)")
    }

    private func showAuthPromptIfNeeded(_ error: Error) {
        guard !hasShownAuthPrompt else {
            return
        }

        hasShownAuthPrompt = true
        let message = SpotifyAuthRecovery.message(for: error)
            ?? "Open Settings and sign in for Spotify Web API."
        StatusHUD.shared.finish(
            title: "Spotify Sign-In Needed",
            message: message,
            dismissAfter: 7.0
        )
        logger.info("SonosHandoffPlaybackSync state=auth_required message=\(message, privacy: .public)")
    }
}

private struct PlaybackTransferSuggestionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
