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
    func volumeMirrorRetriesRateLimitedVolumeWrite() async throws {
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
        SpotifyBridgeURLProtocol.setVolumeResponses([.rateLimited, .emptySuccess])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        await bridge.setActiveDeviceVolumeIfNeeded(roomName: "Port", volume: 42)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(urls.filter { $0.path == "/v1/me/player/volume" }.count == 2)
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
    func playbackStartUsesCurrentPlayerPlayEndpoint() async throws {
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

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        try await bridge.startPlayback(spotifyURI: "spotify:track:3n3Ppam7vgaVa1iaRUc9Lp")

        let requests = SpotifyBridgeURLProtocol.recordedRequests()
        let playRequest = try #require(requests.first { $0.url.path == "/v1/me/player/play" })
        #expect(playRequest.method == "PUT")
        #expect(playRequest.body == #"{"uris":["spotify:track:3n3Ppam7vgaVa1iaRUc9Lp"]}"#)
    }

    @Test
    func playbackStartSelectsUnrestrictedDevice() async throws {
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
        SpotifyBridgeURLProtocol.setDevicesResponses([
            .success(body: #"{"devices":[{"id":"speaker-id","is_active":true,"is_restricted":true,"name":"Kitchen","type":"Speaker"},{"id":"computer-id","is_active":false,"is_restricted":false,"name":"Mac","type":"Computer"}]}"#),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        try await bridge.startPlayback(
            spotifyURI: "spotify:track:3n3Ppam7vgaVa1iaRUc9Lp",
            deviceName: nil,
            deviceType: "Computer"
        )

        let requests = SpotifyBridgeURLProtocol.recordedRequests()
        _ = try #require(requests.first { $0.url.path == "/v1/me/player/devices" })
        let playRequest = try #require(requests.first { $0.url.path == "/v1/me/player/play" })
        #expect(playRequest.url.query == "device_id=computer-id")
    }

    @Test
    func playbackTransferSelectsUnrestrictedDevice() async throws {
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
        SpotifyBridgeURLProtocol.setDevicesResponses([
            .success(body: #"{"devices":[{"id":"speaker-id","is_active":true,"is_restricted":true,"name":"Kitchen","type":"Speaker"},{"id":"computer-id","is_active":false,"is_restricted":false,"name":"Mac","type":"Computer"}]}"#),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        try await bridge.transferPlayback(deviceName: nil, deviceType: "Computer", play: true)

        let requests = SpotifyBridgeURLProtocol.recordedRequests()
        _ = try #require(requests.first { $0.url.path == "/v1/me/player/devices" })
        let transferRequest = try #require(requests.first { $0.url.path == "/v1/me/player" && $0.method == "PUT" })
        #expect(transferRequest.url.query == nil)
        let transferBody = try #require(transferRequest.body?.data(using: .utf8))
        let transferJSON = try #require(JSONSerialization.jsonObject(with: transferBody) as? [String: Any])
        #expect(transferJSON["device_ids"] as? [String] == ["computer-id"])
        #expect(transferJSON["play"] as? Bool == true)
        #expect(requests.allSatisfy { $0.url.path != "/v1/me/player/play" })
    }

    @Test
    func playbackTransferRejectsAmbiguousComputerTypeOnlyTarget() async throws {
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
        SpotifyBridgeURLProtocol.setDevicesResponses([
            .success(body: #"{"devices":[{"id":"this-mac-id","is_active":false,"is_restricted":false,"name":"This Mac","type":"Computer"},{"id":"other-mac-id","is_active":false,"is_restricted":false,"name":"Studio Mac","type":"Computer"}]}"#),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        do {
            try await bridge.transferPlayback(deviceName: nil, deviceType: "Computer", play: true)
            Issue.record("Expected ambiguous Spotify computer transfer to fail.")
        } catch let error as ConnectHandoffError {
            #expect(error.message.contains("multiple unrestricted Computer playback devices"))
        }

        let requests = SpotifyBridgeURLProtocol.recordedRequests()
        #expect(!requests.contains { $0.url.path == "/v1/me/player" && $0.method == "PUT" })
    }

    @Test
    func playbackStartFailsWhenNoUnrestrictedDeviceMatches() async throws {
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
        SpotifyBridgeURLProtocol.setDevicesResponses([
            .success(body: #"{"devices":[]}"#),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        do {
            try await bridge.startPlayback(spotifyURI: nil, deviceName: nil, deviceType: "Computer")
            Issue.record("Expected Spotify playback priming to fail without an unrestricted device.")
        } catch let error as ConnectHandoffError {
            #expect(error.message.contains("no unrestricted Computer playback device"))
        }
    }

    @Test
    func availablePlaybackDevicesReturnsDeviceSummary() async throws {
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
        SpotifyBridgeURLProtocol.setDevicesResponses([
            .success(body: #"{"devices":[{"id":"computer-id","is_active":true,"is_restricted":false,"name":"Mac","type":"Computer"}]}"#),
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        let devices = try await bridge.availablePlaybackDevices()

        #expect(devices == [
            SpotifyAvailablePlaybackDevice(name: "Mac", type: "Computer", isActive: true, isRestricted: false),
        ])
    }

    @Test
    func playbackStartRefreshesRejectedCachedToken() async throws {
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
        SpotifyBridgeURLProtocol.setPlayResponses([.unauthorized, .emptySuccess])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        try await bridge.startPlayback()

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(urls.filter { $0.path == "/v1/me/player/play" }.count == 2)
        #expect(urls.contains { $0.host == "accounts.spotify.com" && $0.path == "/api/token" })
        #expect(try tokenStore.load()?.accessToken == "refreshed-access-token")
    }

    @Test
    func playbackCommandUsesCurrentPlayerPauseEndpoint() async throws {
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

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        try await bridge.sendPlaybackCommand(.pause)

        let request = try #require(SpotifyBridgeURLProtocol.recordedRequests().first { $0.url.path == "/v1/me/player/pause" })
        #expect(request.method == "PUT")
    }

    @Test
    func playbackCommandPlayPauseReadsStateAndSendsPauseWhenPlaying() async throws {
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
        SpotifyBridgeURLProtocol.setPlayerResponses([.success(deviceName: "Kitchen")])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        try await bridge.sendPlaybackCommand(.playPause)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(urls.map(\.path).contains("/v1/me/player"))
        let pauseRequest = try #require(SpotifyBridgeURLProtocol.recordedRequests().first { $0.url.path == "/v1/me/player/pause" })
        #expect(pauseRequest.method == "PUT")
    }

    @Test
    func playbackCommandRefreshesRejectedCachedToken() async throws {
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
        SpotifyBridgeURLProtocol.setPlaybackCommandResponses(path: "/v1/me/player/next", responses: [.unauthorized, .emptySuccess])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        try await bridge.sendPlaybackCommand(.next)

        let urls = SpotifyBridgeURLProtocol.recordedURLs()
        #expect(urls.filter { $0.path == "/v1/me/player/next" }.count == 2)
        #expect(urls.contains { $0.host == "accounts.spotify.com" && $0.path == "/api/token" })
        #expect(try tokenStore.load()?.accessToken == "refreshed-access-token")
    }

    @Test
    func playbackCommandPreservesRestrictedDeviceResponseBody() async throws {
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
        SpotifyBridgeURLProtocol.setPlaybackCommandResponses(
            path: "/v1/me/player/pause",
            responses: [.restrictedDevice, .restrictedDevice]
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SpotifyBridgeURLProtocol.self]
        let bridge = SpotifyConnectBridge(
            loginID: nil,
            appSupport: applicationSupportDirectory,
            urlSession: URLSession(configuration: sessionConfiguration)
        )

        do {
            try await bridge.sendPlaybackCommand(.pause)
            Issue.record("Expected restricted Spotify devices to fail playback commands.")
        } catch let error as ConnectHandoffError {
            #expect(error.message.contains("Restricted device"))
        }
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
    struct RecordedRequest: Sendable {
        let url: URL
        let method: String?
        let body: String?
    }

    struct PlayerResponse: Sendable {
        let statusCode: Int
        let body: String

        static func success(deviceName: String, restricted: Bool = false, volumePercent: Int = 42) -> PlayerResponse {
            PlayerResponse(
                statusCode: 200,
                body: #"{"is_playing":true,"device":{"name":"\#(deviceName)","is_restricted":\#(restricted),"volume_percent":\#(volumePercent)}}"#
            )
        }

        static func success(body: String) -> PlayerResponse {
            PlayerResponse(statusCode: 200, body: body)
        }

        static let noActivePlayback = PlayerResponse(statusCode: 204, body: "")
        static let unauthorized = PlayerResponse(statusCode: 401, body: #"{"error":"invalid_token"}"#)
        static let rateLimited = PlayerResponse(statusCode: 429, body: #"{"error":"rate_limited"}"#)
        static let emptySuccess = PlayerResponse(statusCode: 204, body: "")
        static let restrictedDevice = PlayerResponse(statusCode: 403, body: #"{"error":{"status":403,"message":"Restricted device"}}"#)
    }

    private static let recorder = SpotifyBridgeURLRecorder()

    static func reset() {
        recorder.reset()
    }

    static func setPlayerResponses(_ responses: [PlayerResponse]) {
        recorder.setPlayerResponses(responses)
    }

    static func setVolumeResponses(_ responses: [PlayerResponse]) {
        recorder.setVolumeResponses(responses)
    }

    static func setPlayResponses(_ responses: [PlayerResponse]) {
        recorder.setPlayResponses(responses)
    }

    static func setDevicesResponses(_ responses: [PlayerResponse]) {
        recorder.setDevicesResponses(responses)
    }

    static func setPlaybackCommandResponses(path: String, responses: [PlayerResponse]) {
        recorder.setPlaybackCommandResponses(path: path, responses: responses)
    }

    static func recordedURLs() -> [URL] {
        recorder.recordedURLs()
    }

    static func recordedRequests() -> [RecordedRequest] {
        recorder.recordedRequests()
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

        Self.recorder.record(request)

        switch (url.host, url.path) {
        case ("api.spotify.com", "/v1/me/player"):
            let response = Self.recorder.nextPlayerResponse()
            respond(statusCode: response.statusCode, body: response.body)
        case ("api.spotify.com", "/v1/me/player/volume"):
            let response = Self.recorder.nextVolumeResponse()
            respond(statusCode: response.statusCode, body: response.body)
        case ("api.spotify.com", "/v1/me/player/play"):
            let response = Self.recorder.nextPlayResponse()
            respond(statusCode: response.statusCode, body: response.body)
        case ("api.spotify.com", "/v1/me/player/devices"):
            let response = Self.recorder.nextDevicesResponse()
            respond(statusCode: response.statusCode, body: response.body)
        case ("api.spotify.com", "/v1/me/player/pause"),
             ("api.spotify.com", "/v1/me/player/next"),
             ("api.spotify.com", "/v1/me/player/previous"):
            let response = Self.recorder.nextPlaybackCommandResponse(path: url.path)
            respond(statusCode: response.statusCode, body: response.body)
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
            headerFields: statusCode == 429
                ? ["Content-Type": "application/json", "Retry-After": "0"]
                : ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SpotifyBridgeURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SpotifyBridgeURLProtocol.RecordedRequest] = []
    private var playerResponses: [SpotifyBridgeURLProtocol.PlayerResponse] = []
    private var volumeResponses: [SpotifyBridgeURLProtocol.PlayerResponse] = []
    private var playResponses: [SpotifyBridgeURLProtocol.PlayerResponse] = []
    private var devicesResponses: [SpotifyBridgeURLProtocol.PlayerResponse] = []
    private var playbackCommandResponses: [String: [SpotifyBridgeURLProtocol.PlayerResponse]] = [:]

    func reset() {
        lock.lock()
        requests = []
        playerResponses = []
        volumeResponses = []
        playResponses = []
        devicesResponses = []
        playbackCommandResponses = [:]
        lock.unlock()
    }

    func setPlayerResponses(_ responses: [SpotifyBridgeURLProtocol.PlayerResponse]) {
        lock.lock()
        playerResponses = responses
        lock.unlock()
    }

    func setVolumeResponses(_ responses: [SpotifyBridgeURLProtocol.PlayerResponse]) {
        lock.lock()
        volumeResponses = responses
        lock.unlock()
    }

    func setPlayResponses(_ responses: [SpotifyBridgeURLProtocol.PlayerResponse]) {
        lock.lock()
        playResponses = responses
        lock.unlock()
    }

    func setDevicesResponses(_ responses: [SpotifyBridgeURLProtocol.PlayerResponse]) {
        lock.lock()
        devicesResponses = responses
        lock.unlock()
    }

    func setPlaybackCommandResponses(path: String, responses: [SpotifyBridgeURLProtocol.PlayerResponse]) {
        lock.lock()
        playbackCommandResponses[path] = responses
        lock.unlock()
    }

    func recordedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map(\.url)
    }

    func recordedRequests() -> [SpotifyBridgeURLProtocol.RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(SpotifyBridgeURLProtocol.RecordedRequest(
            url: request.url!,
            method: request.httpMethod,
            body: requestBody(request)
        ))
        lock.unlock()
    }

    private func requestBody(_ request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(decoding: body, as: UTF8.self)
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func nextPlayerResponse() -> SpotifyBridgeURLProtocol.PlayerResponse {
        lock.lock()
        defer { lock.unlock() }

        guard !playerResponses.isEmpty else {
            return .success(deviceName: "Port")
        }

        return playerResponses.removeFirst()
    }

    func nextVolumeResponse() -> SpotifyBridgeURLProtocol.PlayerResponse {
        lock.lock()
        defer { lock.unlock() }

        guard !volumeResponses.isEmpty else {
            return .emptySuccess
        }

        return volumeResponses.removeFirst()
    }

    func nextPlayResponse() -> SpotifyBridgeURLProtocol.PlayerResponse {
        lock.lock()
        defer { lock.unlock() }

        guard !playResponses.isEmpty else {
            return .emptySuccess
        }

        return playResponses.removeFirst()
    }

    func nextDevicesResponse() -> SpotifyBridgeURLProtocol.PlayerResponse {
        lock.lock()
        defer { lock.unlock() }

        guard !devicesResponses.isEmpty else {
            return .success(body: #"{"devices":[]}"#)
        }

        return devicesResponses.removeFirst()
    }

    func nextPlaybackCommandResponse(path: String) -> SpotifyBridgeURLProtocol.PlayerResponse {
        lock.lock()
        defer { lock.unlock() }

        guard var responses = playbackCommandResponses[path], !responses.isEmpty else {
            return .emptySuccess
        }

        let response = responses.removeFirst()
        playbackCommandResponses[path] = responses
        return response
    }
}
