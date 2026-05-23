import CryptoKit
import Foundation
import SonosHandoffCore

if hasHelpOption() {
    printUsage()
    exit(0)
}

do {
    try validateOptions()
} catch let error as CLIError {
    fputs("sonos-handoff-port: \(error.description)\n", stderr)
    exit(1)
}

private let targetName = targetArgument() ?? "Port"
private let command = commandArgument()
private let explicitLoginID = optionValue("--login-id")
private let desktopClientID = "65b708073fc0480ea92a077233ca87bd"
private let sonosClientID = "9b377073ea334637b1406f329ce005de"
private let appSupport = ConfigPaths.applicationSupportDirectory
private let desktopTokenURL = appSupport.appendingPathComponent("spotify-desktop-connect-tokens.json")
private let projectTokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: appSupport)

struct SonosTarget {
    let roomName: String
    let host: String
    let version: String?
    let deviceID: String?
    let publicKey: String?
}

struct CommandResult {
    let output: String
    let status: Int32
}

final class CommandOutputBuffer: @unchecked Sendable {
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

struct DesktopToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

struct DesktopCredential {
    let loginID: String
    let token: DesktopToken
}

struct PlayerState: Decodable {
    let isPlaying: Bool
    let device: PlayerDevice
    let item: PlayerItem?

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case device
        case item
    }
}

struct PlayerDevice: Decodable {
    let name: String
    let type: String
    let isRestricted: Bool
    let volumePercent: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
    }
}

struct PlayerItem: Decodable {
    let name: String
    let uri: String
}

enum CLIError: Error, CustomStringConvertible {
    case commandFailed(String)
    case missingToken(String)
    case sonosTargetNotFound(String)
    case sonosResponse(String)
    case spotifyResponse(String)
    case verificationFailed(String)

    var description: String {
        switch self {
        case .commandFailed(let message),
             .missingToken(let message),
             .sonosResponse(let message),
             .spotifyResponse(let message),
             .verificationFailed(let message):
            return message
        case .sonosTargetNotFound(let room):
            return "Sonos target not found: \(room)"
        }
    }
}

