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
    override class func canInit(with request: URLRequest) -> Bool {
        request.url == SpotifyEndpoints.tokenURL
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Data(#"{"access_token":"access-token","refresh_token":"refresh-token"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
