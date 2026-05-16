import Foundation

final class SpotifyConnectTransferService: @unchecked Sendable {
    private let directory: SonosDirectory
    private let spotifyBridge: SpotifyConnectBridge
    private let spotifyPlayback: SpotifyPlaybackService
    private let zeroconfClient: SonosSpotifyZeroconfClient
    private let transferVerifier: SonosTransferVerifier

    init(
        directory: SonosDirectory,
        spotifyBridge: SpotifyConnectBridge,
        spotifyPlayback: SpotifyPlaybackService,
        zeroconfClient: SonosSpotifyZeroconfClient,
        transferVerifier: SonosTransferVerifier
    ) {
        self.directory = directory
        self.spotifyBridge = spotifyBridge
        self.spotifyPlayback = spotifyPlayback
        self.zeroconfClient = zeroconfClient
        self.transferVerifier = transferVerifier
    }

    func transferToRoom(named roomName: String) async throws {
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

        try await transferVerifier.waitForSpotifyConnectMode(on: target)
        let readiness = try await transferVerifier.playAndVerifyReadiness(on: target)
        switch readiness {
        case .transportStarted:
            await spotifyPlayback.verifyActiveDeviceIfAvailable(named: roomName)
        case .spotifyConnectModeOnly:
            _ = try await spotifyPlayback.verifyActiveDevice(named: roomName)
        }
    }
}
