import Foundation

public final class SpotifyConnectHandoffService: HandoffPerforming, RoomHandoffPerforming, SonosSpeakerDiscovering, SonosGroupingStateReading, SonosGroupingEditing, SpeakerVolumeAdjusting, SpotifyActivePlaybackObserving, @unchecked Sendable {
    private let runtime: SonosRuntime

    public init(
        configStore: ConfigStoring,
        targetResolver: TargetResolver = TargetResolver(),
        loginID: String? = nil,
        appSupport: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/sonos-handoff", isDirectory: true),
        urlSession: URLSession = .shared
    ) {
        self.runtime = SonosRuntime(
            configStore: configStore,
            targetResolver: targetResolver,
            loginID: loginID,
            appSupport: appSupport,
            urlSession: urlSession
        )
    }

    public func transfer(to alias: String) async -> TransferResult {
        await runtime.transfer(to: alias)
    }

    public func transfer(toRoomName roomName: String, verification: RoomHandoffVerificationMode) async -> TransferResult {
        await runtime.transfer(toRoomName: roomName, verification: verification)
    }

    public func discoverSpeakers() async throws -> [SonosSpeaker] {
        try await runtime.discoverSpeakers()
    }

    public func discoverGroupState() async throws -> SonosGroupState {
        try await runtime.discoverGroupState()
    }

    public func join(roomName: String, toCoordinatorRoomName coordinatorRoomName: String) async throws {
        try await runtime.join(roomName: roomName, toCoordinatorRoomName: coordinatorRoomName)
    }

    public func join(roomNames: [String], toCoordinatorRoomName coordinatorRoomName: String) async throws {
        try await runtime.join(roomNames: roomNames, toCoordinatorRoomName: coordinatorRoomName)
    }

    public func removeFromGroup(roomName: String) async throws {
        try await runtime.removeFromGroup(roomName: roomName)
    }

    public func migrateCoordinator(groupID: String, toRoomName roomName: String) async throws {
        try await runtime.migrateCoordinator(groupID: groupID, toRoomName: roomName)
    }

    public func removeCoordinator(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws {
        try await runtime.removeCoordinator(
            in: group,
            coordinatorRoomName: coordinatorRoomName,
            replacementRoomName: replacementRoomName
        )
    }

    public func volumeDown(roomName: String, step: Int = 5) async throws -> Int {
        try await runtime.volumeDown(roomName: roomName, step: step)
    }

    public func volumeUp(roomName: String, step: Int = 5) async throws -> Int {
        try await runtime.volumeUp(roomName: roomName, step: step)
    }

    public func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        try await runtime.volumeStatus(roomName: roomName)
    }

    public func setVolume(roomName: String, volume: Int) async throws -> Int {
        try await runtime.setVolume(roomName: roomName, volume: volume)
    }

    public func toggleMute(roomName: String) async throws -> Bool {
        try await runtime.toggleMute(roomName: roomName)
    }

    public func setMute(roomName: String, muted: Bool) async throws -> Bool {
        try await runtime.setMute(roomName: roomName, muted: muted)
    }

    public func activePlaybackDeviceStatus() async throws -> SpotifyPlaybackDeviceStatus? {
        try await runtime.activePlaybackDeviceStatus()
    }
}
