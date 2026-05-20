import Foundation

struct SpotifyProjectAccessTokenProvider: Sendable {
    private let tokenStore: ProjectWebAPITokenStore
    private let tokenClient: SpotifyConnectTokenClient
    private let tokenRefreshLeewaySeconds: Int

    private static let missingWebAPITokenMessage = "Spotify Web API sign-in is missing. Open Keyway Settings and sign in to Spotify again."
    private static let incompleteWebAPITokenMessage = "Spotify Web API sign-in is incomplete. Open Keyway Settings and sign in to Spotify again."

    init(
        applicationSupportDirectory: URL,
        tokenClient: SpotifyConnectTokenClient,
        tokenRefreshLeewaySeconds: Int = 120
    ) {
        self.tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        self.tokenClient = tokenClient
        self.tokenRefreshLeewaySeconds = tokenRefreshLeewaySeconds
    }

    func accessToken() async throws -> String {
        try await accessToken(forceRefresh: false)
    }

    func refreshAccessTokenAfterAuthFailure() async throws -> String {
        try await accessToken(forceRefresh: true)
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        let loadedToken: ProjectWebAPIToken?
        do {
            loadedToken = try tokenStore.load()
        } catch {
            try? tokenStore.delete()
            throw ConnectHandoffError(.authRequired, Self.incompleteWebAPITokenMessage)
        }

        guard var token = loadedToken else {
            throw ConnectHandoffError(.authRequired, Self.missingWebAPITokenMessage)
        }

        guard token.hasCredentials else {
            throw ConnectHandoffError(.authRequired, Self.incompleteWebAPITokenMessage)
        }

        if !forceRefresh,
           let expiresAt = token.expiresAt,
           expiresAt > Int(Date().timeIntervalSince1970) + tokenRefreshLeewaySeconds {
            return token.accessToken
        }

        let refreshed: SpotifyRefreshedAccessToken
        do {
            refreshed = try await tokenClient.refreshedAccessToken(
                clientID: token.clientID,
                refreshToken: token.refreshToken,
                failureMessage: "Spotify Web API token refresh failed"
            )
        } catch let error as ConnectHandoffError where error.code == .authRequired {
            try? tokenStore.delete()
            throw ConnectHandoffError(.authRequired, Self.missingWebAPITokenMessage)
        }
        token.accessToken = refreshed.accessToken
        if let refreshToken = refreshed.refreshToken {
            token.refreshToken = refreshToken
        }
        token.expiresAt = Int(Date().timeIntervalSince1970) + refreshed.expiresIn
        try tokenStore.save(token)
        return token.accessToken
    }
}
