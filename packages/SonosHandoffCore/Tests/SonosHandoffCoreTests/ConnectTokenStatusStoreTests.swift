import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct ConnectTokenStatusStoreTests {
    @Test
    func validatedStatusRejectsUnusableDesktopToken() async throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ConnectTokenStatusURLProtocol.reset()
        }

        try Data(
            #"{"65b708073fc0480ea92a077233ca87bd/user":{"access_token":"","refresh_token":"refresh-token","expires_at":9999999999}}"#.utf8
        ).write(to: directory.appendingPathComponent("spotify-desktop-connect-tokens.json"))
        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        let store = ConnectTokenStatusStore(
            applicationSupportDirectory: directory,
            urlSession: Self.urlSession()
        )

        let status = try await store.validatedStatus()

        #expect(status.desktopTokenAvailable == false)
    }

    @Test
    func validatedStatusSurfacesMalformedDesktopTokenFile() async throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ConnectTokenStatusURLProtocol.reset()
        }

        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("spotify-desktop-connect-tokens.json"))
        let store = ConnectTokenStatusStore(
            applicationSupportDirectory: directory,
            urlSession: Self.urlSession()
        )

        await #expect(throws: DecodingError.self) {
            _ = try await store.validatedStatus()
        }
    }

    @Test
    func validatedStatusSurfacesSpotifyAccountServerFailure() async throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ConnectTokenStatusURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        ConnectTokenStatusURLProtocol.setAccountResponse(
            #"{"error":{"status":500,"message":"server error"}}"#,
            statusCode: 500
        )
        let store = ConnectTokenStatusStore(
            applicationSupportDirectory: directory,
            urlSession: Self.urlSession()
        )

        await #expect(throws: ConnectHandoffError.self) {
            _ = try await store.validatedStatus()
        }
    }

    @Test
    func validatedStatusRefreshesExpiredProjectToken() async throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ConnectTokenStatusURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) - 1
        ))
        ConnectTokenStatusURLProtocol.setResponse(
            #"{"access_token":"validated-access-token","expires_in":3600}"#
        )
        ConnectTokenStatusURLProtocol.setAccountResponse(
            #"{"product":"premium","type":"user"}"#
        )
        let store = ConnectTokenStatusStore(
            applicationSupportDirectory: directory,
            urlSession: Self.urlSession()
        )

        let status = try await store.validatedStatus()
        let savedToken = try #require(try tokenStore.load())

        #expect(status.projectTokenAvailable == true)
        #expect(savedToken.accessToken == "validated-access-token")
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().count == 2)
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().last?.url?.absoluteString == "https://api.spotify.com/v1/me")
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer validated-access-token")
    }

    @Test
    func validatedStatusRefreshesServerRejectedAccessToken() async throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ConnectTokenStatusURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "rejected-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        ConnectTokenStatusURLProtocol.setResponse(
            #"{"access_token":"validated-access-token","expires_in":3600}"#
        )
        ConnectTokenStatusURLProtocol.setAccountResponses([
            (#"{"error":{"status":401,"message":"expired"}}"#, 401),
            (#"{"product":"premium","type":"user"}"#, 200),
        ])
        let store = ConnectTokenStatusStore(
            applicationSupportDirectory: directory,
            urlSession: Self.urlSession()
        )

        let status = try await store.validatedStatus()
        let requests = ConnectTokenStatusURLProtocol.recordedRequests()

        #expect(status.projectTokenAvailable)
        #expect(requests.map(\.url?.absoluteString) == [
            "https://api.spotify.com/v1/me",
            "https://accounts.spotify.com/api/token",
            "https://api.spotify.com/v1/me",
        ])
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer validated-access-token")
    }

    @Test
    func validatedStatusRejectsProjectTokenWithoutAccountProduct() async throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ConnectTokenStatusURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "under-scoped-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        ConnectTokenStatusURLProtocol.setAccountResponse(
            #"{"type":"user"}"#
        )
        let store = ConnectTokenStatusStore(
            applicationSupportDirectory: directory,
            urlSession: Self.urlSession()
        )

        let status = try await store.validatedStatus()

        #expect(status.projectTokenAvailable == false)
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().count == 1)
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().first?.url?.absoluteString == "https://api.spotify.com/v1/me")
    }

    @Test
    func validatedStatusRejectsRevokedProjectRefreshToken() async throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            ConnectTokenStatusURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "expired-access-token",
            refreshToken: "revoked-refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) - 1
        ))
        ConnectTokenStatusURLProtocol.setResponse(
            #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#,
            statusCode: 400
        )
        let store = ConnectTokenStatusStore(
            applicationSupportDirectory: directory,
            urlSession: Self.urlSession()
        )

        let status = try await store.validatedStatus()

        #expect(status.projectTokenAvailable == false)
        #expect(try tokenStore.load() == nil)
    }

    private func temporaryApplicationSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-token-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func urlSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectTokenStatusURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ConnectTokenStatusURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorder = ConnectTokenStatusRequestRecorder()

    static func reset() {
        recorder.reset()
    }

    static func setResponse(_ body: String, statusCode: Int = 200) {
        recorder.setResponse(body, statusCode: statusCode)
    }

    static func setAccountResponse(_ body: String, statusCode: Int = 200) {
        recorder.setAccountResponse(body, statusCode: statusCode)
    }

    static func setAccountResponses(_ responses: [(String, Int)]) {
        recorder.setAccountResponses(responses)
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
        let isAccountRequest = request.url?.absoluteString == "https://api.spotify.com/v1/me"
        let accountResponse = isAccountRequest ? Self.recorder.nextAccountResponse() : nil
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: accountResponse?.1 ?? Self.recorder.statusCode(),
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((accountResponse?.0 ?? Self.recorder.response()).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ConnectTokenStatusRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var responseBody = #"{"access_token":"validated-access-token","expires_in":3600}"#
    private var responseStatusCode = 200
    private var accountResponses = [(#"{"product":"premium","type":"user"}"#, 200)]

    func reset() {
        lock.lock()
        requests = []
        responseBody = #"{"access_token":"validated-access-token","expires_in":3600}"#
        responseStatusCode = 200
        accountResponses = [(#"{"product":"premium","type":"user"}"#, 200)]
        lock.unlock()
    }

    func setResponse(_ body: String, statusCode: Int) {
        lock.lock()
        responseBody = body
        responseStatusCode = statusCode
        lock.unlock()
    }

    func setAccountResponse(_ body: String, statusCode: Int) {
        setAccountResponses([(body, statusCode)])
    }

    func setAccountResponses(_ responses: [(String, Int)]) {
        lock.lock()
        accountResponses = responses
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

    func response() -> String {
        lock.lock()
        defer { lock.unlock() }
        return responseBody
    }

    func statusCode() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return responseStatusCode
    }

    func nextAccountResponse() -> (String, Int) {
        lock.lock()
        defer { lock.unlock() }
        return accountResponses.count == 1 ? accountResponses[0] : accountResponses.removeFirst()
    }
}
