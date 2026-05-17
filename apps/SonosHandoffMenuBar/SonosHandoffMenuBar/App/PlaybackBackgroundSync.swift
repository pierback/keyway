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
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")
    private let groupSuggestionTracker = SonosGroupSuggestionTracker()
    private let groupSuggestionAcceptanceResolver = SonosGroupSuggestionAcceptanceResolver()
    private let groupSuggestionAcceptRefreshResolver = SonosGroupSuggestionAcceptRefreshResolver()
    private var task: Task<Void, Never>?
    private var lastDiscoveryRefresh = Date.distantPast
    private var lastSeenSpeakerIDs: Set<String>?
    private var hasShownAuthPrompt = false
    private var groupSuggestionActionCancellable: AnyCancellable?
    private var groupSuggestionIgnoreCancellable: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.groupSuggestionPresenter = environment.groupSuggestionPresenter
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
        let discoveryRefreshStarted = await refreshDiscoveryCacheIfNeeded()

        do {
            guard let status = try await environment.activePlaybackObserver.activePlaybackDeviceStatus(),
                  let activeRoomName = SonosRoomName.normalized(status.deviceName)
            else {
                hasShownAuthPrompt = false
                clearGroupSuggestions()
                clearSelection(reason: "no_active_spotify_playback")
                await refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: discoveryRefreshStarted)
                return
            }

            guard status.isPlaying else {
                hasShownAuthPrompt = false
                clearGroupSuggestions()
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
                clearSelection(reason: "active_device_not_visible")
                notifyOpenMenuAfterDiscoveryRefresh(
                    discoveryRefreshStarted: discoveryRefreshStarted,
                    currentRoomName: activeRoomName
                )
                logger.info("SonosHandoffPlaybackSync state=unmatched activeDevice=\(activeRoomName, privacy: .public)")
                return
            }

            selectRoomName(selectedRoomName)
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
                clearSelection(reason: "spotify_auth_required")
                showAuthPromptIfNeeded(error)
                return
            }

            clearGroupSuggestions()
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
        guard let previousSpeakerIDs = lastSeenSpeakerIDs else {
            lastSeenSpeakerIDs = Set(refresh.state.speakers.map(\.id))
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
        lastSeenSpeakerIDs = update.seenSpeakerIDs
        let suggestion = groupSuggestionPresenter.apply(update)
        if let suggestion {
            logger.info("SonosHandoffGroupSuggestion state=prompted room=\(suggestion.speaker.roomName, privacy: .public) group=\(suggestion.groupDisplayName, privacy: .public)")
        }
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

    private func refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: Bool) async {
        guard discoveryRefreshStarted else {
            return
        }

        do {
            let refresh = try await environment.outputDirectory.refreshAfterBackgroundRefresh(currentRoomName: nil)
            updateGroupSuggestion(refresh: refresh, selectedRoomName: nil, spotifyPlaying: false)
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
                selectRoomName(coordinatorRoomName)
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
                selectRoomName(selectedRoomName)
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

    private func selectRoomName(_ roomName: String) {
        guard !SonosRoomName.matches(environment.outputSelection.roomName, roomName) else {
            return
        }

        environment.outputSelection.setRoomName(roomName)
        SonosVolumeMonitor.shared.setRoomName(roomName)
    }

    private func clearSelection(reason: String) {
        guard environment.outputSelection.roomName != nil else {
            return
        }

        environment.outputSelection.setRoomName(nil)
        SonosVolumeMonitor.shared.setRoomName(nil)
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
