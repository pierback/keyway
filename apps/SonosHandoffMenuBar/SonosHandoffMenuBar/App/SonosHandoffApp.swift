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

    init() {
        let environment = AppEnvironment.live()
        self.environment = environment
        let playbackBackgroundSync = PlaybackBackgroundSync(environment: environment)
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
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")
    private var task: Task<Void, Never>?
    private var lastDiscoveryRefresh = Date.distantPast
    private var hasShownAuthPrompt = false

    init(environment: AppEnvironment) {
        self.environment = environment
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
        await refreshDiscoveryCacheIfNeeded()

        do {
            guard let status = try await environment.activePlaybackObserver.activePlaybackDeviceStatus(),
                  let activeRoomName = SonosRoomName.normalized(status.deviceName)
            else {
                hasShownAuthPrompt = false
                clearSelection(reason: "no_active_spotify_playback")
                return
            }

            let refresh = try await outputRefresh(currentRoomName: activeRoomName)
            guard let selectedRoomName = refresh.selectedRoomName else {
                clearSelection(reason: "active_device_not_visible")
                logger.info("SonosHandoffPlaybackSync state=unmatched activeDevice=\(activeRoomName, privacy: .public)")
                return
            }

            selectRoomName(selectedRoomName)
            hasShownAuthPrompt = false
            logger.info("SonosHandoffPlaybackSync state=selected room=\(selectedRoomName, privacy: .public) spotifyVolume=\(status.volumePercent ?? -1, privacy: .public)")
        } catch {
            if SpotifyAuthRecovery.isAuthRequired(error) {
                clearSelection(reason: "spotify_auth_required")
                showAuthPromptIfNeeded(error)
                return
            }

            logger.info("SonosHandoffPlaybackSync state=unavailable error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func outputRefresh(currentRoomName: String) async throws -> PlaybackOutputRefresh {
        let shouldRefreshDiscovery = Date().timeIntervalSince(lastDiscoveryRefresh) >= Self.discoveryRefreshInterval
        if !shouldRefreshDiscovery,
           let cachedRefresh = await environment.outputDirectory.cachedRefresh(currentRoomName: currentRoomName) {
            return cachedRefresh
        }

        lastDiscoveryRefresh = Date()
        return try await environment.outputDirectory.refresh(currentRoomName: currentRoomName)
    }

    private func refreshDiscoveryCacheIfNeeded() async {
        guard Date().timeIntervalSince(lastDiscoveryRefresh) >= Self.discoveryRefreshInterval else {
            return
        }

        lastDiscoveryRefresh = Date()
        await environment.outputDirectory.startBackgroundRefresh()
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
