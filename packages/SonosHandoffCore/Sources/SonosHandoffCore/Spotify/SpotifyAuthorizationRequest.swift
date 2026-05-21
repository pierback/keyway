import CryptoKit
import Foundation
import Security

struct SpotifyAuthorizationRequest: Sendable {
    let state: String
    let codeVerifier: String
    let redirectURI: URL
    let url: URL

    init(clientID: String) throws {
        try self.init(
            clientID: clientID,
            redirectURI: SpotifyAuthCallbackServer.redirectURI,
            state: Self.randomURLSafeString(length: 32),
            codeVerifier: Self.randomURLSafeString(length: 96)
        )
    }

    init(
        clientID: String,
        redirectURI: URL,
        state: String,
        codeVerifier: String
    ) throws {
        self.state = state
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
        self.url = try Self.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI.absoluteString,
            state: state,
            codeVerifier: codeVerifier
        )
    }

    static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeVerifier: String
    ) throws -> URL {
        var components = URLComponents(url: SpotifyEndpoints.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: SpotifyScopes.required.joined(separator: " ")),
        ]

        guard let url = components?.url else {
            throw SpotifyAuthError.couldNotOpenBrowser
        }

        return url
    }

    static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        guard status == errSecSuccess else {
            return String((0 ..< length).map { _ in alphabet.randomElement()! })
        }
        return String(randomBytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
