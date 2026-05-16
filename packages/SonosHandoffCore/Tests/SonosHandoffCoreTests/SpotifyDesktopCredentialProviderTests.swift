import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SpotifyDesktopCredentialProviderTests {
    @Test
    func selectsPreferredFreshDesktopCredentialWithoutNetworkRefresh() async throws {
        let directory = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            DesktopCredentialURLProtocol.reset()
        }

        try Self.writeDesktopTokens([
            "spotify/\(SpotifyConnectTokenClient.desktopClientID)/other-login": ConnectDesktopToken(
                accessToken: "other-access-token",
                refreshToken: "other-refresh-token",
                expiresAt: Int(Date().timeIntervalSince1970) + 3600
            ),
            "spotify/\(SpotifyConnectTokenClient.desktopClientID)/preferred-login": ConnectDesktopToken(
                accessToken: "preferred-access-token",
                refreshToken: "preferred-refresh-token",
                expiresAt: Int(Date().timeIntervalSince1970) + 3600
            ),
        ], to: directory)
        let provider = Self.provider(directory: directory, preferredLoginID: "preferred-login")

        let credential = try await provider.credential()

        #expect(credential.loginID == "preferred-login")
        #expect(credential.token.accessToken == "preferred-access-token")
        #expect(DesktopCredentialURLProtocol.recordedRequests().isEmpty)
    }

    @Test
    func refreshesExpiredDesktopCredentialAndPersistsReplacement() async throws {
        let directory = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            DesktopCredentialURLProtocol.reset()
        }

        let key = "spotify/\(SpotifyConnectTokenClient.desktopClientID)/preferred-login"
        try Self.writeDesktopTokens([
            key: ConnectDesktopToken(
                accessToken: "expired-access-token",
                refreshToken: "old-refresh-token",
                expiresAt: Int(Date().timeIntervalSince1970) - 1
            ),
        ], to: directory)
        DesktopCredentialURLProtocol.setRefreshResponse(
            #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":120}"#
        )
        let provider = Self.provider(directory: directory, preferredLoginID: "preferred-login")

        let credential = try await provider.credential()

        let savedTokens = try Self.readDesktopTokens(from: directory)
        let savedToken = try #require(savedTokens[key])
        #expect(credential.loginID == "preferred-login")
        #expect(credential.token.accessToken == "new-access-token")
        #expect(savedToken.accessToken == "new-access-token")
        #expect(savedToken.refreshToken == "new-refresh-token")
        #expect(DesktopCredentialURLProtocol.recordedRequests().count == 1)
    }

    @Test
    func rejectsMalformedDesktopTokenWithAppFacingAuthRecovery() async throws {
        let directory = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            DesktopCredentialURLProtocol.reset()
        }

        try Data("{not-json".utf8)
            .write(to: directory.appendingPathComponent("spotify-desktop-connect-tokens.json"))
        let provider = Self.provider(directory: directory, preferredLoginID: nil)

        do {
            _ = try await provider.credential()
            Issue.record("Expected malformed Desktop Connect token to require auth recovery.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .authRequired)
            #expect(error.message.contains("Sonos Handoff Settings"))
        } catch {
            Issue.record("Expected ConnectHandoffError, got \(error).")
        }

        #expect(DesktopCredentialURLProtocol.recordedRequests().isEmpty)
    }

    private static func provider(directory: URL, preferredLoginID: String?) -> SpotifyDesktopCredentialProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopCredentialURLProtocol.self]
        return SpotifyDesktopCredentialProvider(
            preferredLoginID: preferredLoginID,
            applicationSupportDirectory: directory,
            tokenClient: SpotifyConnectTokenClient(urlSession: URLSession(configuration: configuration))
        )
    }

    private static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-desktop-token-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func writeDesktopTokens(_ tokens: [String: ConnectDesktopToken], to directory: URL) throws {
        try JSONEncoder.pretty.encode(tokens)
            .write(to: directory.appendingPathComponent("spotify-desktop-connect-tokens.json"))
    }

    private static func readDesktopTokens(from directory: URL) throws -> [String: ConnectDesktopToken] {
        try JSONDecoder().decode(
            [String: ConnectDesktopToken].self,
            from: Data(contentsOf: directory.appendingPathComponent("spotify-desktop-connect-tokens.json"))
        )
    }
}

private final class DesktopCredentialURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorder = DesktopCredentialRequestRecorder()

    static func reset() {
        recorder.reset()
    }

    static func setRefreshResponse(_ body: String) {
        recorder.setRefreshResponse(body)
    }

    static func recordedRequests() -> [URLRequest] {
        recorder.recordedRequests()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.recorder.refreshResponse().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DesktopCredentialRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var response = #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600}"#

    func reset() {
        lock.lock()
        requests = []
        response = #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600}"#
        lock.unlock()
    }

    func setRefreshResponse(_ body: String) {
        lock.lock()
        response = body
        lock.unlock()
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func refreshResponse() -> String {
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}
