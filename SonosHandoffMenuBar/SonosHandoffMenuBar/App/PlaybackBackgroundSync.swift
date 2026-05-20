import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class PlaybackBackgroundSync {
    private static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let discoveryRefreshInterval: TimeInterval = 20

    private let environment: AppEnvironment
    private let groupSuggestionPresenter: PlaybackGroupSuggestionPresenter
    private let transferSuggestionPresenter: PlaybackTransferSuggestionPresenter
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")
    private let groupSuggestionTracker = SonosGroupSuggestionTracker()
    private let transferSuggestionTracker = SonosTransferSuggestionTracker()
    private let groupSuggestionAcceptanceResolver = SonosGroupSuggestionAcceptanceResolver()
    private let groupSuggestionAcceptRefreshResolver = SonosGroupSuggestionAcceptRefreshResolver()
    private var task: Task<Void, Never>?
    private var lastDiscoveryRefresh = Date.distantPast
    private var lastSeenGroupSuggestionSpeakerIDs: Set<String>?
    private var lastSeenTransferSuggestionSpeakerIDs: Set<String>?
    private var acceptingGroupSuggestionIDs: Set<String> = []
    private var acceptingTransferSuggestionIDs: Set<String> = []
    private var hasShownAuthPrompt = false
    private var groupSuggestionActionCancellable: AnyCancellable?
    private var groupSuggestionIgnoreCancellable: AnyCancellable?
    private var transferSuggestionActionCancellable: AnyCancellable?
    private var transferSuggestionIgnoreCancellable: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.groupSuggestionPresenter = environment.groupSuggestionPresenter
        self.transferSuggestionPresenter = environment.transferSuggestionPresenter
        self.groupSuggestionActionCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffAcceptGroupSuggestion)
            .sink { [weak self] notification in
                guard let suggestionID = notification.object as? String else {
                    return
                }

                Task { @MainActor [weak self] in
                    await self?.acceptGroupSuggestion(id: suggestionID)
                }
            }
        self.groupSuggestionIgnoreCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffIgnoreGroupSuggestion)
            .sink { [weak self] notification in
                guard let suggestionID = notification.object as? String else {
                    return
                }

                Task { @MainActor [weak self] in
                    self?.ignoreGroupSuggestion(id: suggestionID)
                }
            }
        self.transferSuggestionActionCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffAcceptTransferSuggestion)
            .sink { [weak self] notification in
                guard let suggestionID = notification.object as? String else {
                    return
                }

                Task { @MainActor [weak self] in
                    await self?.acceptTransferSuggestion(id: suggestionID)
                }
            }
        self.transferSuggestionIgnoreCancellable = NotificationCenter.default
            .publisher(for: .sonosHandoffIgnoreTransferSuggestion)
            .sink { [weak self] notification in
                guard let suggestionID = notification.object as? String else {
                    return
                }

                Task { @MainActor [weak self] in
                    self?.ignoreTransferSuggestion(id: suggestionID)
                }
            }
    }

    func start() {
        guard task == nil else {
            return
        }

        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    private func syncOnce() async {
        let cachedTransferBaselineSpeakerIDs = await cachedTransferSuggestionBaselineSpeakerIDs()
        let discoveryRefreshStarted = await refreshDiscoveryCacheIfNeeded()

        do {
            guard let status = try await environment.activePlaybackObserver.activePlaybackDeviceStatus(),
                  let activeRoomName = SonosRoomName.normalized(status.deviceName)
            else {
                hasShownAuthPrompt = false
                clearGroupSuggestions()
                clearTransferSuggestions()
                clearSelection(reason: "no_active_spotify_playback")
                await refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: discoveryRefreshStarted)
                return
            }

            guard status.isPlaying else {
                hasShownAuthPrompt = false
                clearGroupSuggestions()
                clearTransferSuggestions()
                clearSelection(reason: "spotify_playback_paused")
                await refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: discoveryRefreshStarted)
                return
            }

            let refresh = try await outputRefresh(
                currentRoomName: activeRoomName,
                forceRefresh: discoveryRefreshStarted
            )
            guard let selectedRoomName = refresh.selectedRoomName else {
                updateGroupSuggestion(refresh: refresh, selectedRoomName: nil, spotifyPlaying: status.isPlaying)
                updateTransferSuggestion(
                    refresh: refresh,
                    activeDeviceName: status.deviceName,
                    selectedRoomName: nil,
                    spotifyPlaying: status.isPlaying,
                    cachedBaselineSpeakerIDs: cachedTransferBaselineSpeakerIDs
                )
                clearSelection(reason: "active_device_not_visible")
                notifyOpenMenuAfterDiscoveryRefresh(
                    discoveryRefreshStarted: discoveryRefreshStarted,
                    currentRoomName: activeRoomName
                )
                logger.info("SonosHandoffPlaybackSync state=unmatched activeDevice=\(activeRoomName, privacy: .public)")
                return
            }

            selectRoomName(selectedRoomName, selectedGroup: refresh.selectedGroup)
            updateTransferSuggestion(
                refresh: refresh,
                activeDeviceName: status.deviceName,
                selectedRoomName: selectedRoomName,
                spotifyPlaying: status.isPlaying,
                cachedBaselineSpeakerIDs: cachedTransferBaselineSpeakerIDs
            )
            updateGroupSuggestion(refresh: refresh, selectedRoomName: selectedRoomName, spotifyPlaying: status.isPlaying)
            notifyOpenMenuAfterDiscoveryRefresh(
                discoveryRefreshStarted: discoveryRefreshStarted,
                currentRoomName: selectedRoomName
            )
            hasShownAuthPrompt = false
            logger.info("SonosHandoffPlaybackSync state=selected room=\(selectedRoomName, privacy: .public) spotifyVolume=\(status.volumePercent ?? -1, privacy: .public)")
        } catch {
            if SpotifyAuthRecovery.isAuthRequired(error) {
                clearGroupSuggestions()
                clearTransferSuggestions()
                clearSelection(reason: "spotify_auth_required")
                showAuthPromptIfNeeded(error)
                return
            }

            clearGroupSuggestions()
            clearTransferSuggestions()
            logger.info("SonosHandoffPlaybackSync state=unavailable error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func outputRefresh(currentRoomName: String, forceRefresh: Bool) async throws -> PlaybackOutputRefresh {
        if forceRefresh {
            return try await environment.outputDirectory.refreshAfterBackgroundRefresh(currentRoomName: currentRoomName)
        }

        let shouldRefreshDiscovery = Date().timeIntervalSince(lastDiscoveryRefresh) >= Self.discoveryRefreshInterval
        if !shouldRefreshDiscovery,
           let cachedRefresh = await environment.outputDirectory.cachedRefresh(currentRoomName: currentRoomName) {
            return cachedRefresh
        }

        lastDiscoveryRefresh = Date()
        return try await environment.outputDirectory.refresh(currentRoomName: currentRoomName)
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
                currentSuggestions: environment.groupSuggestionStore.suggestions.map(\.reference)
            )
            groupSuggestionPresenter.apply(refresh)
            return
        }

        let update = groupSuggestionTracker.update(
            in: refresh.state,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: previousSpeakerIDs,
            currentSuggestions: environment.groupSuggestionStore.suggestions.map(\.reference)
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
            currentSuggestions: environment.transferSuggestionStore.suggestions.map(\.reference)
        )
        lastSeenTransferSuggestionSpeakerIDs = update.seenSpeakerIDs
        let suggestion = transferSuggestionPresenter.apply(update)
        if let suggestion {
            logger.info("SonosHandoffTransferSuggestion state=prompted room=\(suggestion.speaker.roomName, privacy: .public) source=\(suggestion.sourceDeviceName, privacy: .public)")
        }
    }

    private func cachedTransferSuggestionBaselineSpeakerIDs() async -> Set<String>? {
        guard lastSeenTransferSuggestionSpeakerIDs == nil,
              let refresh = await environment.outputDirectory.cachedRefresh(currentRoomName: nil)
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

    private func clearGroupSuggestions() {
        groupSuggestionPresenter.clearAll()
    }

    private func clearTransferSuggestions() {
        transferSuggestionPresenter.clearAll()
    }

    private func refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: Bool) async {
        guard discoveryRefreshStarted else {
            return
        }

        do {
            let refresh = try await environment.outputDirectory.refreshAfterBackgroundRefresh(currentRoomName: nil)
            updateGroupSuggestion(refresh: refresh, selectedRoomName: nil, spotifyPlaying: false)
            updateTransferSuggestion(
                refresh: refresh,
                activeDeviceName: nil,
                selectedRoomName: nil,
                spotifyPlaying: false
            )
            notifyOpenMenuAfterDiscoveryRefresh(discoveryRefreshStarted: true, currentRoomName: nil)
        } catch {
            logger.info("SonosHandoffPlaybackSync output_cache_refresh=failed reason=no_active_playback error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func acceptGroupSuggestion(id: String) async {
        guard let suggestion = environment.groupSuggestionStore.suggestions.first(where: { $0.matches(identifier: id) })
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
            let refresh = try await environment.outputDirectory.refresh(
                currentRoomName: preRefreshPlan.discoveryRoomName
            )
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
                try await environment.groupingEditor.join(
                    roomName: suggestion.speaker.roomName,
                    toCoordinatorRoomName: coordinatorRoomName
                )
            } catch {
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
                postRefresh = try await environment.outputDirectory.refresh(
                    currentRoomName: postRefreshPlan.discoveryRoomName
                )
            } catch {
                lastDiscoveryRefresh = Date.distantPast
                selectRoomName(coordinatorRoomName, selectedGroup: nil)
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
                selectRoomName(selectedRoomName, selectedGroup: postRefresh.selectedGroup)
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
            logger.error("SonosHandoffGroupSuggestion result=notification_failure room=\(suggestion.speaker.roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            groupSuggestionPresenter.deliverFailure(suggestion)
        }
    }

    private func ignoreGroupSuggestion(id: String) {
        groupSuggestionPresenter.clear(id: id)
        logger.info("SonosHandoffGroupSuggestion result=ignored id=\(id, privacy: .public)")
    }

    private func acceptTransferSuggestion(id: String) async {
        guard let suggestion = environment.transferSuggestionStore.suggestions.first(where: { $0.matches(identifier: id) })
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
        let result = await environment.roomHandoffService.transfer(
            toRoomName: suggestion.speaker.roomName,
            verification: .full
        )
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
            let refresh = try await environment.outputDirectory.refresh(currentRoomName: roomName)
            lastDiscoveryRefresh = Date()
            let selectedRoomName = refresh.selectedRoomName ?? roomName
            selectRoomName(selectedRoomName, selectedGroup: refresh.selectedGroup)
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
            lastDiscoveryRefresh = Date.distantPast
            selectRoomName(roomName, selectedGroup: nil)
            NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: roomName)
            logger.error("SonosHandoffTransferSuggestion result=notification_accepted_refresh_failure room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func ignoreTransferSuggestion(id: String) {
        transferSuggestionPresenter.clear(id: id)
        logger.info("SonosHandoffTransferSuggestion result=ignored id=\(id, privacy: .public)")
    }

    private func transferFailureMessage(roomName: String, message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Could not move Spotify playback to \(roomName)."
    }

    private func activePlaybackRoomNameForSuggestionRefresh() async -> String? {
        do {
            guard let status = try await environment.activePlaybackObserver.activePlaybackDeviceStatus(),
                  status.isPlaying
            else {
                return nil
            }

            return SonosRoomName.normalized(status.deviceName)
        } catch {
            if SpotifyAuthRecovery.isAuthRequired(error) {
                clearGroupSuggestions()
                clearTransferSuggestions()
                clearSelection(reason: "spotify_auth_required")
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
        await environment.outputDirectory.startBackgroundRefresh()
        return true
    }

    private func selectRoomName(_ roomName: String, selectedGroup: SonosSpeakerGroup?) {
        environment.outputSelection.setSelection(roomName: roomName, group: selectedGroup)
        SonosVolumeMonitor.shared.setTarget(roomName: roomName, scope: volumeScope(for: selectedGroup))
    }

    private func clearSelection(reason: String) {
        guard environment.outputSelection.roomName != nil else {
            return
        }

        environment.outputSelection.setSelection(roomName: nil, group: nil)
        SonosVolumeMonitor.shared.setTarget(roomName: nil, scope: .member)
        logger.info("SonosHandoffPlaybackSync state=cleared reason=\(reason, privacy: .public)")
    }

    private func volumeScope(for group: SonosSpeakerGroup?) -> PlaybackVolumeScope {
        guard let group, group.members.count > 1 else {
            return .member
        }

        return .group
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
