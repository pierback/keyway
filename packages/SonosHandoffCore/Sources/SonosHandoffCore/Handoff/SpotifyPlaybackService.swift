import Foundation

final class SpotifyPlaybackService: @unchecked Sendable {
    private let bridge: SpotifyConnectBridge
    private let volumeMirrorQueue: SpotifyVolumeMirrorQueue

    init(
        bridge: SpotifyConnectBridge,
        volumeMirrorQueue: SpotifyVolumeMirrorQueue = SpotifyVolumeMirrorQueue()
    ) {
        self.bridge = bridge
        self.volumeMirrorQueue = volumeMirrorQueue
    }

    func activePlaybackDeviceStatus() async throws -> SpotifyPlaybackDeviceStatus? {
        try await bridge.activePlaybackDeviceStatus()
    }

    func availablePlaybackDevices() async throws -> [SpotifyAvailablePlaybackDevice] {
        try await bridge.availablePlaybackDevices()
    }

    func startActivePlayback(spotifyURI: String?, deviceName: String?, deviceType: String?) async throws {
        try await bridge.startPlayback(
            spotifyURI: spotifyURI,
            deviceName: deviceName,
            deviceType: deviceType
        )
    }

    func transferActivePlayback(deviceName: String?, deviceType: String?, play: Bool) async throws {
        try await bridge.transferPlayback(
            deviceName: deviceName,
            deviceType: deviceType,
            play: play
        )
    }

    func setActivePlaybackDeviceVolume(_ volume: Int) async throws -> Int {
        try await bridge.setActivePlaybackDeviceVolume(volume)
    }

    func sendActivePlaybackCommand(_ command: SpotifyPlaybackCommand) async throws {
        try await bridge.sendPlaybackCommand(command)
    }

    func verifyActiveDevice(named roomName: String) async throws -> ConnectPlayerState {
        try await bridge.verifyActiveDevice(named: roomName)
    }

    func verifyActiveDeviceIfAvailable(named roomName: String) async {
        await bridge.verifyActiveDeviceIfAvailable(named: roomName)
    }

    func mirrorVolumeIfNeeded(roomName: String, volume: Int) async {
        await volumeMirrorQueue.enqueue(roomName: roomName, volume: volume) { [bridge] roomName, volume in
            await bridge.setActiveDeviceVolumeIfNeeded(roomName: roomName, volume: volume)
        }
    }
}
