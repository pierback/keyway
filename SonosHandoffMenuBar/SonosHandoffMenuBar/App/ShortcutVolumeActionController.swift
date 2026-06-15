import Foundation
import os
import SonosHandoffCore

@MainActor
final class ShortcutVolumeActionController {
    private struct QueuedVolumeAdjustment: Sendable {
        let target: ShortcutVolumeTarget
        let direction: VolumeDirection
    }

    private enum ShortcutVolumeTarget: Sendable {
        case sonos(roomName: String, scope: PlaybackVolumeScope)
        case spotify

        var logTarget: String {
            switch self {
            case let .sonos(roomName, scope):
                "sonos:\(roomName):\(scope.logName)"
            case .spotify:
                "spotify_active_device"
            }
        }
    }

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let volumeService: any SpeakerVolumeAdjusting
    private let outputSelection: PlaybackOutputSelection
    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let volumeCommands: SpeakerVolumeCommandQueue
    private let step = SpeakerVolumeControlDefaults.step

    private var volumeAdjustmentInFlight = false
    private var queuedVolumeAdjustment: QueuedVolumeAdjustment?
    private var muteToggleInFlight = false
    private var spotifyMuteRestoreVolume: Int?
    private var spotifyMuteRestoreDeviceName: String?

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        volumeCommands: SpeakerVolumeCommandQueue = .shared
    ) {
        self.volumeService = volumeService
        self.outputSelection = outputSelection
        self.activePlaybackObserver = activePlaybackObserver
        self.volumeCommands = volumeCommands
    }

    func adjustVolume(direction: VolumeDirection) {
        adjustVolume(direction: direction, target: selectedVolumeTarget())
    }

    private func adjustVolume(direction: VolumeDirection, target: ShortcutVolumeTarget) {
        if volumeAdjustmentInFlight {
            queuedVolumeAdjustment = QueuedVolumeAdjustment(target: target, direction: direction)
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) state=queued target=\(target.logTarget, privacy: .public)")
            return
        }

        volumeAdjustmentInFlight = true
        switch target {
        case let .sonos(roomName, scope):
            adjustSonosVolume(direction: direction, roomName: roomName, scope: scope)
        case .spotify:
            adjustSpotifyVolume(direction: direction)
        }
    }

    private func adjustSonosVolume(direction: VolumeDirection, roomName: String, scope: PlaybackVolumeScope) {
        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, step, logger] in
            do {
                let volume: Int
                switch (scope, direction) {
                case (.member, .down):
                    volume = try await volumeCommands.volumeDown(
                        using: volumeService,
                        roomName: roomName,
                        step: step
                    )
                case (.member, .up):
                    volume = try await volumeCommands.volumeUp(
                        using: volumeService,
                        roomName: roomName,
                        step: step
                    )
                case (.group, .down):
                    volume = try await volumeCommands.groupVolumeDown(
                        using: volumeService,
                        coordinatorRoomName: roomName,
                        step: step
                    )
                case (.group, .up):
                    volume = try await volumeCommands.groupVolumeUp(
                        using: volumeService,
                        coordinatorRoomName: roomName,
                        step: step
                    )
                }
                logger.info("SonosHandoffHotkeys result=success action=volume_\(direction.logName, privacy: .public) room=\(roomName, privacy: .public) scope=\(scope.logName, privacy: .public) step=\(step, privacy: .public) volume=\(volume, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: roomName, volume: volume, muted: false)
                    StatusHUD.shared.showVolume(roomName: roomName, volume: volume)
                    self.finishVolumeAdjustment(shouldRunQueued: true)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=volume_\(direction.logName, privacy: .public) room=\(roomName, privacy: .public) scope=\(scope.logName, privacy: .public) step=\(step, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(roomName) Volume Failed",
                        message: error.localizedDescription
                    )
                    self.finishVolumeAdjustment(shouldRunQueued: false)
                }
            }
        }
    }

    private func adjustSpotifyVolume(direction: VolumeDirection) {
        let logger = logger
        Task.detached(priority: .userInitiated) { [activePlaybackObserver, step, logger] in
            do {
                guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                      let currentVolume = status.volumePercent
                else {
                    await MainActor.run {
                        logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) ignored reason=no_active_spotify_device")
                        StatusHUD.shared.finish(
                            title: "Spotify Volume Unavailable",
                            message: "Spotify has no active device volume.",
                            dismissAfter: 2.0
                        )
                        self.finishVolumeAdjustment(shouldRunQueued: false)
                    }
                    return
                }

                let requestedVolume = max(0, min(100, currentVolume + direction.delta(step: step)))
                let confirmedVolume = try await activePlaybackObserver.setActivePlaybackDeviceVolume(requestedVolume)
                logger.info("SonosHandoffHotkeys result=success action=volume_\(direction.logName, privacy: .public) target=spotify_active_device device=\(status.deviceName, privacy: .public) step=\(step, privacy: .public) volume=\(confirmedVolume, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.showVolume(roomName: status.deviceName, volume: confirmedVolume)
                    self.finishVolumeAdjustment(shouldRunQueued: true)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=volume_\(direction.logName, privacy: .public) target=spotify_active_device step=\(step, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(title: "Spotify Volume Failed", message: error.localizedDescription)
                    self.finishVolumeAdjustment(shouldRunQueued: false)
                }
            }
        }
    }

    func clearQueuedVolumeAdjustment() {
        queuedVolumeAdjustment = nil
    }

    func toggleMute() {
        clearQueuedVolumeAdjustment()
        guard !muteToggleInFlight else {
            logger.info("SonosHandoffHotkeys action=mute_toggle state=ignored reason=in_flight")
            return
        }

        let target = selectedVolumeTarget()

        muteToggleInFlight = true
        switch target {
        case let .sonos(roomName, scope):
            toggleSonosMute(roomName: roomName, scope: scope)
        case .spotify:
            toggleSpotifyMute()
        }
    }

    private func toggleSonosMute(roomName: String, scope: PlaybackVolumeScope) {
        StatusHUD.shared.showMutePending(roomName: roomName)
        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, logger] in
            do {
                let muted: Bool
                switch scope {
                case .member:
                    muted = try await volumeCommands.toggleMute(using: volumeService, roomName: roomName)
                case .group:
                    muted = try await volumeCommands.toggleGroupMute(using: volumeService, coordinatorRoomName: roomName)
                }
                logger.info("SonosHandoffHotkeys result=success action=mute_toggle room=\(roomName, privacy: .public) scope=\(scope.logName, privacy: .public) muted=\(muted, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: roomName, muted: muted)
                    StatusHUD.shared.showMute(roomName: roomName, muted: muted)
                    self.muteToggleInFlight = false
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=mute_toggle room=\(roomName, privacy: .public) scope=\(scope.logName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(roomName) Mute Failed",
                        message: error.localizedDescription
                    )
                    self.muteToggleInFlight = false
                }
            }
        }
    }

    private func toggleSpotifyMute() {
        let restoreVolume = spotifyMuteRestoreVolume
        let restoreDeviceName = spotifyMuteRestoreDeviceName
        let logger = logger
        Task.detached(priority: .userInitiated) { [activePlaybackObserver, step, logger] in
            do {
                guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                      let currentVolume = status.volumePercent
                else {
                    await MainActor.run {
                        logger.info("SonosHandoffHotkeys action=mute_toggle ignored reason=no_active_spotify_device")
                        StatusHUD.shared.finish(
                            title: "Spotify Mute Unavailable",
                            message: "Spotify has no active device volume.",
                            dismissAfter: 2.0
                        )
                        self.muteToggleInFlight = false
                    }
                    return
                }

                let restoringSameDevice = status.deviceName == restoreDeviceName
                let requestedVolume: Int
                let nextRestoreVolume: Int?
                let nextRestoreDeviceName: String?
                if currentVolume == 0 {
                    requestedVolume = restoringSameDevice ? restoreVolume ?? step : step
                    nextRestoreVolume = nil
                    nextRestoreDeviceName = nil
                } else {
                    requestedVolume = 0
                    nextRestoreVolume = currentVolume
                    nextRestoreDeviceName = status.deviceName
                }

                let confirmedVolume = try await activePlaybackObserver.setActivePlaybackDeviceVolume(requestedVolume)
                logger.info("SonosHandoffHotkeys result=success action=mute_toggle target=spotify_active_device device=\(status.deviceName, privacy: .public) volume=\(confirmedVolume, privacy: .public)")
                await MainActor.run {
                    self.spotifyMuteRestoreVolume = nextRestoreVolume
                    self.spotifyMuteRestoreDeviceName = nextRestoreDeviceName
                    StatusHUD.shared.showVolume(roomName: status.deviceName, volume: confirmedVolume)
                    self.muteToggleInFlight = false
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=mute_toggle target=spotify_active_device error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(title: "Spotify Mute Failed", message: error.localizedDescription)
                    self.muteToggleInFlight = false
                }
            }
        }
    }

    private func finishVolumeAdjustment(shouldRunQueued: Bool) {
        volumeAdjustmentInFlight = false
        guard shouldRunQueued, let adjustment = queuedVolumeAdjustment else {
            queuedVolumeAdjustment = nil
            return
        }

        queuedVolumeAdjustment = nil
        adjustVolume(direction: adjustment.direction, target: adjustment.target)
    }

    private func selectedVolumeTarget() -> ShortcutVolumeTarget {
        if let selectedRoomName = SonosRoomName.normalized(outputSelection.roomName) {
            return .sonos(roomName: selectedRoomName, scope: volumeScope(roomName: selectedRoomName))
        }

        return .spotify
    }

    private func volumeScope(roomName: String) -> PlaybackVolumeScope {
        guard let selectedGroup = outputSelection.selectedGroup,
              selectedGroup.contains(roomName: roomName),
              selectedGroup.members.count > 1
        else {
            return .member
        }

        return .group
    }
}

private extension VolumeDirection {
    func delta(step: Int) -> Int {
        switch self {
        case .down:
            -step
        case .up:
            step
        }
    }
}

private extension PlaybackVolumeScope {
    var logName: String {
        switch self {
        case .member:
            "member"
        case .group:
            "group"
        }
    }
}
