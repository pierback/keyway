import AppKit
import CryptoKit
import Foundation
import Network

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
        }
    }
}

public final class SpotifyAuthCoordinator: SpotifyAuthCoordinating, @unchecked Sendable {
    public static let callbackHost = "127.0.0.1"
    public static let callbackPort: UInt16 = 43821
    public static let callbackPath = "/callback"

    private let tokenStore: TokenStoring
    private let configStore: ConfigStoring
    private let logger: Logger
    private let urlSession: URLSession
    private let browserOpener: @Sendable (URL) -> Bool
    private let applicationSupportDirectory: URL

    public init(
        tokenStore: TokenStoring,
        configStore: ConfigStoring,
        logger: Logger = Logger(),
        urlSession: URLSession = .shared,
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory,
        browserOpener: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.tokenStore = tokenStore
        self.configStore = configStore
        self.logger = logger
        self.urlSession = urlSession
        self.applicationSupportDirectory = applicationSupportDirectory
        self.browserOpener = browserOpener
    }

    public func login() async throws {
        let config = try configStore.load()
        guard let clientID = config.spotifyClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else {
            throw SpotifyAuthError.missingClientID
        }

        let state = Self.randomURLSafeString(length: 32)
        let codeVerifier = Self.randomURLSafeString(length: 96)
        let redirectURI = Self.redirectURI.absoluteString
        let authorizationURL = try Self.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: codeVerifier
        )

        let browserOpener = browserOpener
        try await Self.completeAuthorizationFromCallback(expectedState: state, completion: { authorizationCode in
            let tokenResponse = try await self.exchangeCode(
                authorizationCode,
                clientID: clientID,
                redirectURI: redirectURI,
                codeVerifier: codeVerifier
            )

            try self.saveProjectWebAPIToken(tokenResponse, clientID: clientID)
            do {
                try self.tokenStore.saveRefreshToken(tokenResponse.refreshToken)
            } catch {
                self.logger.log(.warning, "Spotify Web API token file saved, but Keychain refresh token save failed.")
            }
        }, openAuthorizationURL: {
            browserOpener(authorizationURL)
        })
        logger.log(.info, "Spotify authentication completed.")
    }

    private func saveProjectWebAPIToken(_ tokenResponse: TokenExchangeResponse, clientID: String) throws {
        let token = ProjectWebAPIToken(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            clientID: clientID
        )
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder.spotifyTokenFile.encode(token)
            .write(to: applicationSupportDirectory.appendingPathComponent("project-webapi-token.json"), options: .atomic)
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
            let details = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SpotifyAuthError.tokenExchangeFailed(details)
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(TokenExchangePayload.self, from: data)
        guard let refreshToken = payload.refreshToken, !refreshToken.isEmpty else {
            throw SpotifyAuthError.tokenExchangeFailed("Spotify did not return a refresh token.")
        }

        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw SpotifyAuthError.tokenExchangeFailed("Spotify did not return an access token.")
        }

        return TokenExchangeResponse(accessToken: accessToken, refreshToken: refreshToken)
    }

    private static func completeAuthorizationFromCallback(
        expectedState: String,
        completion: @escaping @Sendable (String) async throws -> Void,
        openAuthorizationURL: @escaping @Sendable () -> Bool
    ) async throws {
        guard let port = NWEndpoint.Port(rawValue: callbackPort) else {
            throw SpotifyAuthError.callbackListenerFailed
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            throw SpotifyAuthError.callbackListenerFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "sonos-handoff.spotify-auth")
            let resolver = CallbackResolver(
                expectedState: expectedState,
                continuation: continuation,
                completion: completion
            )
            let browser = OneShotBrowserOpener(openAuthorizationURL)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let didOpen = browser.openOnce() else {
                        return
                    }
                    guard didOpen else {
                        resolver.finish(with: .failure(SpotifyAuthError.couldNotOpenBrowser))
                        listener.cancel()
                        return
                    }
                case .failed:
                    resolver.finish(with: .failure(SpotifyAuthError.callbackListenerFailed))
                    listener.cancel()
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                resolver.handle(connection: connection, listener: listener)
            }

            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(120)) {
                resolver.finish(with: .failure(SpotifyAuthError.callbackTimedOut))
                listener.cancel()
            }
        }
    }

    private static func authorizationURL(
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

    private static var redirectURI: URL {
        URL(string: "http://\(callbackHost):\(callbackPort)\(callbackPath)")!
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0 ..< length).map { _ in alphabet.randomElement()! })
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

