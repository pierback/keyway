import Foundation

final class SonosRuntime: @unchecked Sendable {
    private let configStore: ConfigStoring
    private let targetResolver: TargetResolver
    private let directory: SonosDirectory
    private let volumeService: SonosVolumeService
    private let groupingService: SonosGroupingService
    private let spotifyPlayback: SpotifyPlaybackService
    private let transferService: SpotifyConnectTransferService

    init(
        configStore: ConfigStoring,
        targetResolver: TargetResolver = TargetResolver(),
        loginID: String? = nil,
        appSupport: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/sonos-handoff", isDirectory: true),
        urlSession: URLSession = .shared
    ) {
        self.configStore = configStore
        self.targetResolver = targetResolver
        let soapClient = SonosSOAPClient(urlSession: urlSession)
        let zeroconfClient = SonosSpotifyZeroconfClient(urlSession: urlSession)
        let directory = SonosDirectory(
            zeroconfClient: zeroconfClient,
            zoneGroupTopology: SonosZoneGroupTopology(soapClient: soapClient)
        )
        let renderingControl = SonosRenderingControl(soapClient: soapClient)
        let avTransport = SonosAVTransport(soapClient: soapClient)
        let transferVerifier = SonosTransferVerifier(soapClient: soapClient)
        let spotifyBridge = SpotifyConnectBridge(
            loginID: loginID,
            appSupport: appSupport,
            urlSession: urlSession
        )
        let spotifyPlayback = SpotifyPlaybackService(bridge: spotifyBridge)

        self.directory = directory
        self.spotifyPlayback = spotifyPlayback
        self.volumeService = SonosVolumeService(
            directory: directory,
            renderingControl: renderingControl,
            spotifyPlayback: spotifyPlayback
        )
        self.groupingService = SonosGroupingService(directory: directory, avTransport: avTransport)
        self.transferService = SpotifyConnectTransferService(
            directory: directory,
            spotifyBridge: spotifyBridge,
            spotifyPlayback: spotifyPlayback,
            zeroconfClient: zeroconfClient,
            transferVerifier: transferVerifier
        )
    }

    func transfer(to alias: String) async -> TransferResult {
        do {
            let config = try configStore.load()
            guard let target = targetResolver.resolve(alias: alias, in: config) else {
                return .failure(code: .targetNotConfigured, message: "No saved target found for alias '\(alias)'.")
            }

            try await transferService.transferToRoom(named: target.spotifyDeviceName)
            return .success
        } catch let error as ConnectHandoffError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(code: .unsupported, message: error.localizedDescription)
        }
    }

    func transfer(toRoomName roomName: String) async -> TransferResult {
        do {
            try await transferService.transferToRoom(named: roomName)
            return .success
        } catch let error as ConnectHandoffError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(code: .unsupported, message: error.localizedDescription)
        }
    }

    func discoverSpeakers() async throws -> [SonosSpeaker] {
        try await directory.discoverSpeakers()
    }

    func discoverGroupState() async throws -> SonosGroupState {
        try await directory.discoverGroupState()
    }

    func join(roomName: String, toCoordinatorRoomName coordinatorRoomName: String) async throws {
        try await groupingService.join(roomName: roomName, toCoordinatorRoomName: coordinatorRoomName)
    }

    func removeFromGroup(roomName: String) async throws {
        try await groupingService.removeFromGroup(roomName: roomName)
    }

    func migrateCoordinator(groupID: String, toRoomName roomName: String) async throws {
        try await groupingService.migrateCoordinator(groupID: groupID, toRoomName: roomName)
    }

    func removeCoordinator(groupID: String, coordinatorRoomName: String, replacementRoomName: String) async throws {
        try await groupingService.removeCoordinator(
            groupID: groupID,
            coordinatorRoomName: coordinatorRoomName,
            replacementRoomName: replacementRoomName
        )
    }

    func activePlaybackDeviceStatus() async throws -> SpotifyPlaybackDeviceStatus? {
        try await spotifyPlayback.activePlaybackDeviceStatus()
    }

    func volumeDown(roomName: String, step: Int = 5) async throws -> Int {
        try await volumeService.volumeDown(roomName: roomName, step: step)
    }

    func volumeUp(roomName: String, step: Int = 5) async throws -> Int {
        try await volumeService.volumeUp(roomName: roomName, step: step)
    }

    func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        try await volumeService.status(roomName: roomName)
    }

    func setVolume(roomName: String, volume: Int) async throws -> Int {
        try await volumeService.setVolume(roomName: roomName, volume: volume)
    }

    func toggleMute(roomName: String) async throws -> Bool {
        try await volumeService.toggleMute(roomName: roomName)
    }
}
