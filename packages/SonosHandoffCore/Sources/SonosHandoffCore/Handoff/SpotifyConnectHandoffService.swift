import CryptoKit
import Foundation

public protocol SpeakerVolumeAdjusting: Sendable {
    func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus
    func setVolume(roomName: String, volume: Int) async throws -> Int
    func volumeDown(roomName: String, step: Int) async throws -> Int
    func volumeUp(roomName: String, step: Int) async throws -> Int
    func toggleMute(roomName: String) async throws -> Bool
}

public protocol SonosSpeakerDiscovering: Sendable {
    func discoverSpeakers() async throws -> [SonosSpeaker]
}

public protocol RoomHandoffPerforming: Sendable {
    func transfer(toRoomName roomName: String) async -> TransferResult
}

public struct SonosSpeaker: Identifiable, Equatable, Sendable {
    public let id: String
    public let roomName: String
    public let host: String

    public init(id: String, roomName: String, host: String) {
        self.id = id
        self.roomName = roomName
        self.host = host
    }
}

public struct SpeakerVolumeStatus: Equatable, Sendable {
    public let roomName: String
    public let host: String
    public let volume: Int
    public let outputFixed: Bool
    public let muted: Bool

    public init(roomName: String, host: String, volume: Int, outputFixed: Bool, muted: Bool) {
        self.roomName = roomName
        self.host = host
        self.volume = volume
        self.outputFixed = outputFixed
        self.muted = muted
    }
}

public final class SpotifyConnectHandoffService: HandoffPerforming, RoomHandoffPerforming, SonosSpeakerDiscovering, SpeakerVolumeAdjusting, @unchecked Sendable {
    private let configStore: ConfigStoring
    private let targetResolver: TargetResolver
    private let preferredLoginID: String?
    private let appSupport: URL
    private let urlSession: URLSession
    private let targetCache = ConnectTargetCache()

    private let desktopClientID = "65b708073fc0480ea92a077233ca87bd"
    private let sonosClientID = "9b377073ea334637b1406f329ce005de"
    private let projectClientID = "f8bd8fc9a72a458eb359333b4f3cda14"

    public init(
        configStore: ConfigStoring,
        targetResolver: TargetResolver = TargetResolver(),
        loginID: String? = nil,
        appSupport: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/sonos-handoff", isDirectory: true),
        urlSession: URLSession = .shared
    ) {
        self.configStore = configStore
        self.targetResolver = targetResolver
        self.preferredLoginID = loginID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.appSupport = appSupport
        self.urlSession = urlSession
    }