private final class OneShotBrowserOpener: @unchecked Sendable {
    private let opener: @Sendable () -> Bool
    private let lock = NSLock()
    private var didOpen = false

    init(_ opener: @escaping @Sendable () -> Bool) {
        self.opener = opener
    }

    func openOnce() -> Bool? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !didOpen else {
            return nil
        }

        didOpen = true
        return opener()
    }
}

private struct TokenExchangePayload: Decodable {
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct TokenExchangeResponse {
    let accessToken: String
    let refreshToken: String
}

private struct ProjectWebAPIToken: Encodable {
    let accessToken: String
    let refreshToken: String
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
    }
}

private extension JSONEncoder {
    static var spotifyTokenFile: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private final class CallbackResolver: @unchecked Sendable {
    private let expectedState: String
    private let completion: @Sendable (String) async throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(
        expectedState: String,
        continuation: CheckedContinuation<Void, Error>,
        completion: @escaping @Sendable (String) async throws -> Void
    ) {
        self.expectedState = expectedState
        self.continuation = continuation
        self.completion = completion
    }

    func handle(connection: NWConnection, listener: NWListener) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                self.finish(with: .failure(SpotifyAuthError.callbackListenerFailed))
                listener.cancel()
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, _, error in
            if let error {
                self.finish(with: .failure(error))
                connection.cancel()
                listener.cancel()
                return
            }

            guard
                let data,
                let request = String(data: data, encoding: .utf8),
                let requestLine = request.components(separatedBy: "\r\n").first
            else {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed before an authorization code was received. You can close this window.",
                    result: .failure(SpotifyAuthError.missingAuthorizationCode)
                )
                return
            }

            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed before an authorization code was received. You can close this window.",
                    result: .failure(SpotifyAuthError.missingAuthorizationCode)
                )
                return
            }

            let path = String(parts[1])
            guard let components = URLComponents(string: "http://\(SpotifyAuthCoordinator.callbackHost):\(SpotifyAuthCoordinator.callbackPort)\(path)") else {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed before an authorization code was received. You can close this window.",
                    result: .failure(SpotifyAuthError.missingAuthorizationCode)
                )
                return
            }

            let queryItems = components.queryItems ?? []
            let code = queryItems.first(where: { $0.name == "code" })?.value
            let state = queryItems.first(where: { $0.name == "state" })?.value

            if state != self.expectedState {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed because the callback state did not match. You can close this window.",
                    result: .failure(SpotifyAuthError.invalidCallbackState)
                )
                return
            }

            guard let code, !code.isEmpty else {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed because Spotify did not return an authorization code. You can close this window.",
                    result: .failure(SpotifyAuthError.missingAuthorizationCode)
                )
                return
            }

            Task {
                do {
                    try await self.completion(code)
                    self.sendResponse(
                        connection: connection,
                        listener: listener,
                        body: "Spotify sign-in completed. You can close this window and return to sonos-handoff.",
                        result: .success(())
                    )
                } catch {
                    self.sendResponse(
                        connection: connection,
                        listener: listener,
                        body: "Spotify sign-in failed while saving the token. You can close this window and try again from sonos-handoff.",
                        result: .failure(error)
                    )
                }
            }
        }
    }

    func finish(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else {
            return
        }

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func sendResponse(
        connection: NWConnection,
        listener: NWListener,
        body: String,
        result: Result<Void, Error>
    ) {
        let response = Self.httpResponse(body: body)
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            listener.cancel()
            self.finish(with: result)
        })
    }

    private static func httpResponse(body: String) -> String {
        """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
    }
}
