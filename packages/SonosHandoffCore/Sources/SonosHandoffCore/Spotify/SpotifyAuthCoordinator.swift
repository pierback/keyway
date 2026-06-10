import Foundation

public protocol SpotifyAuthCoordinating: Sendable {
    func login() async throws
}

public enum SpotifyAuthError: LocalizedError, Equatable {
    case missingClientID
    case couldNotOpenBrowser
    case callbackListenerFailed
    case callbackTimedOut
    case missingAuthorizationCode
    case invalidCallbackState
    case tokenExchangeFailed(String)
    case refreshTokenKeychainSaveFailed

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Spotify Client ID is required before signing in."
        case .couldNotOpenBrowser:
            return "Could not open the browser for Spotify sign-in."
        case .callbackListenerFailed:
            return "Could not start the local Spotify callback listener."
        case .callbackTimedOut:
            return "Spotify sign-in timed out before the browser callback completed."
        case .missingAuthorizationCode:
            return "Spotify did not return an authorization code."
        case .invalidCallbackState:
            return "Spotify sign-in returned an invalid state token."
        case .tokenExchangeFailed(let details):
            return "Spotify token exchange failed: \(details)"
        case .refreshTokenKeychainSaveFailed:
            return "Could not save Spotify credentials securely. Check Keychain access and try again."
        }
    }
}

public final class SpotifyAuthCoordinator: SpotifyAuthCoordinating, @unchecked Sendable {
    public static let callbackHost = SpotifyAuthCallbackServer.host
    public static let callbackPorts = SpotifyAuthCallbackServer.ports
    public static let callbackPath = SpotifyAuthCallbackServer.path

    private let tokenStore: TokenStoring
    private let configStore: ConfigStoring
    private let logger: Logger
    private let urlSession: URLSession
    private let browserOpener: @Sendable (URL) -> Bool
    private let projectTokenStore: ProjectWebAPITokenStore

    public init(
        tokenStore: TokenStoring,
        configStore: ConfigStoring,
        logger: Logger = Logger(),
        urlSession: URLSession = .shared,
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory,
        browserOpener: @escaping @Sendable (URL) -> Bool
    ) {
        self.tokenStore = tokenStore
        self.configStore = configStore
        self.logger = logger
        self.urlSession = urlSession
        self.projectTokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        self.browserOpener = browserOpener
    }

    public func login() async throws {
        let config = try configStore.load()
        guard let clientID = config.spotifyClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else {
            throw SpotifyAuthError.missingClientID
        }

        let authorizationRequest = SpotifyAuthorizationRequest(clientID: clientID)

        let browserOpener = browserOpener
        try await SpotifyAuthCallbackServer.completeAuthorization(expectedState: authorizationRequest.state, completion: { authorizationCode, redirectURI in
            let tokenResponse = try await self.exchangeCode(
                authorizationCode,
                clientID: clientID,
                redirectURI: redirectURI.absoluteString,
                codeVerifier: authorizationRequest.codeVerifier
            )

            try await self.validateAccountProduct(accessToken: tokenResponse.accessToken)

            do {
                try self.tokenStore.saveRefreshToken(tokenResponse.refreshToken)
            } catch {
                self.logger.log(.error, "Keychain refresh token save failed. Spotify sign-in aborted before writing token file.")
                throw SpotifyAuthError.refreshTokenKeychainSaveFailed
            }
            try self.projectTokenStore.save(ProjectWebAPIToken(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                clientID: clientID,
                expiresAt: tokenResponse.expiresAt
            ))
        }, openAuthorizationURL: { redirectURI in
            let authorizationURL = SpotifyAuthorizationRequest.authorizationURL(
                clientID: clientID,
                redirectURI: redirectURI.absoluteString,
                state: authorizationRequest.state,
                codeVerifier: authorizationRequest.codeVerifier
            )

            return browserOpener(authorizationURL)
        })
        logger.log(.info, "Spotify authentication completed.")
    }

    private func exchangeCode(
        _ code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> TokenExchangeResponse {
        var request = URLRequest(url: SpotifyEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAuthError.tokenExchangeFailed("Unexpected response.")
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw SpotifyAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(TokenExchangePayload.self, from: data)
        guard let refreshToken = payload.refreshToken, !refreshToken.isEmpty else {
            throw SpotifyAuthError.tokenExchangeFailed("Spotify did not return a refresh token.")
        }

        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw SpotifyAuthError.tokenExchangeFailed("Spotify did not return an access token.")
        }

        let expiresIn = max(payload.expiresIn ?? 3600, 60)
        return TokenExchangeResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Int(Date().timeIntervalSince1970) + expiresIn
        )
    }

    private func validateAccountProduct(accessToken: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAuthError.tokenExchangeFailed("Unexpected account response.")
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw SpotifyAuthError.tokenExchangeFailed("Spotify account check returned HTTP \(httpResponse.statusCode).")
        }

        let profile = try JSONDecoder().decode(SpotifyAccountProfile.self, from: data)
        guard profile.product?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw SpotifyAuthError.tokenExchangeFailed("Spotify account product is unavailable. Sign in again to approve the required account scope.")
        }
    }

    private static func formEncodedBody(_ parameters: [String: String]) -> Data {
        let value = parameters.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .sorted()
        .joined(separator: "&")

        return Data(value.utf8)
    }

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}

private struct SpotifyAccountProfile: Decodable {
    let product: String?
}

private struct TokenExchangePayload: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct TokenExchangeResponse {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
}
