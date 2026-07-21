import Foundation

public final class SpotifyConnectHandoffService: RoomHandoffPerforming, SonosGroupingStateReading, SonosGroupingEditing, SpeakerVolumeAdjusting, SpotifyActivePlaybackObserving, @unchecked Sendable {
    private let directory: SonosDirectory
    private let volumeService: SonosVolumeService
    private let groupingService: SonosGroupingService
    private let spotifyBridge: SpotifyConnectBridge
    private let transferService: SpotifyConnectTransferService
    private let avTransport: SonosAVTransport

    public init(
        loginID: String? = nil,
        appSupport: URL = ConfigPaths.applicationSupportDirectory,
        urlSession: URLSession = .shared
    ) {
        let soapClient = SonosSOAPClient(urlSession: urlSession)
        let zeroconfClient = SonosSpotifyZeroconfClient(urlSession: urlSession)
        let directory = SonosDirectory(
            zeroconfClient: zeroconfClient,
            zoneGroupTopology: SonosZoneGroupTopology(soapClient: soapClient)
        )
        let avTransport = SonosAVTransport(soapClient: soapClient)
        let spotifyBridge = SpotifyConnectBridge(
            loginID: loginID,
            appSupport: appSupport,
            urlSession: urlSession
        )

        self.directory = directory
        self.avTransport = avTransport
        self.spotifyBridge = spotifyBridge
        self.volumeService = SonosVolumeService(
            directory: directory,
            renderingControl: SonosRenderingControl(soapClient: soapClient),
            spotifyBridge: spotifyBridge
        )
        self.groupingService = SonosGroupingService(directory: directory, avTransport: avTransport)
        self.transferService = SpotifyConnectTransferService(
            directory: directory,
            spotifyBridge: spotifyBridge,
            zeroconfClient: zeroconfClient,
            transferVerifier: SonosTransferVerifier(avTransport: avTransport),
            coordinatorMigrationTransferVerifier: SonosTransferVerifier(
                avTransport: avTransport,
                timing: .coordinatorMigration
            ),
            connectOnlyTransferVerifier: SonosTransferVerifier(
                avTransport: avTransport,
                timing: .connectOnly
            )
        )
    }

    public func transfer(toRoomName roomName: String, verification: RoomHandoffVerificationMode) async -> TransferResult {
        do {
            try await transferService.transferToRoom(named: roomName, verification: verification)

            return .success
        } catch let error as ConnectHandoffError {

            return .failure(code: error.code, message: error.message)
        } catch {

            return .failure(code: .unsupported, message: error.localizedDescription)
        }
    }

    public func discoverGroupState() async throws -> SonosGroupState {
        try await directory.discoverGroupState()
    }

    public func discoverGroupState(visibleSpeakers: [SonosSpeaker]) async throws -> SonosGroupState {
        try await directory.discoverGroupState(visibleSpeakers: visibleSpeakers)
    }

    public func join(roomName: String, toCoordinatorRoomName coordinatorRoomName: String) async throws {
        try await groupingService.join(roomName: roomName, toCoordinatorRoomName: coordinatorRoomName)
    }

    public func join(roomNames: [String], toCoordinatorRoomName coordinatorRoomName: String) async throws {
        try await groupingService.join(roomNames: roomNames, toCoordinatorRoomName: coordinatorRoomName)
    }

    public func removeFromGroup(roomName: String) async throws {
        try await groupingService.removeFromGroup(roomName: roomName)
    }

    public func migrateCoordinator(groupID: String, toRoomName roomName: String) async throws {
        try await groupingService.migrateCoordinator(groupID: groupID, toRoomName: roomName)
    }

