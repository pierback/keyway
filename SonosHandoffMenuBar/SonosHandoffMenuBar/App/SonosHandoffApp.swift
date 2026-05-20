import AppKit
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
        environment.groupSuggestionNotifier.prepare()
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

    private static func volumeScope(for group: SonosSpeakerGroup?) -> PlaybackVolumeScope {
        guard let group, group.members.count > 1 else {
            return .member
        }

        return .group
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
                .frame(width: SettingsFeature.preferredWindowSize.width)
                .frame(minHeight: SettingsFeature.preferredWindowSize.height)
        }
        .defaultSize(
            width: SettingsFeature.preferredWindowSize.width,
            height: SettingsFeature.preferredWindowSize.height
        )
        .windowResizability(.contentSize)
    }
}
