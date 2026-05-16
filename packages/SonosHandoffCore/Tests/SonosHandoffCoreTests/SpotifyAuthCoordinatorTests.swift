import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SpotifyAuthCoordinatorTests {
    @Test
    func loginWritesProjectTokenEvenWhenKeychainSaveFails() async throws {
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