    public func transfer(to alias: String) async -> TransferResult {
        do {
            let config = try configStore.load()
            guard let target = targetResolver.resolve(alias: alias, in: config) else {
                return .failure(code: .targetNotConfigured, message: "No saved target found for alias '\(alias)'.")
            }

            try await transferToRoom(named: target.spotifyDeviceName)
            return .success
        } catch let error as ConnectHandoffError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(code: .unsupported, message: error.localizedDescription)
        }
    }

    public func transfer(toRoomName roomName: String) async -> TransferResult {
        do {
            try await transferToRoom(named: roomName)
            return .success
        } catch let error as ConnectHandoffError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(code: .unsupported, message: error.localizedDescription)
        }
    }

    public func discoverSpeakers() async throws -> [SonosSpeaker] {
        try await Task.detached(priority: .userInitiated) {
            try Self.discoverSpeakerRows()
        }.value
    }

    public func volumeDown(roomName: String, step: Int = 5) async throws -> Int {
        let target = try await resolveTarget(named: roomName, needsSpotifyMetadata: false)
        let volume = try await currentVolume(on: target)
        return try await setVolume(on: target, to: volume - clampStep(step))
    }

    public func volumeUp(roomName: String, step: Int = 5) async throws -> Int {
        let target = try await resolveTarget(named: roomName, needsSpotifyMetadata: false)
        let volume = try await currentVolume(on: target)
        return try await setVolume(on: target, to: volume + clampStep(step))
    }

    public func volumeStatus(roomName: String) async throws -> SpeakerVolumeStatus {
        let target = try await resolveTarget(named: roomName, needsSpotifyMetadata: false)
        return SpeakerVolumeStatus(
            roomName: target.roomName,
            host: target.host,
            volume: try await currentVolume(on: target),
            outputFixed: try await currentOutputFixed(on: target),
            muted: try await currentMute(on: target)
        )
    }

    public func setVolume(roomName: String, volume: Int) async throws -> Int {
        let target = try await resolveTarget(named: roomName, needsSpotifyMetadata: false)
        return try await setVolume(on: target, to: volume)
    }

    public func toggleMute(roomName: String) async throws -> Bool {
        let target = try await resolveTarget(named: roomName, needsSpotifyMetadata: false)
        let muted = try await currentMute(on: target)
        return try await setMute(on: target, to: !muted)
    }

    private func transferToRoom(named roomName: String) async throws {
        let target = try await resolveTarget(named: roomName)
        guard let version = target.version else {
            throw ConnectHandoffError(.targetNotVisible, "Missing Spotify Connect version for \(roomName)")
        }
        let credential = try await refreshedDesktopCredential()
        let authorizationCode = try await spotifyConnectAuthorizationCode(from: credential.token.accessToken)
        let originDeviceName = "sonos-handoff-menu"
        let response = try await spotifyZeroconf(host: target.host, parameters: [
            "action": "addUser",
            "version": version,
            "tokenType": "authorization_code",
            "clientKey": "",
            "loginId": credential.loginID,
            "userName": credential.loginID,
            "blob": authorizationCode,
            "deviceName": originDeviceName,
            "deviceId": Self.sha1Hex(originDeviceName),
        ])

        guard (response["status"] as? Int) == 101 else {
            throw ConnectHandoffError(.transferVerificationFailed, "Sonos Spotify Connect activation failed: \(response)")
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let mediaInfo = try await sonosSOAP(host: target.host, service: "AVTransport", action: "GetMediaInfo", path: "/MediaRenderer/AVTransport/Control", body: """
        <u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetMediaInfo>
        """)
        let currentURI = Self.xmlUnescape(Self.firstMatch(#"<CurrentURI>([^<]*)</CurrentURI>"#, in: mediaInfo) ?? "")
        guard currentURI.hasPrefix("x-sonos-vli:"), currentURI.contains("spotify:") else {
            throw ConnectHandoffError(.transferVerificationFailed, "Port did not enter Spotify Connect mode; CurrentURI=\(currentURI)")
        }

        _ = try await sonosSOAP(host: target.host, service: "AVTransport", action: "Play", path: "/MediaRenderer/AVTransport/Control", body: """
        <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>
        """)

        try await waitForSonosSpotifyPlayback(on: target)
        await verifySpotifyActiveDeviceIfAvailable(named: roomName)
    }

    private func resolveTarget(named roomName: String, needsSpotifyMetadata: Bool = true) async throws -> ConnectSonosTarget {
        let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedTarget = targetCache.target(for: roomName),
           !needsSpotifyMetadata || cachedTarget.version != nil {
            return cachedTarget
        }

        let browse = try Self.runCommand(
            "/usr/bin/dns-sd",
            ["-B", "_sonos._tcp", "local."],
            timeoutSeconds: 5,
            stopWhen: { output in
                output
                    .split(separator: "\n")
                    .contains { Self.sonosInstance(fromBrowseLine: String($0), matchingRoomName: roomName) != nil }
            }
        )
        guard let instance = browse.output
            .split(separator: "\n")
            .compactMap({ line -> String? in
                Self.sonosInstance(fromBrowseLine: String(line), matchingRoomName: roomName)
            })
            .first
        else {
            throw ConnectHandoffError(.targetNotVisible, "Sonos target not found: \(roomName)")
        }

        let resolve = try Self.runCommand(
            "/usr/bin/dns-sd",
            ["-L", instance, "_sonos._tcp", "local."],
            timeoutSeconds: 5,
            stopWhen: { Self.firstMatch(#"location=http://([^:/\s]+):1400/"#, in: $0) != nil }
        )
        guard let host = Self.firstMatch(#"location=http://([^:/\s]+):1400/"#, in: resolve.output) else {
            throw ConnectHandoffError(.targetNotVisible, "Could not resolve host for \(instance)")
        }

        guard needsSpotifyMetadata else {
            let target = ConnectSonosTarget(roomName: roomName, host: host, version: nil, deviceID: nil)
            targetCache.store(target, for: roomName)
            return target
        }

        let info = try await spotifyZeroconf(host: host, parameters: ["action": "getInfo"])
        guard
            let version = info["version"] as? String,
            let deviceID = info["deviceID"] as? String
        else {
            throw ConnectHandoffError(.targetNotVisible, "Incomplete Sonos getInfo response: \(info)")
        }

        let target = ConnectSonosTarget(roomName: roomName, host: host, version: version, deviceID: deviceID)
        targetCache.store(target, for: roomName)
        return target
    }

    private static func discoverSpeakerRows() throws -> [SonosSpeaker] {
        let browse = try Self.runCommand(
            "/usr/bin/dns-sd",
            ["-B", "_sonos._tcp", "local."],
            timeoutSeconds: 3.0
        )
        let instances = Self.sonosInstances(fromBrowseOutput: browse.output)

        var speakers: [SonosSpeaker] = []
        for instance in instances {
            if let speaker = try? Self.resolveSpeaker(instance: instance) {
                speakers.append(speaker)
            }
        }

        return speakers
            .uniqued { $0.id }
            .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }

    private static func resolveSpeaker(instance: String) throws -> SonosSpeaker {
        guard let roomName = Self.sonosRoomName(fromInstance: instance) else {
            throw ConnectHandoffError(.targetNotVisible, "Could not read Sonos room name for \(instance)")
        }

        let resolve = try Self.runCommand(
            "/usr/bin/dns-sd",
            ["-L", instance, "_sonos._tcp", "local."],
            timeoutSeconds: 2,
            stopWhen: { Self.firstMatch(#"location=http://([^:/\s]+):1400/"#, in: $0) != nil }
        )
        guard let host = Self.firstMatch(#"location=http://([^:/\s]+):1400/"#, in: resolve.output) else {
            throw ConnectHandoffError(.targetNotVisible, "Could not resolve host for \(instance)")
        }

        return SonosSpeaker(id: sonosSpeakerID(fromInstance: instance) ?? "\(roomName)@\(host)", roomName: roomName, host: host)
    }

    private func currentVolume(on target: ConnectSonosTarget) async throws -> Int {
        let response = try await sonosSOAP(host: target.host, service: "RenderingControl", action: "GetVolume", path: "/MediaRenderer/RenderingControl/Control", body: """
        <u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolume>
        """)

        guard let volume = Self.firstMatch(#"<CurrentVolume>(\d+)</CurrentVolume>"#, in: response).flatMap(Int.init) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos volume.")
        }

        return volume
    }

    private func currentOutputFixed(on target: ConnectSonosTarget) async throws -> Bool {
        let response = try await sonosSOAP(host: target.host, service: "RenderingControl", action: "GetOutputFixed", path: "/MediaRenderer/RenderingControl/Control", body: """
        <u:GetOutputFixed xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID></u:GetOutputFixed>
        """)

        guard let rawValue = Self.firstMatch(#"<CurrentFixed>([01])</CurrentFixed>"#, in: response) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos fixed-output state.")
        }

        return rawValue == "1"
    }

    private func currentMute(on target: ConnectSonosTarget) async throws -> Bool {
        let response = try await sonosSOAP(host: target.host, service: "RenderingControl", action: "GetMute", path: "/MediaRenderer/RenderingControl/Control", body: """
        <u:GetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetMute>
        """)

        guard let rawValue = Self.firstMatch(#"<CurrentMute>([01])</CurrentMute>"#, in: response) else {
            throw ConnectHandoffError(.unsupported, "Could not read Sonos mute state.")
        }

        return rawValue == "1"
    }

    private func setVolume(on target: ConnectSonosTarget, to requestedVolume: Int) async throws -> Int {
        let volume = min(100, max(0, requestedVolume))
        _ = try await sonosSOAP(host: target.host, service: "RenderingControl", action: "SetVolume", path: "/MediaRenderer/RenderingControl/Control", body: """
        <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(volume)</DesiredVolume></u:SetVolume>
        """)
        _ = try await setMute(on: target, to: false)
        await setSpotifyActiveDeviceVolumeIfNeeded(roomName: target.roomName, volume: volume)
        return try await currentVolume(on: target)
    }

    private func setMute(on target: ConnectSonosTarget, to muted: Bool) async throws -> Bool {
        let desiredMute = muted ? 1 : 0
        _ = try await sonosSOAP(host: target.host, service: "RenderingControl", action: "SetMute", path: "/MediaRenderer/RenderingControl/Control", body: """
        <u:SetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(desiredMute)</DesiredMute></u:SetMute>
        """)
        return try await currentMute(on: target)
    }

    private func refreshedDesktopCredential() async throws -> ConnectDesktopCredential {
        let desktopTokenURL = appSupport.appendingPathComponent("spotify-desktop-connect-tokens.json")
        guard FileManager.default.fileExists(atPath: desktopTokenURL.path) else {
            throw ConnectHandoffError(.authRequired, "Missing Spotify Desktop streaming token. Run the CLI one-time auth first.")
        }

        var tokens = try JSONDecoder().decode([String: ConnectDesktopToken].self, from: Data(contentsOf: desktopTokenURL))
        let selectedKey: String?
        if let preferredLoginID {
            selectedKey = tokens.keys.first { $0.contains("/\(desktopClientID)/\(preferredLoginID)") }
            guard selectedKey != nil else {
                throw ConnectHandoffError(.authRequired, "No Spotify Desktop streaming token found for login ID '\(preferredLoginID)'.")
            }
        } else {
            selectedKey = tokens.keys.sorted().first
        }

        guard let key = selectedKey,
              let loginID = Self.loginID(fromDesktopTokenKey: key),
              var token = tokens[key]
        else {
            throw ConnectHandoffError(.authRequired, "No Spotify Desktop streaming token found.")
        }

        if token.expiresAt > Int(Date().timeIntervalSince1970) + 120 {
            return ConnectDesktopCredential(loginID: loginID, token: token)
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "client_id": desktopClientID,
            "refresh_token": token.refreshToken,
        ])

        let payload = try await spotifyJSON(request)
        guard let accessToken = payload["access_token"] as? String else {
            throw ConnectHandoffError(.authRequired, "Spotify Desktop token refresh failed: \(payload)")
        }

        token.accessToken = accessToken
        if let refreshToken = payload["refresh_token"] as? String {
            token.refreshToken = refreshToken
        }
        token.expiresAt = Int(Date().timeIntervalSince1970) + (payload["expires_in"] as? Int ?? 3600)
        tokens[key] = token
        try JSONEncoder.pretty.encode(tokens).write(to: desktopTokenURL)
        return ConnectDesktopCredential(loginID: loginID, token: token)
    }

    private func spotifyConnectAuthorizationCode(from desktopAccessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Spotify/124300420 Win32_x86_64/0 (PC desktop)", forHTTPHeaderField: "User-Agent")
        request.setValue("en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.httpBody = Self.formBody([
            "audience": sonosClientID,
            "client_id": desktopClientID,
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "requested_token_type": "urn:spotify:params:oauth:authorization_code",
            "resource": "urn:spotify:resources:connect",
            "scope": "streaming",
            "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "subject_token": desktopAccessToken,
        ])

        let payload = try await spotifyJSON(request)
        guard let accessToken = payload["access_token"] as? String else {
            throw ConnectHandoffError(.authRequired, "Spotify Connect token exchange failed: \(payload)")
        }
        return accessToken
    }

    private func refreshedProjectAccessToken() async throws -> String {
        let projectTokenURL = appSupport.appendingPathComponent("project-webapi-token.json")
        guard FileManager.default.fileExists(atPath: projectTokenURL.path) else {
            throw ConnectHandoffError(.authRequired, "Missing Spotify Web API token. Run Spotify Web API auth first.")
        }

        var token = try JSONDecoder().decode(ConnectProjectToken.self, from: Data(contentsOf: projectTokenURL))
        let clientID = try projectTokenClientID(from: token)
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": token.refreshToken,
        ])

        let payload = try await spotifyJSON(request)
        guard let accessToken = payload["access_token"] as? String else {
            throw ConnectHandoffError(.authRequired, "Spotify Web API token refresh failed: \(payload)")
        }

        token.accessToken = accessToken
        if let refreshToken = payload["refresh_token"] as? String {
            token.refreshToken = refreshToken
        }
        try JSONEncoder.pretty.encode(token).write(to: projectTokenURL)
        return accessToken
    }

    private func projectTokenClientID(from token: ConnectProjectToken) throws -> String {
        if let clientID = token.clientID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return clientID
        }

        if let clientID = try configStore.load().spotifyClientID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return clientID
        }

        return projectClientID
    }

    private func waitForSpotifyActiveDevice(named roomName: String) async throws -> ConnectPlayerState {
        let accessToken = try await refreshedProjectAccessToken()
        var lastDevice: String?
        for _ in 0 ..< 20 {
            guard let state = try await currentSpotifyPlayerState(accessToken: accessToken) else {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            lastDevice = state.device.name
            if state.device.name.caseInsensitiveCompare(roomName) == .orderedSame, state.isPlaying {
                return state
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ConnectHandoffError(.transferVerificationFailed, "Spotify active device is not \(roomName); last=\(lastDevice ?? "none")")
    }

    private func verifySpotifyActiveDeviceIfAvailable(named roomName: String) async {
        do {
            _ = try await waitForSpotifyActiveDevice(named: roomName)
        } catch {
            return
        }
    }

    private func waitForSonosSpotifyPlayback(on target: ConnectSonosTarget) async throws {
        var lastState: String?
        for _ in 0 ..< 8 {
            let transportInfo = try await sonosSOAP(host: target.host, service: "AVTransport", action: "GetTransportInfo", path: "/MediaRenderer/AVTransport/Control", body: """
            <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo>
            """)
            lastState = Self.firstMatch(#"<CurrentTransportState>([^<]*)</CurrentTransportState>"#, in: transportInfo)
            if lastState == "PLAYING" || lastState == "TRANSITIONING" {
                return
            }

            try await Task.sleep(nanoseconds: 350_000_000)
        }

        throw ConnectHandoffError(.transferVerificationFailed, "\(target.roomName) did not start Spotify playback; state=\(lastState ?? "unknown")")
    }

    private func currentSpotifyPlayerState(accessToken: String) async throws -> ConnectPlayerState? {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectHandoffError(.transferVerificationFailed, "Spotify returned a non-HTTP player response.")
        }
        if http.statusCode == 204 {
            return nil
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ConnectHandoffError(.transferVerificationFailed, String(data: data, encoding: .utf8) ?? "Spotify player HTTP \(http.statusCode)")
        }

        return try JSONDecoder().decode(ConnectPlayerState.self, from: data)
    }

    private func setSpotifyActiveDeviceVolumeIfNeeded(roomName: String, volume: Int) async {
        do {
            let accessToken = try await refreshedProjectAccessToken()
            guard let state = try await currentSpotifyPlayerState(accessToken: accessToken),
                  state.device.name.caseInsensitiveCompare(roomName) == .orderedSame,
                  !state.device.isRestricted
            else {
                return
            }

            var components = URLComponents(string: "https://api.spotify.com/v1/me/player/volume")!
            components.queryItems = [URLQueryItem(name: "volume_percent", value: String(volume))]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 204 || (200 ..< 300).contains(http.statusCode)
            else {
                _ = String(data: data, encoding: .utf8)
                return
            }
        } catch {
            return
        }
    }

    private func sonosSOAP(host: String, service: String, action: String, path: String, body: String) async throws -> String {
        let envelope = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
        """
        var request = URLRequest(url: URL(string: "http://\(host):1400\(path)")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await urlSession.data(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw ConnectHandoffError(.unsupported, "Sonos \(action) failed: \(responseBody)")
        }
        return responseBody
    }

    private func spotifyZeroconf(host: String, parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(host):1400/spotifyzc")!)
        request.httpMethod = parameters["action"] == "getInfo" ? "GET" : "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if request.httpMethod == "GET" {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.url = components.url
        } else {
            request.httpBody = Self.formBody(parameters)
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ConnectHandoffError(.unsupported, String(data: data, encoding: .utf8) ?? "Invalid zeroconf response")
        }
        return payload
    }

    private func spotifyJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectHandoffError(.unsupported, "Spotify returned a non-HTTP response.")
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? "Invalid Spotify response"
            if Self.isSpotifyAuthFailure(statusCode: http.statusCode, payload: nil) {
                throw ConnectHandoffError(.authRequired, "Spotify authentication failed: \(body)")
            }
            throw ConnectHandoffError(.unsupported, body)
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            if Self.isSpotifyAuthFailure(statusCode: http.statusCode, payload: payload) {
                throw ConnectHandoffError(.authRequired, "Spotify authentication failed: \(payload)")
            }
            throw ConnectHandoffError(.unsupported, "Spotify HTTP \(http.statusCode): \(payload)")
        }
        return payload
    }

    private func clampStep(_ step: Int) -> Int {
        min(25, max(5, step))
    }

    private static func sonosInstance(fromBrowseLine line: String, matchingRoomName roomName: String) -> String? {
        guard let instance = sonosInstance(fromBrowseLine: line),
            let instanceRoomName = sonosRoomName(fromInstance: instance),
            instanceRoomName.caseInsensitiveCompare(roomName) == .orderedSame
        else {
            return nil
        }

        return instance
    }

    private static func sonosInstances(fromBrowseOutput output: String) -> [String] {
        output
            .split(separator: "\n")
            .compactMap { sonosInstance(fromBrowseLine: String($0)) }
            .uniqued { $0 }
            .sorted()
    }

    private static func sonosInstance(fromBrowseLine line: String) -> String? {
        let parts = line.components(separatedBy: "_sonos._tcp.")
        guard parts.count > 1,
              let instance = parts.last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty,
              sonosRoomName(fromInstance: instance) != nil
        else {
            return nil
        }

        return instance
    }

    private static func sonosRoomName(fromInstance instance: String) -> String? {
        guard let roomName = instance
            .split(separator: "@", maxSplits: 1)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else {
            return nil
        }

        return DNSSDName.unescaped(roomName)
    }

    private static func sonosSpeakerID(fromInstance instance: String) -> String? {
        instance
            .split(separator: "@", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func isSpotifyAuthFailure(statusCode: Int, payload: [String: Any]?) -> Bool {
        guard statusCode == 400 || statusCode == 401 || statusCode == 403 else {
            return false
        }

        guard let error = payload?["error"] as? String else {
            return statusCode == 401 || statusCode == 403
        }

        return ["invalid_grant", "invalid_client", "invalid_token", "unauthorized_client"].contains(error)
    }

    private static func runCommand(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval,
        stopWhen: (@Sendable (String) -> Bool)? = nil
    ) throws -> ConnectCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputBuffer = ConnectCommandOutputBuffer(stopWhen: stopWhen)
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            outputBuffer.append(data)
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            if outputBuffer.shouldStop {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        outputHandle.readabilityHandler = nil

        let remainingData = outputHandle.readDataToEndOfFile()
        outputBuffer.append(remainingData)

        return ConnectCommandResult(output: outputBuffer.output, status: process.terminationStatus)
    }

    private static func formBody(_ parameters: [String: String]) -> Data {
        Data(parameters.map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }.sorted().joined(separator: "&").utf8)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func loginID(fromDesktopTokenKey key: String) -> String? {
        key.split(separator: "/").last.map(String.init)?.nilIfEmpty
    }

    private static func xmlUnescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private struct ConnectSonosTarget: Sendable {
    let roomName: String
    let host: String
    let version: String?
    let deviceID: String?
}

private final class ConnectTargetCache: @unchecked Sendable {
    private struct Entry {
        let target: ConnectSonosTarget
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 120

    func target(for roomName: String) -> ConnectSonosTarget? {
        let key = roomName.lowercased()
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else {
            return nil
        }

        guard entry.expiresAt > Date() else {
            entries.removeValue(forKey: key)
            return nil
        }

        return entry.target
    }

    func store(_ target: ConnectSonosTarget, for roomName: String) {
        lock.lock()
        entries[roomName.lowercased()] = Entry(target: target, expiresAt: Date().addingTimeInterval(ttl))
        lock.unlock()
    }
}

private struct ConnectCommandResult {
    let output: String
    let status: Int32
}

private final class ConnectCommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let stopWhen: (@Sendable (String) -> Bool)?
    private var outputData = Data()
    private var matchedStopCondition = false

    init(stopWhen: (@Sendable (String) -> Bool)?) {
        self.stopWhen = stopWhen
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return matchedStopCondition
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        outputData.append(data)
        let output = String(data: outputData, encoding: .utf8) ?? ""
        matchedStopCondition = matchedStopCondition || (stopWhen?(output) ?? false)
        lock.unlock()
    }
}

private struct ConnectDesktopToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

private struct ConnectDesktopCredential {
    let loginID: String
    let token: ConnectDesktopToken
}

private struct ConnectProjectToken: Codable {
    var accessToken: String
    var refreshToken: String
    var clientID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
    }
}

private struct ConnectPlayerState: Decodable {
    let isPlaying: Bool
    let device: ConnectPlayerDevice

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case device
    }
}

private struct ConnectPlayerDevice: Decodable {
    let name: String
    let isRestricted: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case isRestricted = "is_restricted"
    }
}

private struct ConnectHandoffError: Error {
    let code: TransferErrorCode
    let message: String

    init(_ code: TransferErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? self
    }
}

private extension Sequence {
    func uniqued<ID: Hashable>(by id: (Element) -> ID) -> [Element] {
        var seen = Set<ID>()
        var values: [Element] = []
        for element in self where seen.insert(id(element)).inserted {
            values.append(element)
        }
        return values
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
