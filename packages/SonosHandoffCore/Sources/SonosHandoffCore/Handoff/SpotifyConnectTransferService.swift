import Foundation

final class SpotifyConnectTransferService: @unchecked Sendable {
    private let directory: SonosDirectory
    private let spotifyBridge: SpotifyConnectBridge
    private let zeroconfClient: SonosSpotifyZeroconfClient
    private let transferVerifier: SonosTransferVerifier
    private let coordinatorMigrationTransferVerifier: SonosTransferVerifier
    private let connectOnlyTransferVerifier: SonosTransferVerifier

    init(
        directory: SonosDirectory,
        spotifyBridge: SpotifyConnectBridge,
        zeroconfClient: SonosSpotifyZeroconfClient,
        transferVerifier: SonosTransferVerifier,
        coordinatorMigrationTransferVerifier: SonosTransferVerifier,
        connectOnlyTransferVerifier: SonosTransferVerifier
    ) {
        self.directory = directory
        self.spotifyBridge = spotifyBridge
        self.zeroconfClient = zeroconfClient
        self.transferVerifier = transferVerifier
        self.coordinatorMigrationTransferVerifier = coordinatorMigrationTransferVerifier
        self.connectOnlyTransferVerifier = connectOnlyTransferVerifier
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
            let status = response["status"] as? Int
            throw ConnectHandoffError(.transferVerificationFailed, "Sonos Spotify Connect activation failed (status \(status.map(String.init) ?? "unknown")).")
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
        switch verification {
        case .connectOnly:
            return
        case .coordinatorMigration:
            _ = try await verifier.playAndVerifyReadiness(on: target)
        case .full:
            switch try await verifier.playAndVerifyReadiness(on: target) {
            case .transportStarted:
                await spotifyBridge.verifyActiveDeviceIfAvailable(named: roomName)
            case .spotifyConnectModeOnly:
                _ = try await spotifyBridge.verifyActiveDevice(named: roomName)
            }
        }
    }

    private func transferVerifier(for verification: RoomHandoffVerificationMode) -> SonosTransferVerifier {
        switch verification {
        case .full:
            return transferVerifier
        case .coordinatorMigration:
            return coordinatorMigrationTransferVerifier
        case .connectOnly:
            return connectOnlyTransferVerifier
        }
    }
}
