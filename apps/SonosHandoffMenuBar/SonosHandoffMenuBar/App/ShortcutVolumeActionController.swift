import Foundation
import os
import SonosHandoffCore

@MainActor
final class ShortcutVolumeActionController {
    private struct QueuedVolumeAdjustment {
        let roomName: String
        let direction: VolumeDirection
    }

    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Hotkeys")
    private let volumeService: any SpeakerVolumeAdjusting
    private let outputSelection: PlaybackOutputSelection
    private let configStore: any ConfigStoring
    private let outputPreferenceResolver = SonosOutputPreferenceResolver()
    private let volumeCommands: SpeakerVolumeCommandQueue
    private let step = SpeakerVolumeControlDefaults.step

    private var volumeAdjustmentInFlight = false
    private var queuedVolumeAdjustment: QueuedVolumeAdjustment?

    init(
        volumeService: any SpeakerVolumeAdjusting,
        outputSelection: PlaybackOutputSelection,
        configStore: any ConfigStoring,
        volumeCommands: SpeakerVolumeCommandQueue = .shared
    ) {
        self.volumeService = volumeService
        self.outputSelection = outputSelection
        self.configStore = configStore
        self.volumeCommands = volumeCommands
    }

    func adjustVolume(direction: VolumeDirection) {
        guard let roomName = selectedRoomName() else {
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) ignored reason=no_active_sonos_output")
            StatusHUD.shared.finish(
                title: "No Sonos Playback",
                message: "Start Spotify playback on a Sonos speaker first.",
                dismissAfter: 2.4
            )
            return
        }

        adjustVolume(direction: direction, roomName: roomName)
    }

    private func adjustVolume(direction: VolumeDirection, roomName: String) {
        if volumeAdjustmentInFlight {
            queuedVolumeAdjustment = QueuedVolumeAdjustment(roomName: roomName, direction: direction)
            logger.info("SonosHandoffHotkeys action=volume_\(direction.logName, privacy: .public) state=queued room=\(roomName, privacy: .public)")
            return
        }

        volumeAdjustmentInFlight = true
        StatusHUD.shared.showVolumePending(roomName: roomName, direction: direction)
        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, step, logger] in
            do {
                let volume: Int
                switch direction {
                case .down:
                    volume = try await volumeCommands.volumeDown(
                        using: volumeService,
                        roomName: roomName,
                        step: step
                    )
                case .up:
                    volume = try await volumeCommands.volumeUp(
                        using: volumeService,
                        roomName: roomName,
                        step: step
                    )
                }
                logger.info("SonosHandoffHotkeys result=success action=volume_\(direction.logName, privacy: .public) room=\(roomName, privacy: .public) step=\(step, privacy: .public) volume=\(volume, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: roomName, volume: volume, muted: false)
                    StatusHUD.shared.showVolume(roomName: roomName, volume: volume, direction: direction)
                    self.finishVolumeAdjustment(shouldRunQueued: true)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=volume_\(direction.logName, privacy: .public) room=\(roomName, privacy: .public) step=\(step, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
        guard let roomName = selectedRoomName() else {
            logger.info("SonosHandoffHotkeys action=mute_toggle ignored reason=no_active_sonos_output")
            StatusHUD.shared.finish(
                title: "No Sonos Playback",
                message: "Start Spotify playback on a Sonos speaker first.",
                dismissAfter: 2.4
            )
            return
        }

        StatusHUD.shared.showMutePending(roomName: roomName)
        let logger = logger
        Task.detached(priority: .userInitiated) { [volumeService, volumeCommands, logger] in
            do {
                let muted = try await volumeCommands.toggleMute(using: volumeService, roomName: roomName)
                logger.info("SonosHandoffHotkeys result=success action=mute_toggle room=\(roomName, privacy: .public) muted=\(muted, privacy: .public)")
                await MainActor.run {
                    SonosVolumeMonitor.shared.noteLocalChange(roomName: roomName, muted: muted)
                    StatusHUD.shared.showMute(roomName: roomName, muted: muted)
                }
            } catch {
                logger.error("SonosHandoffHotkeys result=failure action=mute_toggle room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    StatusHUD.shared.finish(
                        title: "\(roomName) Mute Failed",
                        message: error.localizedDescription
                    )
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
        adjustVolume(direction: adjustment.direction, roomName: adjustment.roomName)
    }

    private func selectedRoomName() -> String? {
        if let selectedRoomName = SonosRoomName.normalized(outputSelection.roomName) {
            return selectedRoomName
        }

        let config = try? configStore.load()
        return outputPreferenceResolver.preferredRoomName(selectedRoomName: nil, config: config)
    }
}
