import AppKit
import Combine
import os
import SonosHandoffCore
import SwiftUI

@main
struct SonosHandoffApp: App {
    private static let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")
    private static let volumeMonitorSeedRetryNanoseconds: UInt64 = 5_000_000_000
    private static let volumeMonitorSeedAttemptsMax = 3

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment: AppEnvironment
    private let playbackBackgroundSync: PlaybackBackgroundSync
    private let groupSuggestionNotifier: PlaybackGroupSuggestionNotifier

    init() {
        let environment = AppEnvironment.live()
        self.environment = environment
        self.groupSuggestionNotifier = environment.groupSuggestionNotifier
        environment.groupSuggestionNotifier.prepare()
        let playbackBackgroundSync = PlaybackBackgroundSync(
            environment: environment,
            groupSuggestionNotifier: environment.groupSuggestionNotifier
        )
        self.playbackBackgroundSync = playbackBackgroundSync
        appDelegate.configure(environment: environment)
        SonosVolumeMonitor.shared.start(
            volumeService: environment.volumeService
        )
        Task {
            await environment.outputDirectory.startBackgroundRefresh()
        }
        Task { @MainActor in
            await Self.seedVolumeMonitor(environment: environment)
        }
        Task { @MainActor in
            playbackBackgroundSync.start()
        }
    }

    @MainActor
    private static func seedVolumeMonitor(environment: AppEnvironment) async {
        let outputDirectory = environment.outputDirectory
        for attempt in 1 ... volumeMonitorSeedAttemptsMax {
            guard !Task.isCancelled else {
                return
            }

            do {
                let currentRoomName = await preferredStartupRoomName(environment: environment)
                let refresh = try await outputDirectory.refresh(currentRoomName: currentRoomName)
                if let selectedRoomName = refresh.selectedRoomName {
                    environment.outputSelection.setRoomName(selectedRoomName)
                    SonosVolumeMonitor.shared.setRoomName(selectedRoomName)
                    logger.info("SonosHandoffVolumeMonitor seed=selected room=\(selectedRoomName, privacy: .public)")
                    return
                }

                environment.outputSelection.setRoomName(nil)
                SonosVolumeMonitor.shared.setRoomName(nil)
                logger.info("SonosHandoffVolumeMonitor seed=no_output retry=true")
            } catch {
                logger.error("SonosHandoffVolumeMonitor seed=failure error=\(error.localizedDescription, privacy: .public)")
            }

            guard attempt < volumeMonitorSeedAttemptsMax else {
                break
            }

            do {
                try await Task.sleep(nanoseconds: volumeMonitorSeedRetryNanoseconds)
            } catch {
                return
            }
        }

        logger.info("SonosHandoffVolumeMonitor seed=stopped reason=no_visible_output")
    }

    @MainActor
    private static func preferredStartupRoomName(environment: AppEnvironment) async -> String? {
        do {
            if let status = try await environment.activePlaybackObserver.activePlaybackDeviceStatus(),
               status.isPlaying,
               let roomName = SonosRoomName.normalized(status.deviceName)
            {
                return roomName
            }
        } catch {
            logger.info("SonosHandoffVolumeMonitor active_playback=unavailable error=\(error.localizedDescription, privacy: .public)")
        }

        return nil
    }

