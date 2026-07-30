import AppKit
import ApplicationServices
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
            playbackBackgroundSync: environment.playbackBackgroundSync,
            volumeHotkeys: environment.volumeHotkeys
        )
        self.environment = environment
        self.runtime = runtime
        appDelegate.configure(
            runtime: runtime,
            playback: environment.playbackSyncController,
            mediaRemoteController: environment.mediaRemoteController,
            chromiumBrowserExtensionController: environment.chromiumBrowserExtensionController,
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
    private let chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let mediaRemoteController: MediaRemoteController
    private let mediaRoutingProbeController: MediaRoutingProbeController
    private let volumeService: any SpeakerVolumeAdjusting
    private let playbackBackgroundSync: PlaybackBackgroundSync
    private let volumeHotkeys: VolumeHotkeyController
    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "Playback")
    private(set) var isStarted = false
    private(set) var isMediaInputEnabled = false
    private(set) var isSonosEnabled = false

    init(
        chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        mediaRemoteController: MediaRemoteController,
        mediaRoutingProbeController: MediaRoutingProbeController,
        volumeService: any SpeakerVolumeAdjusting,
        playbackBackgroundSync: PlaybackBackgroundSync,
        volumeHotkeys: VolumeHotkeyController
    ) {
        self.chromiumNativeMessagingHostInstaller = chromiumNativeMessagingHostInstaller
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.mediaRemoteController = mediaRemoteController
        self.mediaRoutingProbeController = mediaRoutingProbeController
        self.volumeService = volumeService
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
        refreshMediaPermissions()
        logger.info("KeywayRuntime capability=base state=started")
    }

    func enableSonos() {
        guard isStarted, !isSonosEnabled else {
            return
        }
        isSonosEnabled = true

        volumeHotkeys.setSonosVolumeInputEnabled(true)
        SonosVolumeMonitor.shared.start(volumeService: volumeService)
        playbackBackgroundSync.start()
        logger.info("KeywayRuntime capability=sonos state=enabled")
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false

        disableSonos()
        if isMediaInputEnabled {
            isMediaInputEnabled = false
            volumeHotkeys.stop()
        }
        mediaRoutingProbeController.stop()
        mediaRemoteController.stop()
        chromiumBrowserExtensionController.stop()
        logger.info("KeywayRuntime capability=base state=stopped")
    }

    func refreshMediaPermissions() {
        guard isStarted else {
            return
        }

        guard AccessibilityPermission.isGranted(), CGPreflightListenEventAccess() else {
            if isMediaInputEnabled {
                isMediaInputEnabled = false
                volumeHotkeys.stop()
                logger.info("KeywayRuntime capability=media_input state=disabled")
            }
            return
        }

        if !isMediaInputEnabled {
            isMediaInputEnabled = true
            volumeHotkeys.start()
            logger.info("KeywayRuntime capability=media_input state=enabled")
        }
        volumeHotkeys.refreshMediaFallback()
    }

    private func disableSonos() {
        guard isSonosEnabled else {
            return
        }
        isSonosEnabled = false

        volumeHotkeys.setSonosVolumeInputEnabled(false)
        playbackBackgroundSync.stop()
        SonosVolumeMonitor.shared.stop()
        logger.info("KeywayRuntime capability=sonos state=disabled")
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
