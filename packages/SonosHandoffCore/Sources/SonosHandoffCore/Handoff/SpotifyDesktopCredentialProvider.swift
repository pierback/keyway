import Foundation

struct SpotifyDesktopCredentialProvider: Sendable {
    private let preferredLoginID: String?
    private let desktopTokenURL: URL
    private let tokenClient: SpotifyConnectTokenClient
    private let tokenRefreshLeewaySeconds: Int

    private static let missingDesktopTokenMessage = "Spotify Desktop Connect token is missing. Open Keyway Settings to check token status before handoff."
    private static let malformedDesktopTokenMessage = "Spotify Desktop Connect token is unreadable. Open Keyway Settings to refresh token status before handoff."

    init(
        preferredLoginID: String?,
        applicationSupportDirectory: URL,
        tokenClient: SpotifyConnectTokenClient,
        tokenRefreshLeewaySeconds: Int = 120
    ) {
        let preferredLoginID = preferredLoginID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredLoginID = preferredLoginID?.isEmpty == false ? preferredLoginID : nil
        self.desktopTokenURL = applicationSupportDirectory.appendingPathComponent("spotify-desktop-connect-tokens.json")
        self.tokenClient = tokenClient
        self.tokenRefreshLeewaySeconds = tokenRefreshLeewaySeconds
    }

    func credential() async throws -> ConnectDesktopCredential {
        guard FileManager.default.fileExists(atPath: desktopTokenURL.path) else {
            throw ConnectHandoffError(.authRequired, Self.missingDesktopTokenMessage)
        }

        var tokens: [String: ConnectDesktopToken]
        do {
            tokens = try JSONDecoder().decode(
                [String: ConnectDesktopToken].self,
                from: ProjectWebAPITokenStore.sensitiveFileData(at: desktopTokenURL)
            )
        } catch {
            throw ConnectHandoffError(.authRequired, Self.malformedDesktopTokenMessage)
        }

        let selectedKey: String?
        if let preferredLoginID {
            selectedKey = tokens.keys.first { $0.contains("/\(SpotifyConnectTokenClient.desktopClientID)/\(preferredLoginID)") }
            guard selectedKey != nil else {
                throw ConnectHandoffError(.authRequired, "No Spotify Desktop streaming token found for login ID '\(preferredLoginID)'.")
            }
        } else {
            selectedKey = tokens.keys.sorted().first
        }

        guard let key = selectedKey,
              let loginID = SonosRuntimeSupport.loginID(fromDesktopTokenKey: key),
              var token = tokens[key]
        else {
            throw ConnectHandoffError(.authRequired, Self.missingDesktopTokenMessage)
        }

        if token.expiresAt > Int(Date().timeIntervalSince1970) + tokenRefreshLeewaySeconds {
            return ConnectDesktopCredential(loginID: loginID, token: token)
        }

        let refreshed = try await tokenClient.refreshedAccessToken(
            clientID: SpotifyConnectTokenClient.desktopClientID,
            refreshToken: token.refreshToken,
            failureMessage: "Spotify Desktop token refresh failed"
        )
        token.accessToken = refreshed.accessToken
        if let refreshToken = refreshed.refreshToken {
            token.refreshToken = refreshToken
        }
        token.expiresAt = Int(Date().timeIntervalSince1970) + refreshed.expiresIn
        tokens[key] = token
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ProjectWebAPITokenStore.writeSensitiveFileData(encoder.encode(tokens), to: desktopTokenURL)
        return ConnectDesktopCredential(loginID: loginID, token: token)
    }
}
