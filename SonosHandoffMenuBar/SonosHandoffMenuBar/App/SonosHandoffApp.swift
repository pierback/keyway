import AppKit
import os
import SonosHandoffCore
import SwiftUI

@main
struct KeywayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment: AppEnvironment
    private let runtime: AppRuntime

    init() {
        let environment = AppEnvironment.live()
        let runtime = AppRuntime(environment: environment)
        self.environment = environment
        self.runtime = runtime
        appDelegate.configure(
            environment: environment,
            runtime: runtime
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
                initialChromiumBridgeMessage: environment.chromiumNativeMessagingHostInstallMessage,
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

    private let environment: AppEnvironment
    private let playbackBackgroundSync: PlaybackBackgroundSync
    private let volumeHotkeys: VolumeHotkeyController
    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "Playback")
    private var outputDirectoryTask: Task<Void, Never>?
    private var volumeMonitorSeedTask: Task<Void, Never>?
    private(set) var isStarted = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.playbackBackgroundSync = PlaybackBackgroundSync(environment: environment)
        let volumeHotkeys = VolumeHotkeyController(
            volumeService: environment.volumeService,
            outputSelection: environment.outputSelection,
            activePlaybackObserver: environment.activePlaybackObserver,
            mediaSourceStore: environment.mediaSourceStore,
            mediaTransportActions: environment.mediaTransportActionController
        )
        self.volumeHotkeys = volumeHotkeys
        environment.mediaTransportActionController.relaxRouteShield = { [weak volumeHotkeys] reason in
            volumeHotkeys?.suspendCommandCenterRouteShield(reason: reason)
        }
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        environment.chromiumBrowserExtensionController.start()
        environment.mediaRemoteController.start()
        environment.mediaRoutingProbeController.start()
        SonosVolumeMonitor.shared.start(volumeService: environment.volumeService)
        outputDirectoryTask = Task {
            await environment.outputDirectory.startBackgroundRefresh()
        }
        volumeMonitorSeedTask = Task { @MainActor [weak self] in
            await self?.seedVolumeMonitor()
        }
        playbackBackgroundSync.start()
        volumeHotkeys.start()
        logger.info("KeywayRuntime state=started")
    }

    func refreshMediaPermissions() {
        guard isStarted else {
            return
        }
        volumeHotkeys.refreshMediaFallback()
    }

    private func seedVolumeMonitor() async {
        let outputDirectory = environment.outputDirectory
        for attempt in 1 ... Self.volumeMonitorSeedAttemptsMax {
            guard !Task.isCancelled else {
                return
            }

            do {
                let currentRoomName = await preferredStartupRoomName()
                let refresh = try await outputDirectory.refresh(currentRoomName: currentRoomName)
                if let selectedRoomName = refresh.selectedRoomName {
                    environment.outputSelection.setSelection(roomName: selectedRoomName, group: refresh.selectedGroup)
                    SonosVolumeMonitor.shared.setTarget(
                        roomName: selectedRoomName,
                        scope: volumeScope(for: refresh.selectedGroup)
                    )
                    logger.info("SonosHandoffVolumeMonitor seed=selected room=\(selectedRoomName, privacy: .public)")
                    return
                }

                environment.outputSelection.setSelection(roomName: nil, group: nil)
                SonosVolumeMonitor.shared.setTarget(roomName: nil, scope: .member)
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

    private func volumeScope(for group: SonosSpeakerGroup?) -> PlaybackVolumeScope {
        guard let group, group.members.count > 1 else {
            return .member
        }

        return .group
    }
}
