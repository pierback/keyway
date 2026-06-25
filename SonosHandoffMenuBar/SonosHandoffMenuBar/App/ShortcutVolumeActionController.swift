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
    private let volumeCommands: SpeakerVolumeCommandQueue
    private let spotifyVolumeController: SpotifyActiveDeviceVolumeController
    private let step = SpeakerVolumeControlDefaults.step

    private var volumeAdjustmentInFlight = false
    private var queuedVolumeAdjustment: QueuedVolumeAdjustment?
    private var sonosMuteToggleInFlight = false

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        activePlaybackObserver: any SpotifyActivePlaybackObserving,
        volumeCommands: SpeakerVolumeCommandQueue = .shared
    ) {
        self.volumeService = volumeService
        self.outputSelection = outputSelection
        self.volumeCommands = volumeCommands
        self.spotifyVolumeController = SpotifyActiveDeviceVolumeController(
            activePlaybackObserver: activePlaybackObserver,
            step: SpeakerVolumeControlDefaults.step
        )
    }

    func adjustVolume(direction: VolumeDirection) {
        adjustVolume(direction: direction, target: selectedVolumeTarget())
    }

    private func adjustVolume(direction: VolumeDirection, target: ShortcutVolumeTarget) {
        switch target {
        case let .sonos(roomName, scope):
            adjustSonosVolume(direction: direction, roomName: roomName, scope: scope)
        case .spotify:
            spotifyVolumeController.adjustVolume(direction: direction)
        }
    }

    private func adjustSonosVolume(direction: VolumeDirection, roomName: String, scope: PlaybackVolumeScope) {
        if volumeAdjustmentInFlight {
            let target = ShortcutVolumeTarget.sonos(roomName: roomName, scope: scope)
            queuedVolumeAdjustment = QueuedVolumeAdjustment(target: target, direction: direction)
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) state=queued target=\(target.logTarget, privacy: .public)")
            return
        }

        volumeAdjustmentInFlight = true
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

    func clearQueuedVolumeAdjustment() {
        queuedVolumeAdjustment = nil
    }

    func toggleMute() {
        clearQueuedVolumeAdjustment()
        let target = selectedVolumeTarget()
        switch target {
        case let .sonos(roomName, scope):
            guard !sonosMuteToggleInFlight else {
                logger.info("SonosHandoffHotkeys action=mute_toggle state=ignored reason=in_flight")
                return
            }
            sonosMuteToggleInFlight = true
            toggleSonosMute(roomName: roomName, scope: scope)
        case .spotify:
            spotifyVolumeController.toggleMute()
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
                    self.sonosMuteToggleInFlight = false
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=mute_toggle room=\(roomName, privacy: .public) scope=\(scope.logName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(roomName) Mute Failed",
                        message: error.localizedDescription
                    )
                    self.sonosMuteToggleInFlight = false
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

@MainActor
private final class SpotifyActiveDeviceVolumeController {
    private struct SpotifyVolumeState {
        let deviceName: String
        var desiredVolume: Int
        var updatedAt: CFAbsoluteTime
    }

    private let activePlaybackObserver: any SpotifyActivePlaybackObserving
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let step: Int
    private let spotifyVolumeStateTTL: CFTimeInterval = 4.0

    private var muteRestoreVolume: Int?
    private var muteRestoreDeviceName: String?
    private var volumeState: SpotifyVolumeState?
    private var volumeBootstrapInFlight = false
    private var volumeBootstrapDelta = 0
    private var volumeWriteInFlight = false
    private var volumeWritePending = false
    private var muteToggleInFlight = false

    init(activePlaybackObserver: any SpotifyActivePlaybackObserving, step: Int) {
        self.activePlaybackObserver = activePlaybackObserver
        self.step = step
    }

    func adjustVolume(direction: VolumeDirection) {
        let delta = direction.delta(step: step)
        if let state = freshVolumeState() {
            applyDesiredVolume(deviceName: state.deviceName, volume: state.desiredVolume + delta)
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) state=optimistic target=spotify_active_device")
            return
        }

        volumeBootstrapDelta += delta
        guard !volumeBootstrapInFlight else {
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) state=bootstrap_queued target=spotify_active_device")
            return
        }

        volumeBootstrapInFlight = true
        let logger = logger
        Task.detached(priority: .userInitiated) { [activePlaybackObserver, logger, step] in
            do {
                guard let status = try await activePlaybackObserver.activePlaybackDeviceStatus(),
                      let currentVolume = status.volumePercent
                else {
                    await MainActor.run {
                        self.volumeBootstrapInFlight = false
                        self.volumeBootstrapDelta = 0
                        logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) ignored reason=no_active_spotify_device")
                        StatusHUD.shared.finish(
                            title: "Spotify Volume Unavailable",
                            message: "Spotify has no active device volume.",
                            dismissAfter: 2.0
                        )
                    }
                    return
                }

                await MainActor.run {
                    let requestedVolume = currentVolume + self.volumeBootstrapDelta
                    self.volumeBootstrapInFlight = false
                    self.volumeBootstrapDelta = 0
                    self.applyDesiredVolume(deviceName: status.deviceName, volume: requestedVolume)
                    logger.info("SonosHandoffHotkeys result=bootstrapped action=volume_\(direction.logName, privacy: .public) target=spotify_active_device device=\(status.deviceName, privacy: .public)")
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=volume_\(direction.logName, privacy: .public) target=spotify_active_device step=\(step, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.volumeBootstrapInFlight = false
                    self.volumeBootstrapDelta = 0
                    StatusHUD.shared.finish(title: "Spotify Volume Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func toggleMute() {
        guard !muteToggleInFlight else {
            logger.info("SonosHandoffHotkeys action=mute_toggle state=ignored reason=in_flight")
            return
        }

        muteToggleInFlight = true
        if let state = freshVolumeState() {
            let requestedVolume = muteToggleVolume(deviceName: state.deviceName, currentVolume: state.desiredVolume)
            applyDesiredVolume(deviceName: state.deviceName, volume: requestedVolume)
            muteToggleInFlight = false
            return
        }

        let logger = logger
        Task.detached(priority: .userInitiated) { [activePlaybackObserver, logger] in
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

                await MainActor.run {
                    let requestedVolume = self.muteToggleVolume(deviceName: status.deviceName, currentVolume: currentVolume)
                    self.applyDesiredVolume(deviceName: status.deviceName, volume: requestedVolume)
                    logger.info("SonosHandoffHotkeys result=bootstrapped action=mute_toggle target=spotify_active_device device=\(status.deviceName, privacy: .public) volume=\(requestedVolume, privacy: .public)")
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

    private func muteToggleVolume(deviceName: String, currentVolume: Int) -> Int {
        if currentVolume == 0 {
            let restoreVolume = muteRestoreVolume
            let restoringSameDevice = deviceName == muteRestoreDeviceName
            muteRestoreVolume = nil
            muteRestoreDeviceName = nil
            return restoringSameDevice ? restoreVolume ?? step : step
        }

        muteRestoreVolume = currentVolume
        muteRestoreDeviceName = deviceName
        return 0
    }

    private func freshVolumeState() -> SpotifyVolumeState? {
        guard let state = volumeState,
              CFAbsoluteTimeGetCurrent() - state.updatedAt <= spotifyVolumeStateTTL
        else {
            return nil
        }
        return state
    }

    private func applyDesiredVolume(deviceName: String, volume: Int) {
        let requestedVolume = clampedVolume(volume)
        volumeState = SpotifyVolumeState(
            deviceName: deviceName,
            desiredVolume: requestedVolume,
            updatedAt: CFAbsoluteTimeGetCurrent()
        )
        StatusHUD.shared.showVolume(roomName: deviceName, volume: requestedVolume, dismissAfter: 1.2)
        scheduleVolumeWrite()
    }

    private func scheduleVolumeWrite() {
        guard !volumeWriteInFlight else {
            volumeWritePending = true
            return
        }
        guard let state = volumeState else {
            volumeWritePending = false
            return
        }

        volumeWritePending = false
        volumeWriteInFlight = true
        let requestedVolume = state.desiredVolume
        let logger = logger
        Task.detached(priority: .userInitiated) { [activePlaybackObserver, logger] in
            do {
                let confirmedVolume = try await activePlaybackObserver.setActivePlaybackDeviceVolume(requestedVolume)
                logger.info("SonosHandoffHotkeys result=success action=spotify_volume_write target=spotify_active_device requested_volume=\(requestedVolume, privacy: .public) confirmed_volume=\(confirmedVolume, privacy: .public)")
                await MainActor.run {
                    self.finishVolumeWrite(requestedVolume: requestedVolume, confirmedVolume: confirmedVolume)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=spotify_volume_write target=spotify_active_device requested_volume=\(requestedVolume, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.volumeWriteInFlight = false
                    self.volumeWritePending = false
                    self.volumeState = nil
                    StatusHUD.shared.finish(title: "Spotify Volume Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func finishVolumeWrite(requestedVolume: Int, confirmedVolume: Int) {
        volumeWriteInFlight = false
        let shouldWriteAgain = volumeWritePending
        volumeWritePending = false

        if !shouldWriteAgain, var state = volumeState, state.desiredVolume == requestedVolume {
            state.desiredVolume = confirmedVolume
            state.updatedAt = CFAbsoluteTimeGetCurrent()
            volumeState = state
        }

        if shouldWriteAgain {
            scheduleVolumeWrite()
        }
    }

    private func clampedVolume(_ volume: Int) -> Int {
        min(max(volume, 0), 100)
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