do {
    switch command {
    case "handoff":
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: true)
        try await performHandoff(to: target)
    case "volume-up":
        let step = try volumeStep()
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let volume = try await adjustVolume(on: target, delta: step)
        print("volume=\(volume)")
        print("volume-up=ok")
    case "volume-down":
        let step = try volumeStep()
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let volume = try await adjustVolume(on: target, delta: -step)
        print("volume=\(volume)")
        print("volume-down=ok")
    case "volume-set":
        let volumeValue = try desiredVolume()
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let volume = try await setVolume(on: target, to: volumeValue)
        print("volume=\(volume)")
        print("volume-set=ok")
    case "volume-status":
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let volume = try await currentVolume(on: target)
        let outputFixed = try await currentOutputFixed(on: target)
        let muted = try await currentMute(on: target)
        print("volume=\(volume)")
        print("output_fixed=\(outputFixed)")
        print("muted=\(muted)")
        print("volume-status=ok")
    case "volume-mute":
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let muted = try await toggleMute(on: target)
        print("muted=\(muted)")
        print("volume-mute=ok")
    case "volume-mute-on":
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let muted = try await setMute(on: target, to: true)
        print("muted=\(muted)")
        print("volume-mute-on=ok")
    case "volume-mute-off":
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let muted = try await setMute(on: target, to: false)
        print("muted=\(muted)")
        print("volume-mute-off=ok")
    case "volume-zero-muted":
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let volume = try await setVolume(on: target, to: 0)
        let muted = try await setMute(on: target, to: true)
        print("volume=\(volume)")
        print("muted=\(muted)")
        print("volume-zero-muted=ok")
    case "playback-status":
        let state = try await currentSpotifyPlaybackState()
        printSpotifyState(state)
        print("playback-status=ok")
    case "sonos-status":
        let target = try await resolvedCommandTarget(needsSpotifyMetadata: false)
        let currentURI = try await currentMediaURI(on: target)
        let transportState = try await currentTransportState(on: target)
        print("current_uri=\(currentURI)")
        print("transport_state=\(transportState)")
        print("sonos-status=ok")
    default:
        throw CLIError.commandFailed("Unknown command: \(command)")
    }
} catch let error as CLIError {
    fputs("sonos-handoff-port: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("sonos-handoff-port: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func resolvedCommandTarget(needsSpotifyMetadata: Bool) async throws -> SonosTarget {
    let target = try await resolveTarget(
        named: targetName,
        needsSpotifyMetadata: needsSpotifyMetadata
    )
    if let deviceID = target.deviceID {
        print("target=\(target.roomName) host=\(target.host) device_id=\(deviceID)")
    } else {
        print("target=\(target.roomName) host=\(target.host)")
    }
    return target
}

func performHandoff(to target: SonosTarget) async throws {
    try await connectSonosToSpotify(target)
    let mediaInfo = try await sonosSOAP(host: target.host, action: "GetMediaInfo", body: """
    <u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetMediaInfo>
    """)

    let currentURI = xmlUnescape(firstMatch(#"<CurrentURI>([^<]*)</CurrentURI>"#, in: mediaInfo) ?? "")
    guard currentURI.hasPrefix("x-sonos-vli:"), currentURI.contains("spotify:") else {
        throw CLIError.verificationFailed("Port did not enter Spotify Connect source mode; CurrentURI=\(currentURI)")
    }

    try await sonosSOAP(host: target.host, action: "Play", body: """
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>
    """)

    try await waitForSonosSpotifyPlayback(on: target)
    if let state = try? await waitForSpotifyActiveDevice(named: target.roomName) {
        print("spotify_device=\(state.device.name) type=\(state.device.type) restricted=\(state.device.isRestricted)")
        if let volumePercent = state.device.volumePercent {
            print("spotify_device_volume=\(volumePercent)")
        }
        print("spotify_playing=\(state.isPlaying)")
        if let item = state.item {
            print("spotify_item=\(item.name)")
            print("spotify_uri=\(item.uri)")
        }
    } else {
        print("spotify_device_verification=skipped")
    }
    print("sonos_transport=playing")
    print("handoff=ok")
}

func currentSpotifyPlaybackState() async throws -> PlayerState {
    let accessToken = try await refreshedProjectAccessToken()
    var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw CLIError.spotifyResponse("Spotify player state returned a non-HTTP response")
    }

    if http.statusCode == 204 {
        throw CLIError.verificationFailed("Spotify has no active playback")
    }

    guard (200 ..< 300).contains(http.statusCode) else {
        throw CLIError.spotifyResponse(String(data: data, encoding: .utf8) ?? "Spotify player state HTTP \(http.statusCode)")
    }

    return try JSONDecoder().decode(PlayerState.self, from: data)
}

func printSpotifyState(_ state: PlayerState) {
    print("spotify_device=\(state.device.name) type=\(state.device.type) restricted=\(state.device.isRestricted)")
    if let volumePercent = state.device.volumePercent {
        print("spotify_device_volume=\(volumePercent)")
    }
    print("spotify_playing=\(state.isPlaying)")
    if let item = state.item {
        print("spotify_item=\(item.name)")
        print("spotify_uri=\(item.uri)")
    }
}

func resolveTarget(
    named roomName: String,
    needsSpotifyMetadata: Bool = true
) async throws -> SonosTarget {
    let host: String
    let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
    let browse = try runCommand(
        "/usr/bin/dns-sd",
        ["-B", "_sonos._tcp", "local."],
        timeoutSeconds: 5,
        stopWhen: { output in
            output
                .split(separator: "\n")
                .contains { sonosInstance(fromBrowseLine: String($0), matchingRoomName: roomName) != nil }
        }
    )
    guard let instance = browse.output
        .split(separator: "\n")
        .compactMap({ line -> String? in
            sonosInstance(fromBrowseLine: String(line), matchingRoomName: roomName)
        })
        .first
    else {
        throw CLIError.sonosTargetNotFound(roomName)
    }

    let resolve = try runCommand(
        "/usr/bin/dns-sd",
        ["-L", instance, "_sonos._tcp", "local."],
        timeoutSeconds: 5,
        stopWhen: { firstMatch(#"location=http://([^:/\s]+):1400/"#, in: $0) != nil }
    )
    guard let resolvedHost = firstMatch(#"location=http://([^:/\s]+):1400/"#, in: resolve.output) else {
        throw CLIError.sonosResponse("Could not resolve host for \(instance)")
    }
    host = resolvedHost

    guard needsSpotifyMetadata else {
        return SonosTarget(roomName: roomName, host: host, version: nil, deviceID: nil, publicKey: nil)
    }

    let info = try await spotifyZeroconf(host: host, parameters: ["action": "getInfo"])
    guard
        let version = info["version"] as? String,
        let deviceID = info["deviceID"] as? String,
        let publicKey = info["publicKey"] as? String
    else {
        throw CLIError.sonosResponse("Incomplete Sonos getInfo response: \(info)")
    }

    return SonosTarget(roomName: roomName, host: host, version: version, deviceID: deviceID, publicKey: publicKey)
}

func currentVolume(on target: SonosTarget) async throws -> Int {
    let response = try await sonosRenderingSOAP(host: target.host, action: "GetVolume", body: """
    <u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolume>
    """)

    guard let value = firstMatch(#"<CurrentVolume>(\d+)</CurrentVolume>"#, in: response).flatMap(Int.init) else {
        throw CLIError.sonosResponse("Could not read Sonos volume: \(response)")
    }

    return value
}

func currentOutputFixed(on target: SonosTarget) async throws -> Bool {
    let response = try await sonosRenderingSOAP(host: target.host, action: "GetOutputFixed", body: """
    <u:GetOutputFixed xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID></u:GetOutputFixed>
    """)

    guard let rawValue = firstMatch(#"<CurrentFixed>([01])</CurrentFixed>"#, in: response) else {
        throw CLIError.sonosResponse("Could not read Sonos fixed-output state: \(response)")
    }

    return rawValue == "1"
}

func currentMute(on target: SonosTarget) async throws -> Bool {
    let response = try await sonosRenderingSOAP(host: target.host, action: "GetMute", body: """
    <u:GetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetMute>
    """)

    guard let rawValue = firstMatch(#"<CurrentMute>([01])</CurrentMute>"#, in: response) else {
        throw CLIError.sonosResponse("Could not read Sonos mute state: \(response)")
    }

    return rawValue == "1"
}

func currentMediaURI(on target: SonosTarget) async throws -> String {
    let response = try await sonosSOAP(host: target.host, action: "GetMediaInfo", body: """
    <u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetMediaInfo>
    """)

    guard let currentURI = firstMatch(#"<CurrentURI>([^<]*)</CurrentURI>"#, in: response) else {
        throw CLIError.sonosResponse("Could not read Sonos media URI: \(response)")
    }

    return xmlUnescape(currentURI)
}

func currentTransportState(on target: SonosTarget) async throws -> String {
    let response = try await sonosSOAP(host: target.host, action: "GetTransportInfo", body: """
    <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo>
    """)

    guard let transportState = firstMatch(#"<CurrentTransportState>([^<]*)</CurrentTransportState>"#, in: response) else {
        throw CLIError.sonosResponse("Could not read Sonos transport state: \(response)")
    }

    return transportState
}

func adjustVolume(on target: SonosTarget, delta: Int) async throws -> Int {
    let volume = try await currentVolume(on: target)
    return try await setVolume(on: target, to: volume + delta)
}

func toggleMute(on target: SonosTarget) async throws -> Bool {
    let muted = try await currentMute(on: target)
    return try await setMute(on: target, to: !muted)
}

func setVolume(on target: SonosTarget, to requestedVolume: Int) async throws -> Int {
    let volume = min(100, max(0, requestedVolume))
    try await sonosRenderingSOAP(host: target.host, action: "SetVolume", body: """
    <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(volume)</DesiredVolume></u:SetVolume>
    """)
    _ = try await setMute(on: target, to: false)
    await setSpotifyActiveDeviceVolumeIfNeeded(on: target, to: volume)

    return try await currentVolume(on: target)
}

func setSpotifyActiveDeviceVolumeIfNeeded(on target: SonosTarget, to volume: Int) async {
    do {
        let state = try await currentSpotifyPlaybackState()
        guard state.device.name.caseInsensitiveCompare(target.roomName) == .orderedSame,
              !state.device.isRestricted
        else {
            return
        }

        let accessToken = try await refreshedProjectAccessToken()
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/volume")!
        components.queryItems = [URLQueryItem(name: "volume_percent", value: String(volume))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 204 || (200 ..< 300).contains(http.statusCode)
        else {
            return
        }
    } catch {
        return
    }
}

func setMute(on target: SonosTarget, to muted: Bool) async throws -> Bool {
    let desiredMute = muted ? 1 : 0
    try await sonosRenderingSOAP(host: target.host, action: "SetMute", body: """
    <u:SetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(desiredMute)</DesiredMute></u:SetMute>
    """)

    return try await currentMute(on: target)
}

func sonosInstance(fromBrowseLine line: String, matchingRoomName roomName: String) -> String? {
    guard let instance = line.components(separatedBy: "_sonos._tcp.").last?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty,
        let instanceRoomName = sonosRoomName(fromInstance: instance),
        instanceRoomName.caseInsensitiveCompare(roomName) == .orderedSame
    else {
        return nil
    }

    return instance
}

func sonosRoomName(fromInstance instance: String) -> String? {
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

func connectSonosToSpotify(_ target: SonosTarget) async throws {
    guard let version = target.version else {
        throw CLIError.sonosResponse("Missing Spotify Connect version for \(target.roomName)")
    }
    let credential = try await refreshedDesktopCredential()
    let authorizationCode = try await spotifyConnectAuthorizationCode(from: credential.token.accessToken)
    let originDeviceName = "sonos-handoff-cli"
    let response = try await spotifyZeroconf(host: target.host, parameters: [
        "action": "addUser",
        "version": version,
        "tokenType": "authorization_code",
        "clientKey": "",
        "loginId": credential.loginID,
        "userName": credential.loginID,
        "blob": authorizationCode,
        "deviceName": originDeviceName,
        "deviceId": sha1Hex(originDeviceName),
    ])

    guard (response["status"] as? Int) == 101 else {
        throw CLIError.sonosResponse("Sonos addUser failed: \(response)")
    }

    try await Task.sleep(nanoseconds: 1_000_000_000)
}

func refreshedDesktopCredential() async throws -> DesktopCredential {
    guard FileManager.default.fileExists(atPath: desktopTokenURL.path) else {
        throw CLIError.missingToken("Missing Spotify desktop-connect token at \(desktopTokenURL.path). Run the one-time Spotify Desktop streaming auth first.")
    }

    var tokens = try JSONDecoder().decode(
        [String: DesktopToken].self,
        from: ProjectWebAPITokenStore.sensitiveFileData(at: desktopTokenURL)
    )
    let selectedKey: String?
    if let explicitLoginID {
        selectedKey = tokens.keys.first { $0.contains("/\(desktopClientID)/\(explicitLoginID)") }
        guard selectedKey != nil else {
            throw CLIError.missingToken("No Spotify desktop-connect token found for login ID '\(explicitLoginID)' in \(desktopTokenURL.path)")
        }
    } else {
        selectedKey = tokens.keys.sorted().first
    }

    guard let key = selectedKey,
          let loginID = loginID(fromDesktopTokenKey: key),
          var token = tokens[key]
    else {
        throw CLIError.missingToken("No Spotify desktop-connect token found in \(desktopTokenURL.path)")
    }

    if token.expiresAt > Int(Date().timeIntervalSince1970) + 120 {
        return DesktopCredential(loginID: loginID, token: token)
    }

    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formBody([
        "grant_type": "refresh_token",
        "client_id": desktopClientID,
        "refresh_token": token.refreshToken,
    ])

    let payload = try await spotifyJSON(request)
    guard let accessToken = payload["access_token"] as? String else {
        throw CLIError.spotifyResponse("Spotify desktop token refresh failed: \(payload)")
    }

    token.accessToken = accessToken
    if let refreshToken = payload["refresh_token"] as? String {
        token.refreshToken = refreshToken
    }
    token.expiresAt = Int(Date().timeIntervalSince1970) + (payload["expires_in"] as? Int ?? 3600)
    tokens[key] = token
    try ProjectWebAPITokenStore.writeSensitiveFileData(JSONEncoder.pretty.encode(tokens), to: desktopTokenURL)
    return DesktopCredential(loginID: loginID, token: token)
}

func spotifyConnectAuthorizationCode(from desktopAccessToken: String) async throws -> String {
    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("Spotify/124300420 Win32_x86_64/0 (PC desktop)", forHTTPHeaderField: "User-Agent")
    request.setValue("en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
    request.httpBody = formBody([
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
        throw CLIError.spotifyResponse("Spotify Connect token exchange failed: \(payload)")
    }

    return accessToken
}

func refreshedProjectAccessToken() async throws -> String {
    var token: ProjectWebAPIToken
    do {
        guard let loadedToken = try projectTokenStore.load() else {
            throw CLIError.missingToken("Missing project Web API token at \(projectTokenStore.tokenURL.path). Run Spotify Web API auth first.")
        }
        token = loadedToken
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError.missingToken("Project Web API token is incomplete or unreadable. Run Spotify Web API auth again.")
    }

    guard token.isComplete else {
        throw CLIError.missingToken("Project Web API token is incomplete. Run Spotify Web API auth again.")
    }

    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formBody([
        "grant_type": "refresh_token",
        "client_id": token.clientID,
        "refresh_token": token.refreshToken,
    ])

    let payload = try await spotifyJSON(request)
    guard let accessToken = payload["access_token"] as? String else {
        throw CLIError.spotifyResponse("Project Web API token refresh failed: \(payload)")
    }

    token.accessToken = accessToken
    if let refreshToken = payload["refresh_token"] as? String {
        token.refreshToken = refreshToken
    }
    try projectTokenStore.save(token)
    return accessToken
}

func waitForSpotifyActiveDevice(named roomName: String) async throws -> PlayerState {
    let accessToken = try await refreshedProjectAccessToken()
    var lastState: PlayerState?

    for _ in 0 ..< 20 {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIError.spotifyResponse("Spotify player state returned a non-HTTP response")
        }

        if http.statusCode == 204 {
            try await Task.sleep(nanoseconds: 500_000_000)
            continue
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw CLIError.spotifyResponse(String(data: data, encoding: .utf8) ?? "Spotify player state HTTP \(http.statusCode)")
        }

        let state = try JSONDecoder().decode(PlayerState.self, from: data)
        lastState = state
        if state.device.name.caseInsensitiveCompare(roomName) == .orderedSame, state.isPlaying {
            return state
        }

        try await Task.sleep(nanoseconds: 500_000_000)
    }

    throw CLIError.verificationFailed("Spotify active device is not \(roomName); last=\(String(describing: lastState?.device.name))")
}

func waitForSonosSpotifyPlayback(on target: SonosTarget) async throws {
    var lastState: String?
    for _ in 0 ..< 8 {
        lastState = try await currentTransportState(on: target)
        if lastState == "PLAYING" || lastState == "TRANSITIONING" {
            return
        }

        try await Task.sleep(nanoseconds: 350_000_000)
    }

    throw CLIError.verificationFailed("\(target.roomName) did not start Spotify playback; state=\(lastState ?? "unknown")")
}

@discardableResult
func sonosSOAP(host: String, action: String, body: String) async throws -> String {
    let envelope = """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
    """

    var request = URLRequest(url: URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control")!)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
    request.httpBody = Data(envelope.utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    let responseBody = String(data: data, encoding: .utf8) ?? ""
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw CLIError.sonosResponse("Sonos \(action) failed: \(responseBody)")
    }

    return responseBody
}

@discardableResult
func sonosRenderingSOAP(host: String, action: String, body: String) async throws -> String {
    let envelope = """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
    """

    var request = URLRequest(url: URL(string: "http://\(host):1400/MediaRenderer/RenderingControl/Control")!)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
    request.httpBody = Data(envelope.utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    let responseBody = String(data: data, encoding: .utf8) ?? ""
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw CLIError.sonosResponse("Sonos \(action) failed: \(responseBody)")
    }

    return responseBody
}

func spotifyZeroconf(host: String, parameters: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "http://\(host):1400/spotifyzc")!)
    request.httpMethod = parameters["action"] == "getInfo" ? "GET" : "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    if request.httpMethod == "GET" {
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.url = components.url
    } else {
        request.httpBody = formBody(parameters)
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw CLIError.sonosResponse(String(data: data, encoding: .utf8) ?? "Zeroconf HTTP failure")
    }

    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError.sonosResponse("Invalid zeroconf JSON: \(String(data: data, encoding: .utf8) ?? "")")
    }

    return payload
}

func spotifyJSON(_ request: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw CLIError.spotifyResponse("Spotify returned a non-HTTP response")
    }

    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let body = String(data: data, encoding: .utf8) ?? "Invalid Spotify JSON"
        if isSpotifyAuthFailure(statusCode: http.statusCode, payload: nil) {
            throw CLIError.missingToken("Spotify authentication failed: \(body)")
        }
        throw CLIError.spotifyResponse(body)
    }

    guard (200 ..< 300).contains(http.statusCode) else {
        if isSpotifyAuthFailure(statusCode: http.statusCode, payload: payload) {
            throw CLIError.missingToken("Spotify authentication failed: \(payload)")
        }
        throw CLIError.spotifyResponse("Spotify HTTP \(http.statusCode): \(payload)")
    }

    return payload
}

func isSpotifyAuthFailure(statusCode: Int, payload: [String: Any]?) -> Bool {
    guard statusCode == 400 || statusCode == 401 || statusCode == 403 else {
        return false
    }

    guard let error = payload?["error"] as? String else {
        return statusCode == 401 || statusCode == 403
    }

    return ["invalid_grant", "invalid_client", "invalid_token", "unauthorized_client"].contains(error)
}

func formBody(_ parameters: [String: String]) -> Data {
    Data(parameters
        .map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }
        .sorted()
        .joined(separator: "&")
        .utf8)
}

func runCommand(
    _ executable: String,
    _ arguments: [String],
    timeoutSeconds: TimeInterval,
    stopWhen: (@Sendable (String) -> Bool)? = nil
) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    let outputBuffer = CommandOutputBuffer(stopWhen: stopWhen)
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
    outputBuffer.append(outputHandle.readDataToEndOfFile())

    return CommandResult(output: outputBuffer.output, status: process.terminationStatus)
}

func commandArgument() -> String {
    let first = commandLineValuesExcludingOptions().first
    guard let first, isCommand(first) else {
        return "handoff"
    }

    return first
}

func targetArgument() -> String? {
    positionalArgumentsAfterCommand().first
}

func volumeStep() throws -> Int {
    let raw = optionValue("--step") ?? "5"
    guard let step = Int(raw), step >= 5, step <= 25 else {
        throw CLIError.commandFailed("--step must be an integer from 5 to 25")
    }

    return step
}

func desiredVolume() throws -> Int {
    guard let raw = optionValue("--volume") ?? positionalArgumentsAfterCommand().dropFirst().first,
          let volume = Int(raw),
          (0 ... 100).contains(volume)
    else {
        throw CLIError.commandFailed("volume-set requires --volume 0...100")
    }

    return volume
}

func positionalArgumentsAfterCommand() -> [String] {
    let values = commandLineValuesExcludingOptions()
    guard let first = values.first, isCommand(first) else {
        return values
    }

    return Array(values.dropFirst())
}

func commandLineValuesExcludingOptions() -> [String] {
    let optionsWithValues = Set(["--login-id", "--step", "--volume"])
    var values: [String] = []
    var shouldSkipNext = false

    for argument in CommandLine.arguments.dropFirst() {
        if shouldSkipNext {
            shouldSkipNext = false
            continue
        }

        if let optionName = argument.split(separator: "=", maxSplits: 1).first,
           optionsWithValues.contains(String(optionName)) {
            shouldSkipNext = !argument.contains("=")
            continue
        }

        guard !argument.hasPrefix("--") else {
            continue
        }

        values.append(argument)
    }

    return values
}

func hasHelpOption() -> Bool {
    CommandLine.arguments.dropFirst().contains { $0 == "--help" || $0 == "-h" }
}

func printUsage() {
    print(
        """
        Usage:
          sonos-handoff-port [handoff] [room] [--login-id LOGIN_ID]
          sonos-handoff-port playback-status
          sonos-handoff-port sonos-status [room]
          sonos-handoff-port volume-status [room]
          sonos-handoff-port volume-up [room] [--step 5...25]
          sonos-handoff-port volume-down [room] [--step 5...25]
          sonos-handoff-port volume-set [room] --volume 0...100
          sonos-handoff-port volume-mute [room]
          sonos-handoff-port volume-mute-on [room]
          sonos-handoff-port volume-mute-off [room]
          sonos-handoff-port volume-zero-muted [room]
        """
    )
}

func validateOptions() throws {
    let optionsWithValues = Set(["--login-id", "--step", "--volume"])
    let flags = Set(["--help", "-h"])
    let arguments = Array(CommandLine.arguments.dropFirst())
    var shouldSkipNext = false

    for argument in arguments {
        if shouldSkipNext {
            shouldSkipNext = false
            continue
        }

        guard argument.hasPrefix("-") else {
            continue
        }

        if flags.contains(argument) {
            continue
        }

        let optionName = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
        if optionsWithValues.contains(optionName) {
            shouldSkipNext = !argument.contains("=")
            continue
        }

        throw CLIError.commandFailed("Unknown option: \(argument)")
    }
}

func isCommand(_ value: String) -> Bool {
    switch value {
    case "handoff", "playback-status", "sonos-status", "volume-up", "volume-down", "volume-set", "volume-status", "volume-mute", "volume-mute-on", "volume-mute-off", "volume-zero-muted":
        return true
    default:
        return false
    }
}

func positionalArgument(at index: Int) -> String? {
    let values = positionalArgumentsAfterCommand()
    guard index < values.count else {
        return nil
    }

    return values[index].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}


func optionValue(_ option: String) -> String? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    for (index, argument) in arguments.enumerated() where argument == option {
        guard index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    let prefix = "\(option)="
    return arguments
        .first { $0.hasPrefix(prefix) }?
        .dropFirst(prefix.count)
        .description
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
}

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return nil
    }

    let range = NSRange(text.startIndex ..< text.endIndex, in: text)
    guard
        let match = regex.firstMatch(in: text, range: range),
        match.numberOfRanges > 1,
        let captureRange = Range(match.range(at: 1), in: text)
    else {
        return nil
    }

    return String(text[captureRange])
}

func sha1Hex(_ value: String) -> String {
    Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func loginID(fromDesktopTokenKey key: String) -> String? {
    key.split(separator: "/").last.map(String.init)?.nilIfEmpty
}

func xmlUnescape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&amp;", with: "&")
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? self
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
