import Foundation
import SonosHandoffCore

@MainActor
final class PlaybackVolumeActionController {
    private let volumeService: any SpeakerVolumeAdjusting
    private let volumeMonitor: SonosVolumeMonitor
    private let volumeCommands: SpeakerVolumeCommandQueue

    init(
        environment: AppEnvironment,
        volumeMonitor: SonosVolumeMonitor = .shared,
        volumeCommands: SpeakerVolumeCommandQueue = .shared
    ) {
        self.volumeService = environment.volumeService
        self.volumeMonitor = volumeMonitor
        self.volumeCommands = volumeCommands
    }

    func noteLocalChange(roomName: String, volume: Int? = nil, muted: Bool? = nil) {
        volumeMonitor.noteLocalChange(roomName: roomName, volume: volume, muted: muted)
    }

    func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        try await volumeCommands.volumeStatus(using: volumeService, roomName: roomName)
    }

    func adjustVolume(roomName: String, direction: VolumeDirection) async throws -> Int {
        switch direction {
        case .down:
            try await volumeCommands.volumeDown(
                using: volumeService,
                roomName: roomName,
                step: SpeakerVolumeControlDefaults.step
            )
        case .up:
            try await volumeCommands.volumeUp(
                using: volumeService,
                roomName: roomName,
                step: SpeakerVolumeControlDefaults.step
            )
        }
    }

    func toggleMute(roomName: String) async throws -> Bool {
        try await volumeCommands.toggleMute(using: volumeService, roomName: roomName)
    }

    func setVolume(roomName: String, volume: Int) async throws -> Int {
        try await volumeCommands.setVolume(using: volumeService, roomName: roomName, volume: volume)
    }
}