    public func prepareCoordinatorRemoval(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws {
        try await groupingService.prepareCoordinatorRemoval(
            in: group,
            coordinatorRoomName: coordinatorRoomName,
            replacementRoomName: replacementRoomName
        )
    }

    public func finishCoordinatorRemoval(
        in group: SonosSpeakerGroup,
        coordinatorRoomName: String,
        replacementRoomName: String
    ) async throws {
        try await groupingService.finishCoordinatorRemoval(
            in: group,
            coordinatorRoomName: coordinatorRoomName,
            replacementRoomName: replacementRoomName
        )
    }

    public func volumeDown(roomName: String, step: Int = 5) async throws -> Int {
        try await volumeService.volumeDown(roomName: roomName, step: step)
    }

    public func volumeUp(roomName: String, step: Int = 5) async throws -> Int {
        try await volumeService.volumeUp(roomName: roomName, step: step)
    }

    public func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        try await volumeService.status(roomName: roomName)
    }

    public func setVolume(roomName: String, volume: Int) async throws -> Int {
        try await volumeService.setVolume(roomName: roomName, volume: volume)
    }

    public func toggleMute(roomName: String) async throws -> Bool {
        try await volumeService.toggleMute(roomName: roomName)
    }

    public func setMute(roomName: String, muted: Bool) async throws -> Bool {
        try await volumeService.setMute(roomName: roomName, muted: muted)
    }

    public func memberVolumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        try await volumeService.memberStatus(roomName: roomName)
    }

    public func setMemberVolume(roomName: String, volume: Int) async throws -> Int {
        try await volumeService.setMemberVolume(roomName: roomName, volume: volume)
    }

    public func groupVolumeDown(coordinatorRoomName: String, step: Int = 5) async throws -> Int {
        try await volumeService.groupVolumeDown(coordinatorRoomName: coordinatorRoomName, step: step)
    }

    public func groupVolumeUp(coordinatorRoomName: String, step: Int = 5) async throws -> Int {
        try await volumeService.groupVolumeUp(coordinatorRoomName: coordinatorRoomName, step: step)
    }

    public func groupVolumeStatus(coordinatorRoomName: String) async throws -> SpeakerVolumeStatus {
        try await volumeService.groupStatus(coordinatorRoomName: coordinatorRoomName)
    }

    public func setGroupVolume(coordinatorRoomName: String, volume: Int) async throws -> Int {
        try await volumeService.setGroupVolume(coordinatorRoomName: coordinatorRoomName, volume: volume)
    }

    public func toggleGroupMute(coordinatorRoomName: String) async throws -> Bool {
        try await volumeService.toggleGroupMute(coordinatorRoomName: coordinatorRoomName)
    }

    public func setGroupMute(coordinatorRoomName: String, muted: Bool) async throws -> Bool {
        try await volumeService.setGroupMute(coordinatorRoomName: coordinatorRoomName, muted: muted)
    }

    public func activePlaybackDeviceStatus() async throws -> SpotifyPlaybackDeviceStatus? {
        try await spotifyBridge.activePlaybackDeviceStatus()
    }

    public func availablePlaybackDevices() async throws -> [SpotifyAvailablePlaybackDevice] {
        try await spotifyBridge.availablePlaybackDevices()
    }

    public func startActivePlayback(
        spotifyURI: String? = nil,
        deviceName: String? = nil,
        deviceType: String? = nil
    ) async throws {
        try await spotifyBridge.startPlayback(
            spotifyURI: spotifyURI,
            deviceName: deviceName,
            deviceType: deviceType
        )
    }

    public func transferActivePlayback(
        deviceName: String? = nil,
        deviceType: String? = nil,
        play: Bool = true
    ) async throws {
        try await spotifyBridge.transferPlayback(
            deviceName: deviceName,
            deviceType: deviceType,
            play: play
        )
    }

    public func setActivePlaybackDeviceVolume(_ volume: Int) async throws -> Int {
        try await spotifyBridge.setActivePlaybackDeviceVolume(volume)
    }

    public func sendActivePlaybackCommand(_ command: SpotifyPlaybackCommand) async throws {
        try await spotifyBridge.sendPlaybackCommand(command)
    }

    public func sonosTransportStatus(roomName: String) async throws -> (currentURI: String, transportState: String) {
        let target = try await directory.resolveTarget(named: roomName, needsSpotifyMetadata: false)

        return try await avTransport.status(on: target)
    }
}
