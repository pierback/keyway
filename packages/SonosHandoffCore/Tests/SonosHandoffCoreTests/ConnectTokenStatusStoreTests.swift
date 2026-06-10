import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct ConnectTokenStatusStoreTests {
    @Test
    func statusRejectsStaleProjectTokenWithoutClientID() throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try Data(#"{"access_token":"access-token","refresh_token":"refresh-token","client_id":null}"#.utf8)
            .write(to: directory.appendingPathComponent("project-webapi-token.json"))

        let status = ConnectTokenStatusStore(applicationSupportDirectory: directory).status()

        #expect(status.projectTokenAvailable == false)
    }

    @Test
    func statusRejectsProjectTokenWithoutExpiry() throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try Data(#"{"access_token":"access-token","refresh_token":"refresh-token","client_id":"client-id"}"#.utf8)
            .write(to: directory.appendingPathComponent("project-webapi-token.json"))

        let status = ConnectTokenStatusStore(applicationSupportDirectory: directory).status()

        #expect(status.projectTokenAvailable == false)
    }

    @Test
    func statusAcceptsCompleteProjectToken() throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try Data(#"{"access_token":"access-token","refresh_token":"refresh-token","client_id":"client-id","expires_at":9999999999}"#.utf8)
            .write(to: directory.appendingPathComponent("project-webapi-token.json"))

        let status = ConnectTokenStatusStore(applicationSupportDirectory: directory).status()

        #expect(status.projectTokenAvailable == true)
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

        let status = await store.validatedStatus()
        let savedToken = try #require(try tokenStore.load())

        #expect(status.projectTokenAvailable == true)
        #expect(savedToken.accessToken == "validated-access-token")
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().count == 2)
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().last?.url?.absoluteString == "https://api.spotify.com/v1/me")
        #expect(ConnectTokenStatusURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer validated-access-token")
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

        let status = await store.validatedStatus()

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

        let status = await store.validatedStatus()

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
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isAccountRequest ? Self.recorder.accountStatusCode() : Self.recorder.statusCode(),
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((isAccountRequest ? Self.recorder.accountResponse() : Self.recorder.response()).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ConnectTokenStatusRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var responseBody = #"{"access_token":"validated-access-token","expires_in":3600}"#
    private var responseStatusCode = 200
    private var accountResponseBody = #"{"product":"premium","type":"user"}"#
    private var accountResponseStatusCode = 200

    func reset() {
        lock.lock()
        requests = []
        responseBody = #"{"access_token":"validated-access-token","expires_in":3600}"#
        responseStatusCode = 200
        accountResponseBody = #"{"product":"premium","type":"user"}"#
        accountResponseStatusCode = 200
        lock.unlock()
    }

    func setResponse(_ body: String, statusCode: Int) {
        lock.lock()
        responseBody = body
        responseStatusCode = statusCode
        lock.unlock()
    }

    func setAccountResponse(_ body: String, statusCode: Int) {
        lock.lock()
        accountResponseBody = body
        accountResponseStatusCode = statusCode
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