    var body: some Scene {
        MenuBarExtra("Sonos", systemImage: "hifispeaker") {
            MenuBarController(environment: environment)
        }
        .menuBarExtraStyle(.window)

        Window(SettingsFeature.menuTitle, id: MenuBarController.settingsWindowID) {
            SettingsFeature(
                configStore: environment.configStore,
                tokenStore: environment.tokenStore,
                connectTokenStatusStore: environment.connectTokenStatusStore,
                authCoordinator: environment.authCoordinator,
                accessibilityAutomator: environment.accessibilityAutomator
            )
                .frame(width: 560, height: 420)
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class PlaybackBackgroundSync {
    private static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let discoveryRefreshInterval: TimeInterval = 20

    private let environment: AppEnvironment
    private let groupSuggestionNotifier: PlaybackGroupSuggestionNotifier
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")
    private let groupSuggestionTracker = SonosGroupSuggestionTracker()
    private var task: Task<Void, Never>?
    private var lastDiscoveryRefresh = Date.distantPast
    private var lastSeenSpeakerIDs: Set<String>?
    private var hasShownAuthPrompt = false
    private var groupSuggestionActionCancellable: AnyCancellable?

    init(
        environment: AppEnvironment,
        groupSuggestionNotifier: PlaybackGroupSuggestionNotifier
    ) {
        self.environment = environment
        self.groupSuggestionNotifier = groupSuggestionNotifier
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
                environment.groupSuggestionStore.clear()
                groupSuggestionNotifier.cancelAllSuggestions()
                clearSelection(reason: "no_active_spotify_playback")
                await refreshOutputCacheWithoutPlayback(discoveryRefreshStarted: discoveryRefreshStarted)
                return
            }

            guard status.isPlaying else {
                hasShownAuthPrompt = false
                environment.groupSuggestionStore.clear()
                groupSuggestionNotifier.cancelAllSuggestions()
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
                environment.groupSuggestionStore.clear()
                groupSuggestionNotifier.cancelAllSuggestions()
                clearSelection(reason: "spotify_auth_required")
                showAuthPromptIfNeeded(error)
                return
            }

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
        let state = SonosGroupState(groups: refresh.rows.map(\.group))
        let update = groupSuggestionTracker.update(
            in: state,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: lastSeenSpeakerIDs,
            currentSuggestions: environment.groupSuggestionStore.suggestions.map(\.reference)
        )
        lastSeenSpeakerIDs = update.seenSpeakerIDs
        environment.groupSuggestionStore.clear(ids: update.staleSuggestionIDs)
        groupSuggestionNotifier.cancelSuggestions(ids: update.staleSuggestionIDs)
        let refreshedSuggestions = environment.groupSuggestionStore.refresh(update.refreshedSuggestions)
        for suggestion in refreshedSuggestions {
            groupSuggestionNotifier.deliverSuggestion(suggestion)
        }

        switch update.action {
        case .none:
            return
        case .keepCurrent:
            return
        case .clearCurrent:
            environment.groupSuggestionStore.clear()
            groupSuggestionNotifier.cancelAllSuggestions()
            return
        case .present(let candidate):
            let suggestion = PlaybackGroupSuggestion(candidate: candidate, detectedAt: Date())
            environment.groupSuggestionStore.present(suggestion)
            groupSuggestionNotifier.deliverSuggestion(suggestion)
            logger.info("SonosHandoffGroupSuggestion state=prompted room=\(candidate.speaker.roomName, privacy: .public) group=\(candidate.groupDisplayName, privacy: .public)")
        }
    }

    private func notifyOpenMenuAfterDiscoveryRefresh(discoveryRefreshStarted: Bool, currentRoomName: String?) {
        guard discoveryRefreshStarted else {
            return
        }

        NotificationCenter.default.post(name: .sonosHandoffApplyCachedOutputs, object: currentRoomName)
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
            try await environment.groupingEditor.join(
                roomName: suggestion.speaker.roomName,
                toCoordinatorRoomName: suggestion.coordinatorRoomName
            )
            environment.groupSuggestionStore.clear(id: suggestion.id)
            groupSuggestionNotifier.cancelSuggestion(id: suggestion.id)
            let refresh = try await environment.outputDirectory.refresh(
                currentRoomName: suggestion.coordinatorRoomName
            )
            lastDiscoveryRefresh = Date()
            let refreshedRoomName = refresh.selectedRoomName ?? suggestion.coordinatorRoomName
            if let selectedRoomName = refresh.selectedRoomName {
                selectRoomName(selectedRoomName)
            }
            updateGroupSuggestion(
                refresh: refresh,
                selectedRoomName: refresh.selectedRoomName,
                spotifyPlaying: true
            )
            NotificationCenter.default.post(name: .sonosHandoffRefreshOutputs, object: refreshedRoomName)
            logger.info("SonosHandoffGroupSuggestion result=notification_accepted room=\(suggestion.speaker.roomName, privacy: .public) coordinator=\(suggestion.coordinatorRoomName, privacy: .public)")
        } catch {
            logger.error("SonosHandoffGroupSuggestion result=notification_failure room=\(suggestion.speaker.roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            groupSuggestionNotifier.deliverFailure(suggestion)
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
