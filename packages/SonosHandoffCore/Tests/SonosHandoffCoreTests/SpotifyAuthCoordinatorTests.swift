import Foundation
import Network
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SpotifyAuthCoordinatorTests {
    @Test
    func loginWritesProjectTokenWhenKeychainSaveSucceeds() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-auth-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SuccessfulSpotifyTokenURLProtocol.reset()
        }

        let callbackCapture = CallbackCapture()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SuccessfulSpotifyTokenURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)

        let coordinator = SpotifyAuthCoordinator(
            tokenStore: MockTokenStore(token: nil),
            configStore: MockConfigStore(config: AppConfig(spotifyClientID: "client-id")),
            urlSession: urlSession,
            applicationSupportDirectory: applicationSupportDirectory,
            browserOpener: { authorizationURL in
                Task {
                    await openSpotifyCallback(from: authorizationURL, callbackCapture: callbackCapture)
                }
                return true
            }
        )

        try await coordinator.login()

        let tokenURL = applicationSupportDirectory.appendingPathComponent("project-webapi-token.json")
        let tokenData = try Data(contentsOf: tokenURL)
        let token = try #require(JSONSerialization.jsonObject(with: tokenData) as? [String: Any])
        #expect(token["access_token"] as? String == "access-token")
        #expect(token["refresh_token"] as? String == "refresh-token")
        #expect(token["client_id"] as? String == "client-id")
        #expect(token["expires_at"] as? Int != nil)

        let callbackBody = await callbackCapture.waitForBody()
        #expect(callbackBody?.contains("Spotify sign-in completed.") == true)
        #expect(SuccessfulSpotifyTokenURLProtocol.recordedRequests().count == 2)
        let accountRequest = SuccessfulSpotifyTokenURLProtocol.recordedRequests().last
        #expect(accountRequest?.url?.absoluteString == "https://api.spotify.com/v1/me")
        #expect(accountRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    }

    @Test
    func loginRejectsTokenWithoutAccountProductBeforeSavingCredentials() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-auth-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SuccessfulSpotifyTokenURLProtocol.reset()
        }

        SuccessfulSpotifyTokenURLProtocol.setAccountResponse(#"{"type":"user"}"#)
        let tokenStore = RecordingTokenStore()
        let callbackCapture = CallbackCapture()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SuccessfulSpotifyTokenURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)

        let coordinator = SpotifyAuthCoordinator(
            tokenStore: tokenStore,
            configStore: MockConfigStore(config: AppConfig(spotifyClientID: "client-id")),
            urlSession: urlSession,
            applicationSupportDirectory: applicationSupportDirectory,
            browserOpener: { authorizationURL in
                Task {
                    await openSpotifyCallback(from: authorizationURL, callbackCapture: callbackCapture)
                }
                return true
            }
        )

        let missingProductError = SpotifyAuthError.tokenExchangeFailed(
            "Spotify account product is unavailable. Sign in again to approve the required account scope."
        )
        await #expect(throws: missingProductError) {
            try await coordinator.login()
        }

        let tokenURL = applicationSupportDirectory.appendingPathComponent("project-webapi-token.json")
        #expect(!FileManager.default.fileExists(atPath: tokenURL.path))
        #expect(tokenStore.savedTokens().isEmpty)

        let callbackBody = await callbackCapture.waitForBody()
        #expect(callbackBody?.contains("Spotify sign-in failed while saving the token.") == true)
    }

    @Test
    func loginRetriesCallbackPortWhenDefaultPortFailsAfterStart() async throws {
        let occupiedListener = try await occupyDefaultCallbackPort()
        defer {
            occupiedListener.cancel()
        }

        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-auth-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SuccessfulSpotifyTokenURLProtocol.reset()
        }

        let callbackCapture = CallbackCapture()
        let authorizationURLCapture = AuthorizationURLCapture()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SuccessfulSpotifyTokenURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)

        let coordinator = SpotifyAuthCoordinator(
            tokenStore: MockTokenStore(token: nil),
            configStore: MockConfigStore(config: AppConfig(spotifyClientID: "client-id")),
            urlSession: urlSession,
            applicationSupportDirectory: applicationSupportDirectory,
            browserOpener: { authorizationURL in
                Task {
                    await authorizationURLCapture.record(authorizationURL)
                    await openSpotifyCallback(from: authorizationURL, callbackCapture: callbackCapture)
                }
                return true
            }
        )

        try await coordinator.login()

        let redirectPort = try #require(await authorizationURLCapture.redirectPort())
        #expect(redirectPort != Int(SpotifyAuthCoordinator.callbackPorts[0]))
        #expect(SpotifyAuthCoordinator.callbackPorts.map(Int.init).contains(redirectPort))

        let callbackBody = await callbackCapture.waitForBody()
        #expect(callbackBody?.contains("Spotify sign-in completed.") == true)
    }

    @Test
    func loginAbortsBeforeProjectTokenWhenKeychainSaveFails() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-auth-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SuccessfulSpotifyTokenURLProtocol.reset()
        }

        let callbackCapture = CallbackCapture()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SuccessfulSpotifyTokenURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)

        let coordinator = SpotifyAuthCoordinator(
            tokenStore: FailingSaveTokenStore(),
            configStore: MockConfigStore(config: AppConfig(spotifyClientID: "client-id")),
            urlSession: urlSession,
            applicationSupportDirectory: applicationSupportDirectory,
            browserOpener: { authorizationURL in
                Task {
                    await openSpotifyCallback(from: authorizationURL, callbackCapture: callbackCapture)
                }
                return true
            }
        )

        await #expect(throws: SpotifyAuthError.refreshTokenKeychainSaveFailed) {
            try await coordinator.login()
        }

        let tokenURL = applicationSupportDirectory.appendingPathComponent("project-webapi-token.json")
        #expect(!FileManager.default.fileExists(atPath: tokenURL.path))

        let callbackBody = await callbackCapture.waitForBody()
        #expect(callbackBody?.contains("Spotify sign-in failed while saving the token.") == true)
    }
}

private final class SuccessfulSpotifyTokenURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorder = SpotifyAuthRequestRecorder()

    static func reset() {
        recorder.reset()
    }

    static func setAccountResponse(_ body: String, statusCode: Int = 200) {
        recorder.setAccountResponse(body, statusCode: statusCode)
    }

    static func recordedRequests() -> [URLRequest] {
        recorder.recordedRequests()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url == SpotifyEndpoints.tokenURL
            || request.url?.absoluteString == "https://api.spotify.com/v1/me"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request)
        let isAccountRequest = request.url?.absoluteString == "https://api.spotify.com/v1/me"
        let body = Data((isAccountRequest
            ? Self.recorder.accountResponse()
            : #"{"access_token":"access-token","refresh_token":"refresh-token"}"#).utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isAccountRequest ? Self.recorder.accountStatusCode() : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SpotifyAuthRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var accountResponseBody = #"{"product":"premium","type":"user"}"#
    private var accountResponseStatusCode = 200

    func reset() {
        lock.lock()
        requests = []
        accountResponseBody = #"{"product":"premium","type":"user"}"#
        accountResponseStatusCode = 200
        lock.unlock()
    }

    func setAccountResponse(_ body: String, statusCode: Int) {
        lock.lock()
        accountResponseBody = body
        accountResponseStatusCode = statusCode
        lock.unlock()
    }

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func accountResponse() -> String {
        lock.lock()
        defer { lock.unlock() }
        return accountResponseBody
    }

    func accountStatusCode() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return accountResponseStatusCode
    }
}

private final class RecordingTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []

    func saveRefreshToken(_ token: String) throws {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func loadRefreshToken() throws -> String? {
        nil
    }

    func deleteRefreshToken() throws {}

    func savedTokens() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }
}

private actor CallbackCapture {
    private var body: String?

    func setBody(_ body: String) {
        self.body = body
    }

    func waitForBody() async -> String? {
        for _ in 0 ..< 50 {
            if let body {
                return body
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return body
    }
}

private actor AuthorizationURLCapture {
    private var port: Int?

    func record(_ authorizationURL: URL) {
        guard
            let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
            let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
            let redirectURL = URL(string: redirectURI)
        else {
            return
        }

        port = redirectURL.port
    }

    func redirectPort() -> Int? {
        port
    }
}

private func openSpotifyCallback(from authorizationURL: URL, callbackCapture: CallbackCapture) async {
    guard
        let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
        let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
        let callbackURL = URL(string: "\(redirectURI)?code=authorization-code&state=\(state)")
    else {
        return
    }

    do {
        let (data, _) = try await URLSession.shared.data(from: callbackURL)
        await callbackCapture.setBody(String(data: data, encoding: .utf8) ?? "")
    } catch {
        await callbackCapture.setBody(error.localizedDescription)
    }
}

private func occupyDefaultCallbackPort() async throws -> NWListener {
    let defaultPort = NWEndpoint.Port(rawValue: SpotifyAuthCoordinator.callbackPorts[0])!
    let listener = try NWListener(using: .tcp, on: defaultPort)
    let queue = DispatchQueue(label: "keyway.spotify-auth-test-occupied-port")
    listener.newConnectionHandler = { connection in
        connection.cancel()
    }
    try await withCheckedThrowingContinuation { continuation in
        let gate = ListenerStartupGate(continuation: continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.resume(with: .success(()))
            case .failed(let error):
                gate.resume(with: .failure(error))
            default:
                break
            }
        }
        listener.start(queue: queue)
    }
    return listener
}

private final class ListenerStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
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
}
