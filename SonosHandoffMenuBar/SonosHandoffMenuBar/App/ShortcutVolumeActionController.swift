import Foundation
import os
import SonosHandoffCore

@MainActor
final class ShortcutVolumeActionController {
    private struct QueuedVolumeAdjustment: Sendable {
        let target: ShortcutVolumeTarget
        let direction: VolumeDirection
    }

    private struct ShortcutVolumeTarget: Sendable {
        let roomName: String
        let scope: PlaybackVolumeScope
    }

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private let volumeService: any SpeakerVolumeAdjusting
    private let outputSelection: PlaybackOutputSelection
    private let outputPreferenceResolver = SonosOutputPreferenceResolver()
    private let volumeCommands: SpeakerVolumeCommandQueue
    private let step = SpeakerVolumeControlDefaults.step

    private var volumeAdjustmentInFlight = false
    private var queuedVolumeAdjustment: QueuedVolumeAdjustment?
    private var muteToggleInFlight = false

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        volumeCommands: SpeakerVolumeCommandQueue = .shared
    ) {
        self.volumeService = volumeService
        self.outputSelection = outputSelection
        self.volumeCommands = volumeCommands
    }

    func adjustVolume(direction: VolumeDirection) {
        guard let target = selectedVolumeTarget() else {
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) ignored reason=no_active_sonos_output")
            StatusHUD.shared.finish(
                title: "No Sonos Playback",
                message: "Start Spotify playback on a Sonos speaker first.",
                dismissAfter: 2.4
            )
            return
        }

        adjustVolume(direction: direction, target: target)
    }

    private func adjustVolume(direction: VolumeDirection, target: ShortcutVolumeTarget) {
        if volumeAdjustmentInFlight {
            queuedVolumeAdjustment = QueuedVolumeAdjustment(target: target, direction: direction)
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) state=queued room=\(target.roomName, privacy: .public) scope=\(target.scope.logName, privacy: .public)")
            return
        }

        volumeAdjustmentInFlight = true
        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, step, logger] in
            do {
                let volume: Int
                switch (target.scope, direction) {
                case (.member, .down):
                    volume = try await volumeCommands.volumeDown(
                        using: volumeService,
                        roomName: target.roomName,
                        step: step
                    )
                case (.member, .up):
                    volume = try await volumeCommands.volumeUp(
                        using: volumeService,
                        roomName: target.roomName,
                        step: step
                    )
                case (.group, .down):
                    volume = try await volumeCommands.groupVolumeDown(
                        using: volumeService,
                        coordinatorRoomName: target.roomName,
                        step: step
                    )
                case (.group, .up):
                    volume = try await volumeCommands.groupVolumeUp(
                        using: volumeService,
                        coordinatorRoomName: target.roomName,
                        step: step
                    )
                }
                logger.info("SonosHandoffHotkeys result=success action=volume_\(direction.logName, privacy: .public) room=\(target.roomName, privacy: .public) scope=\(target.scope.logName, privacy: .public) step=\(step, privacy: .public) volume=\(volume, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: target.roomName, volume: volume, muted: false)
                    StatusHUD.shared.showVolume(roomName: target.roomName, volume: volume)
                    self.finishVolumeAdjustment(shouldRunQueued: true)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=volume_\(direction.logName, privacy: .public) room=\(target.roomName, privacy: .public) scope=\(target.scope.logName, privacy: .public) step=\(step, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(target.roomName) Volume Failed",
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
        guard !muteToggleInFlight else {
            logger.info("SonosHandoffHotkeys action=mute_toggle state=ignored reason=in_flight")
            return
        }

        guard let target = selectedVolumeTarget() else {
            logger.info("SonosHandoffHotkeys action=mute_toggle ignored reason=no_active_sonos_output")
            StatusHUD.shared.finish(
                title: "No Sonos Playback",
                message: "Start Spotify playback on a Sonos speaker first.",
                dismissAfter: 2.4
            )
            return
        }

        muteToggleInFlight = true
        StatusHUD.shared.showMutePending(roomName: target.roomName)
        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, logger] in
            do {
                let muted: Bool
                switch target.scope {
                case .member:
                    muted = try await volumeCommands.toggleMute(using: volumeService, roomName: target.roomName)
                case .group:
                    muted = try await volumeCommands.toggleGroupMute(using: volumeService, coordinatorRoomName: target.roomName)
                }
                logger.info("SonosHandoffHotkeys result=success action=mute_toggle room=\(target.roomName, privacy: .public) scope=\(target.scope.logName, privacy: .public) muted=\(muted, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: target.roomName, muted: muted)
                    StatusHUD.shared.showMute(roomName: target.roomName, muted: muted)
                    self.muteToggleInFlight = false
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=mute_toggle room=\(target.roomName, privacy: .public) scope=\(target.scope.logName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(target.roomName) Mute Failed",
                        message: error.localizedDescription
                    )
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

    private func selectedVolumeTarget() -> ShortcutVolumeTarget? {
        if let selectedRoomName = SonosRoomName.normalized(outputSelection.roomName) {
            return ShortcutVolumeTarget(
                roomName: selectedRoomName,
                scope: volumeScope(roomName: selectedRoomName)
            )
        }

        let preferredRoomName = outputPreferenceResolver.preferredRoomName(selectedRoomName: nil)
        return ShortcutVolumeTarget(roomName: preferredRoomName, scope: .member)
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
