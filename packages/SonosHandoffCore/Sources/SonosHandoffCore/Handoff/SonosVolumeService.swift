import Foundation

final class SonosVolumeService: @unchecked Sendable {
    private let directory: SonosDirectory
    private let renderingControl: SonosRenderingControl
    private let spotifyPlayback: SpotifyPlaybackService

    init(
        directory: SonosDirectory,
        renderingControl: SonosRenderingControl,
        spotifyPlayback: SpotifyPlaybackService
    ) {
        self.directory = directory
        self.renderingControl = renderingControl
        self.spotifyPlayback = spotifyPlayback
    }

    func volumeDown(roomName: String, step: Int = 5) async throws -> Int {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        let volume = try await renderingControl.volumeDown(on: target, step: step)
        await spotifyPlayback.mirrorVolumeIfNeeded(roomName: target.roomName, volume: volume)
        return volume
    }

    func volumeUp(roomName: String, step: Int = 5) async throws -> Int {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        let volume = try await renderingControl.volumeUp(on: target, step: step)
        await spotifyPlayback.mirrorVolumeIfNeeded(roomName: target.roomName, volume: volume)
        return volume
    }

    func status(roomName: String) async throws -> SpeakerVolumeStatus {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        return try await renderingControl.status(on: target)
    }

    func setVolume(roomName: String, volume: Int) async throws -> Int {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        let confirmedVolume = try await renderingControl.setVolume(on: target, to: volume)
        await spotifyPlayback.mirrorVolumeIfNeeded(roomName: target.roomName, volume: confirmedVolume)
        return confirmedVolume
    }

    func toggleMute(roomName: String) async throws -> Bool {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        return try await renderingControl.toggleMute(on: target)
    }

    func setMute(roomName: String, muted: Bool) async throws -> Bool {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        return try await renderingControl.setMute(on: target, to: muted)
    }

    func memberStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        return try await renderingControl.status(on: target)
    }

    func setMemberVolume(roomName: String, volume: Int) async throws -> Int {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)
        return try await renderingControl.setVolume(on: target, to: volume)
    }

    func groupVolumeDown(coordinatorRoomName: String, step: Int = 5) async throws -> Int {
        let target = try await directory.resolveTarget(named: coordinatorRoomName, needsSpotifyMetadata: false)
        let volume = try await renderingControl.groupVolumeDown(on: target, step: step)
        await spotifyPlayback.mirrorVolumeIfNeeded(roomName: target.roomName, volume: volume)
        return volume
    }

    func groupVolumeUp(coordinatorRoomName: String, step: Int = 5) async throws -> Int {
        let target = try await directory.resolveTarget(named: coordinatorRoomName, needsSpotifyMetadata: false)
        let volume = try await renderingControl.groupVolumeUp(on: target, step: step)
        await spotifyPlayback.mirrorVolumeIfNeeded(roomName: target.roomName, volume: volume)
        return volume
    }

    func groupStatus(coordinatorRoomName: String) async throws -> SpeakerVolumeStatus {
        let target = try await directory.resolveTarget(named: coordinatorRoomName, needsSpotifyMetadata: false)
        return try await renderingControl.groupStatus(on: target)
    }

    func setGroupVolume(coordinatorRoomName: String, volume: Int) async throws -> Int {
        let target = try await directory.resolveTarget(named: coordinatorRoomName, needsSpotifyMetadata: false)
        let confirmedVolume = try await renderingControl.setGroupVolume(on: target, to: volume)
        await spotifyPlayback.mirrorVolumeIfNeeded(roomName: target.roomName, volume: confirmedVolume)
        return confirmedVolume
    }

    func toggleGroupMute(coordinatorRoomName: String) async throws -> Bool {
        let target = try await directory.resolveTarget(named: coordinatorRoomName, needsSpotifyMetadata: false)
        return try await renderingControl.toggleGroupMute(on: target)
    }

    func setGroupMute(coordinatorRoomName: String, muted: Bool) async throws -> Bool {
        let target = try await directory.resolveTarget(named: coordinatorRoomName, needsSpotifyMetadata: false)
        return try await renderingControl.setGroupMute(on: target, to: muted)
    }
}
