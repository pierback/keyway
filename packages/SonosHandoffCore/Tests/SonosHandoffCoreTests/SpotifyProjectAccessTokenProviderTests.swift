import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SpotifyProjectAccessTokenProviderTests {
    @Test
    func returnsCachedAccessTokenWhenTokenIsFresh() async throws {
        let directory = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ProjectAccessTokenURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "cached-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        let provider = Self.provider(directory: directory)

        let accessToken = try await provider.accessToken()

        #expect(accessToken == "cached-access-token")
        #expect(ProjectAccessTokenURLProtocol.recordedRequests().isEmpty)
    }

    @Test
    func refreshesExpiredTokenAndPersistsReplacement() async throws {
        let directory = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ProjectAccessTokenURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "expired-access-token",
            refreshToken: "old-refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) - 1
        ))
        ProjectAccessTokenURLProtocol.setRefreshResponse(
            #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":120}"#
        )
        let provider = Self.provider(directory: directory)

        let accessToken = try await provider.accessToken()

        let requests = ProjectAccessTokenURLProtocol.recordedRequests()
        let savedToken = try #require(try tokenStore.load())
        #expect(accessToken == "new-access-token")
        #expect(savedToken.accessToken == "new-access-token")
        #expect(savedToken.refreshToken == "new-refresh-token")
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "accounts.spotify.com")
    }

    @Test
    func deletesMalformedProjectTokenAndRequiresSignIn() async throws {
        let directory = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ProjectAccessTokenURLProtocol.reset()
        }

        try Data("""
        {
          "access_token": "access-token",
          "refresh_token": "refresh-token"
        }
        """.utf8)
            .write(to: directory.appendingPathComponent("project-webapi-token.json"))
        let provider = Self.provider(directory: directory)

        do {
            _ = try await provider.accessToken()
            Issue.record("Expected incomplete project token to require sign-in.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .authRequired)
            #expect(error.message.contains("sign in to Spotify again"))
        } catch {
            Issue.record("Expected ConnectHandoffError, got \(error).")
        }

        #expect(ProjectAccessTokenURLProtocol.recordedRequests().isEmpty)
        #expect(try ProjectWebAPITokenStore(applicationSupportDirectory: directory).load() == nil)
    }

    @Test
    func deletesProjectTokenWhenRefreshTokenIsRevoked() async throws {
        let directory = Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ProjectAccessTokenURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "expired-access-token",
            refreshToken: "revoked-refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) - 1
        ))
        ProjectAccessTokenURLProtocol.setRefreshResponse(
            #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#,
            statusCode: 400
        )
        let provider = Self.provider(directory: directory)

        do {
            _ = try await provider.accessToken()
            Issue.record("Expected revoked refresh token to require sign-in.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .authRequired)
        } catch {
            Issue.record("Expected ConnectHandoffError, got \(error).")
        }

        #expect(try tokenStore.load() == nil)
    }

    private static func provider(directory: URL) -> SpotifyProjectAccessTokenProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectAccessTokenURLProtocol.self]
        return SpotifyProjectAccessTokenProvider(
            applicationSupportDirectory: directory,
            tokenClient: SpotifyConnectTokenClient(urlSession: URLSession(configuration: configuration))
        )
    }

    private static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-project-token-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class ProjectAccessTokenURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorder = ProjectAccessTokenRequestRecorder()

    static func reset() {
        recorder.reset()
    }

    static func setRefreshResponse(_ body: String, statusCode: Int = 200) {
        recorder.setRefreshResponse(body, statusCode: statusCode)
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
            statusCode: Self.recorder.statusCode(),
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.recorder.refreshResponse().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProjectAccessTokenRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var response = #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600}"#
    private var responseStatusCode = 200

    func reset() {
        lock.lock()
        requests = []
        response = #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600}"#
        responseStatusCode = 200
        lock.unlock()
    }

    func setRefreshResponse(_ body: String, statusCode: Int) {
        lock.lock()
        response = body
        responseStatusCode = statusCode
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

    func statusCode() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return responseStatusCode
    }
}
