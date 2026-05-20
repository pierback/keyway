import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SpotifyConnectBridgeTests {
    @Test
    func missingDesktopTokenUsesAppFacingRecoveryMessage() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: .ephemeral)
        )

        do {
            _ = try await bridge.refreshedDesktopCredential()
            Issue.record("Expected missing Desktop Connect token to require Spotify authentication.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .authRequired)
            #expect(error.message.contains("Keyway Settings"))
            #expect(!error.message.localizedCaseInsensitiveContains("CLI"))
        }
    }

    @Test
    func volumeMirrorReusesUnexpiredProjectToken() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let expiresAt = Int(Date().timeIntervalSince1970) + 3600
        try Data("""
        {
          "access_token": "cached-access-token",
          "refresh_token": "refresh-token",
          "client_id": "client-id",
          "expires_at": \(expiresAt)
        }
        """.utf8)
            .write(to: applicationSupportDirectory.appendingPathComponent("project-webapi-token.json"))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        await bridge.setActiveDeviceVolumeIfNeeded(roomName: "Port", volume: 42)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(urls.contains { $0.path == "/v1/me/player/volume" })
        #expect(!urls.contains { $0.host == "accounts.spotify.com" })
    }

    @Test
    func volumeMirrorRefreshesExpiredProjectTokenThroughSharedStore() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) - 10
        ))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        await bridge.setActiveDeviceVolumeIfNeeded(roomName: "Port", volume: 42)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(urls.contains { $0.host == "accounts.spotify.com" && $0.path == "/api/token" })
        #expect(try tokenStore.load()?.accessToken == "refreshed-access-token")
    }

    @Test
    func volumeMirrorWaitsForTransferredRoomToBecomeActiveDevice() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "cached-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        SpotifyBridgeURLProtocol.setPlayerResponses([
            .success(deviceName: "This computer"),
            .noActivePlayback,
            .success(deviceName: "Port"),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        await bridge.setActiveDeviceVolumeIfNeeded(roomName: "Port", volume: 42)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(urls.filter { $0.path == "/v1/me/player" }.count == 3)
        #expect(urls.contains { $0.path == "/v1/me/player/volume" })
    }

    @Test
    func volumeMirrorReportsActiveDeviceMismatchWithoutWritingVolume() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "cached-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        SpotifyBridgeURLProtocol.setPlayerResponses(Array(
            repeating: .success(deviceName: "This computer"),
            count: 6
        ))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        let result = await bridge.setActiveDeviceVolumeIfNeeded(roomName: "Port", volume: 42)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(result == .skipped(.activeDeviceMismatch(lastDeviceName: "This computer")))
        #expect(urls.filter { $0.path == "/v1/me/player" }.count == 6)
        #expect(!urls.contains { $0.path == "/v1/me/player/volume" })
    }

    @Test
    func volumeMirrorReportsRestrictedDeviceWithoutWritingVolume() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "cached-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        SpotifyBridgeURLProtocol.setPlayerResponses([
            .success(deviceName: "Port", restricted: true),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        let result = await bridge.setActiveDeviceVolumeIfNeeded(roomName: "Port", volume: 42)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(result == .skipped(.restrictedDevice(deviceName: "Port")))
        #expect(!urls.contains { $0.path == "/v1/me/player/volume" })
    }

    @Test
    func activePlaybackDeviceStatusReadsCurrentSpotifyDevice() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "cached-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        SpotifyBridgeURLProtocol.setPlayerResponses([
            .success(deviceName: "Kitchen", volumePercent: 37),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        let status = try await bridge.activePlaybackDeviceStatus()

        #expect(status == SpotifyPlaybackDeviceStatus(deviceName: "Kitchen", isPlaying: true, volumePercent: 37))
    }

    @Test
    func activePlaybackDeviceStatusRefreshesRejectedCachedToken() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "rejected-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        SpotifyBridgeURLProtocol.setPlayerResponses([
            .unauthorized,
            .success(deviceName: "Kitchen", volumePercent: 37),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        let status = try await bridge.activePlaybackDeviceStatus()

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(status == SpotifyPlaybackDeviceStatus(deviceName: "Kitchen", isPlaying: true, volumePercent: 37))
        #expect(urls.contains { $0.host == "accounts.spotify.com" && $0.path == "/api/token" })
        #expect(try tokenStore.load()?.accessToken == "refreshed-access-token")
    }

    @Test
    func activePlaybackDeviceStatusReturnsNilWithoutActivePlayback() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: applicationSupportDirectory)
            SpotifyBridgeURLProtocol.reset()
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let tokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        try tokenStore.save(ProjectWebAPIToken(
            accessToken: "cached-access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        ))
        SpotifyBridgeURLProtocol.setPlayerResponses([.noActivePlayback])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        let status = try await bridge.activePlaybackDeviceStatus()

        #expect(status == nil)
    }
}

private final class SpotifyBridgeURLProtocol: URLProtocol, @unchecked Sendable {
    struct PlayerResponse: Sendable {
        let statusCode: Int
        let body: String

        static func success(deviceName: String, restricted: Bool = false, volumePercent: Int = 42) -> PlayerResponse {
            PlayerResponse(
                statusCode: 200,
                body: #"{"is_playing":true,"device":{"name":"\#(deviceName)","is_restricted":\#(restricted),"volume_percent":\#(volumePercent)}}"#
            )
        }

        static let noActivePlayback = PlayerResponse(statusCode: 204, body: "")
        static let unauthorized = PlayerResponse(statusCode: 401, body: #"{"error":"invalid_token"}"#)
    }

    private static let recorder = SpotifyBridgeURLRecorder()

    static func reset() {
        recorder.reset()
    }

    static func setPlayerResponses(_ responses: [PlayerResponse]) {
        recorder.setPlayerResponses(responses)
    }

    static func recordedURLs() -> [URL] {
        recorder.recordedURLs()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.recorder.record(url)

        switch (url.host, url.path) {
        case ("api.spotify.com", "/v1/me/player"):
            let response = Self.recorder.nextPlayerResponse()
            respond(statusCode: response.statusCode, body: response.body)
        case ("api.spotify.com", "/v1/me/player/volume"):
            respond(statusCode: 204, body: "")
        case ("accounts.spotify.com", "/api/token"):
            respond(
                statusCode: 200,
                body: #"{"access_token":"refreshed-access-token","refresh_token":"refresh-token","expires_in":3600}"#
            )
        default:
            respond(statusCode: 404, body: "{}")
        }
    }

    override func stopLoading() {}

    private func respond(statusCode: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SpotifyBridgeURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var playerResponses: [SpotifyBridgeURLProtocol.PlayerResponse] = []

    func reset() {
        lock.lock()
        urls = []
        playerResponses = []
        lock.unlock()
    }

    func setPlayerResponses(_ responses: [SpotifyBridgeURLProtocol.PlayerResponse]) {
        lock.lock()
        playerResponses = responses
        lock.unlock()
    }

    func recordedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func nextPlayerResponse() -> SpotifyBridgeURLProtocol.PlayerResponse {
        lock.lock()
        defer { lock.unlock() }

        guard !playerResponses.isEmpty else {
            return .success(deviceName: "Port")
        }

        return playerResponses.removeFirst()
    }
}
