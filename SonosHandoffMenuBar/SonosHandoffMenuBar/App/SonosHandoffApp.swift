import AppKit
import os
import SonosHandoffCore
import SwiftUI
@preconcurrency import UserNotifications

@main
struct KeywayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment: AppEnvironment
    private let runtime: AppRuntime

    init() {
        let environment = AppEnvironment.live()
        let runtime = AppRuntime(
            chromiumNativeMessagingHostInstaller: environment.chromiumNativeMessagingHostInstaller,
            chromiumBrowserExtensionController: environment.chromiumBrowserExtensionController,
            mediaRemoteController: environment.mediaRemoteController,
            mediaRoutingProbeController: environment.mediaRoutingProbeController,
            volumeService: environment.volumeService,
            activePlaybackObserver: environment.activePlaybackObserver,
            outputSelection: environment.outputSelection,
            outputDirectory: environment.outputDirectory,
            playbackBackgroundSync: environment.playbackBackgroundSync,
            volumeHotkeys: environment.volumeHotkeys
        )
        self.environment = environment
        self.runtime = runtime
        appDelegate.configure(
            runtime: runtime,
            playback: environment.playbackSyncController,
            mediaRemoteController: environment.mediaRemoteController,
            mediaSourceStore: environment.mediaSourceStore,
            mediaAudioControlController: environment.mediaAudioControlController,
            mediaTransportActionController: environment.mediaTransportActionController
        )
    }

    var body: some Scene {
        Settings {
            SettingsFeature(
                configStore: environment.configStore,
                tokenStore: environment.tokenStore,
                connectTokenStatusStore: environment.connectTokenStatusStore,
                authCoordinator: environment.authCoordinator,
                configImportService: environment.configImportService,
                chromiumNativeMessagingHostInstaller: environment.chromiumNativeMessagingHostInstaller,
                mediaRemoteController: environment.mediaRemoteController,
                chromiumBrowserExtensionController: environment.chromiumBrowserExtensionController
            )
        }
    }
}

@MainActor
final class AppRuntime {
    private static let volumeMonitorSeedRetryNanoseconds: UInt64 = 5_000_000_000
    private static let volumeMonitorSeedAttemptsMax = 3

    private let chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let mediaRemoteController: MediaRemoteController
    private let mediaRoutingProbeController: MediaRoutingProbeController
    private let volumeService: any SpeakerVolumeAdjusting
    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let outputSelection: PlaybackOutputSelection
    private let outputDirectory: PlaybackOutputDirectory
    private let playbackBackgroundSync: PlaybackBackgroundSync
    private let volumeHotkeys: VolumeHotkeyController
    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "Playback")
    private var outputDirectoryTask: Task<Void, Never>?
    private var volumeMonitorSeedTask: Task<Void, Never>?
    private(set) var isStarted = false

    init(
        chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        mediaRemoteController: MediaRemoteController,
        mediaRoutingProbeController: MediaRoutingProbeController,
        volumeService: any SpeakerVolumeAdjusting,
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        outputSelection: PlaybackOutputSelection,
        outputDirectory: PlaybackOutputDirectory,
        playbackBackgroundSync: PlaybackBackgroundSync,
        volumeHotkeys: VolumeHotkeyController
    ) {
        self.chromiumNativeMessagingHostInstaller = chromiumNativeMessagingHostInstaller
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.mediaRemoteController = mediaRemoteController
        self.mediaRoutingProbeController = mediaRoutingProbeController
        self.volumeService = volumeService
        self.activePlaybackObserver = activePlaybackObserver
        self.outputSelection = outputSelection
        self.outputDirectory = outputDirectory
        self.playbackBackgroundSync = playbackBackgroundSync
        self.volumeHotkeys = volumeHotkeys
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        prepareNotifications()
        installChromiumNativeMessagingHost()
        chromiumBrowserExtensionController.start()
        mediaRemoteController.start()
        mediaRoutingProbeController.start()
        SonosVolumeMonitor.shared.start(volumeService: volumeService)
        outputDirectoryTask = Task {
            await outputDirectory.startBackgroundRefresh()
        }
        volumeMonitorSeedTask = Task { @MainActor [weak self] in
            await self?.seedVolumeMonitor()
        }
        playbackBackgroundSync.start()
        volumeHotkeys.start()
        logger.info("KeywayRuntime state=started")
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false

        volumeMonitorSeedTask?.cancel()
        volumeMonitorSeedTask = nil
        outputDirectoryTask?.cancel()
        outputDirectoryTask = nil
        volumeHotkeys.stop()
        playbackBackgroundSync.stop()
        SonosVolumeMonitor.shared.stop()
        mediaRoutingProbeController.stop()
        mediaRemoteController.stop()
        chromiumBrowserExtensionController.stop()
        logger.info("KeywayRuntime state=stopped")
    }

    func refreshMediaPermissions() {
        guard isStarted else {
            return
        }
        volumeHotkeys.refreshMediaFallback()
    }

    private func seedVolumeMonitor() async {
        for attempt in 1 ... Self.volumeMonitorSeedAttemptsMax {
            guard !Task.isCancelled else {
                return
            }

            do {
                let currentRoomName = await preferredStartupRoomName()
                let refresh = try await outputDirectory.refresh(currentRoomName: currentRoomName)
                if let selectedRoomName = refresh.selectedRoomName {
                    outputSelection.update(
                        roomName: selectedRoomName,
                        group: refresh.selectedGroup,
                        source: .activePlaybackObservation
                    )
                    logger.info("SonosHandoffVolumeMonitor seed=selected room=\(selectedRoomName, privacy: .public)")
                    return
                }

                outputSelection.update(
                    roomName: nil,
                    group: nil,
                    source: .activePlaybackObservation
                )
                logger.info("SonosHandoffVolumeMonitor seed=no_output retry=true")
            } catch {
                logger.error("SonosHandoffVolumeMonitor seed=failure error=\(error.localizedDescription, privacy: .public)")
            }

            guard attempt < Self.volumeMonitorSeedAttemptsMax else {
                break
            }

            do {
                try await Task.sleep(nanoseconds: Self.volumeMonitorSeedRetryNanoseconds)
            } catch {
                return
            }
        }

        logger.info("SonosHandoffVolumeMonitor seed=stopped reason=no_visible_output")
    }

    private func preferredStartupRoomName() async -> String? {
        do {
            if let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
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

    private func prepareNotifications() {
        PlaybackSuggestionNotificationRegistrar.prepare(
            notificationCenter: .current(),
            logger: logger
        )
    }

    private func installChromiumNativeMessagingHost() {
        do {
            let state = try chromiumNativeMessagingHostInstaller.install()
            logger.info("Chromium native bridge installed manifests=\(state.manifestPaths.count, privacy: .public)")
        } catch {
            logger.error("Chromium native bridge install failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
