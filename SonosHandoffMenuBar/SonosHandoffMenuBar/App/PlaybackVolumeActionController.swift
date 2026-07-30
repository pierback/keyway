import Foundation
import SonosHandoffCore

@MainActor
final class PlaybackVolumeActionController {
    private let volumeService: any SpeakerVolumeAdjusting
    private let volumeMonitor: SonosVolumeMonitor
    private let volumeCommands: SpeakerVolumeCommandQueue

    init(
        volumeService: any SpeakerVolumeAdjusting,
        volumeMonitor: SonosVolumeMonitor = .shared,
        volumeCommands: SpeakerVolumeCommandQueue = .shared
    ) {
        self.volumeService = volumeService
        self.volumeMonitor = volumeMonitor
        self.volumeCommands = volumeCommands
    }

    func noteLocalChange(roomName: String, volume: Int? = nil, muted: Bool? = nil) {
        volumeMonitor.noteLocalChange(roomName: roomName, volume: volume, muted: muted)
    }

    func volumeStatus(roomName: String, scope: PlaybackVolumeScope) async throws -> SpeakerVolumeStatus {
        switch scope {
        case .member:
            try await volumeCommands.volumeStatus(using: volumeService, roomName: roomName)
        case .group:
            try await volumeCommands.groupVolumeStatus(using: volumeService, coordinatorRoomName: roomName)
        }
    }

    func adjustVolume(roomName: String, scope: PlaybackVolumeScope, direction: VolumeDirection) async throws -> Int {
        switch (scope, direction) {
        case (.member, .down):
            try await volumeCommands.volumeDown(
                using: volumeService,
                roomName: roomName,
                step: SpeakerVolumeControlDefaults.step
            )
        case (.member, .up):
            try await volumeCommands.volumeUp(
                using: volumeService,
                roomName: roomName,
                step: SpeakerVolumeControlDefaults.step
            )
        case (.group, .down):
            try await volumeCommands.groupVolumeDown(
                using: volumeService,
                coordinatorRoomName: roomName,
                step: SpeakerVolumeControlDefaults.step
            )
        case (.group, .up):
            try await volumeCommands.groupVolumeUp(
                using: volumeService,
                coordinatorRoomName: roomName,
                step: SpeakerVolumeControlDefaults.step
            )
        }
    }

    func toggleMute(roomName: String, scope: PlaybackVolumeScope) async throws -> Bool {
        switch scope {
        case .member:
            try await volumeCommands.toggleMute(using: volumeService, roomName: roomName)
        case .group:
            try await volumeCommands.toggleGroupMute(using: volumeService, coordinatorRoomName: roomName)
        }
    }

    func setVolume(roomName: String, scope: PlaybackVolumeScope, volume: Int) async throws -> Int {
        switch scope {
        case .member:
            try await volumeCommands.setVolume(using: volumeService, roomName: roomName, volume: volume)
        case .group:
            try await volumeCommands.setGroupVolume(using: volumeService, coordinatorRoomName: roomName, volume: volume)
        }
    }

    func memberVolumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        try await volumeCommands.memberVolumeStatus(using: volumeService, roomName: roomName)
    }

    func setMemberVolume(roomName: String, volume: Int) async throws -> Int {
        try await volumeCommands.setMemberVolume(using: volumeService, roomName: roomName, volume: volume)
    }
}
