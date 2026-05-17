import Foundation

final class SpotifyConnectTransferService: @unchecked Sendable {
    private let directory: SonosDirectory
    private let spotifyBridge: SpotifyConnectBridge
    private let spotifyPlayback: SpotifyPlaybackService
    private let zeroconfClient: SonosSpotifyZeroconfClient
    private let transferVerifier: SonosTransferVerifier
    private let coordinatorMigrationTransferVerifier: SonosTransferVerifier

    init(
        directory: SonosDirectory,
        spotifyBridge: SpotifyConnectBridge,
        spotifyPlayback: SpotifyPlaybackService,
        zeroconfClient: SonosSpotifyZeroconfClient,
        transferVerifier: SonosTransferVerifier,
        coordinatorMigrationTransferVerifier: SonosTransferVerifier
    ) {
        self.directory = directory
        self.spotifyBridge = spotifyBridge
        self.spotifyPlayback = spotifyPlayback
        self.zeroconfClient = zeroconfClient
        self.transferVerifier = transferVerifier
        self.coordinatorMigrationTransferVerifier = coordinatorMigrationTransferVerifier
    }

    func transferToRoom(named roomName: String, verification: RoomHandoffVerificationMode) async throws {
        let target = try await directory.resolveTarget(named: roomName)
        guard let version = target.version else {
            throw ConnectHandoffError(.targetNotVisible, "Missing Spotify Connect version for \(roomName)")
        }

        let credential = try await spotifyBridge.refreshedDesktopCredential()
        let authorizationCode = try await spotifyBridge.spotifyConnectAuthorizationCode(from: credential.token.accessToken)
        let originDeviceName = "sonos-handoff-menu"
        let response = try await zeroconfClient.request(host: target.host, parameters: [
            "action": "addUser",
            "version": version,
            "tokenType": "authorization_code",
            "clientKey": "",
            "loginId": credential.loginID,
            "userName": credential.loginID,
            "blob": authorizationCode,
            "deviceName": originDeviceName,
            "deviceId": SonosRuntimeSupport.sha1Hex(originDeviceName),
        ])

        guard (response["status"] as? Int) == 101 else {
            throw ConnectHandoffError(.transferVerificationFailed, "Sonos Spotify Connect activation failed: \(response)")
        }

        try await verifyTransfer(to: target, roomName: roomName, verification: verification)
    }

    private func verifyTransfer(
        to target: ConnectSonosTarget,
        roomName: String,
        verification: RoomHandoffVerificationMode
    ) async throws {
        let verifier = transferVerifier(for: verification)
        try await verifier.waitForSpotifyConnectMode(on: target)
        let readiness = try await verifier.playAndVerifyReadiness(on: target)
        switch (verification, readiness) {
        case (.full, .transportStarted):
            await spotifyPlayback.verifyActiveDeviceIfAvailable(named: roomName)
        case (.full, .spotifyConnectModeOnly):
            _ = try await spotifyPlayback.verifyActiveDevice(named: roomName)
        case (.coordinatorMigration, .transportStarted):
            return
        case (.coordinatorMigration, .spotifyConnectModeOnly):
            _ = try await spotifyPlayback.verifyActiveDevice(named: roomName)
        }
    }

    private func transferVerifier(for verification: RoomHandoffVerificationMode) -> SonosTransferVerifier {
        switch verification {
        case .full:
            return transferVerifier
        case .coordinatorMigration:
            return coordinatorMigrationTransferVerifier
        }
    }
}
