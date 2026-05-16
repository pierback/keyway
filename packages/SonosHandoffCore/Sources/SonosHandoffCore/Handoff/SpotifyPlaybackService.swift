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
