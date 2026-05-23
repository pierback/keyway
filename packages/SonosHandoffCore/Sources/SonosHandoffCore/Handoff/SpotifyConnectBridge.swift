import Foundation
import os

enum SpotifyVolumeMirrorResult: Equatable, Sendable {
    case applied
    case skipped(SpotifyVolumeMirrorSkipReason)
}

enum SpotifyVolumeMirrorSkipReason: Equatable, Sendable {
    case activeDeviceMismatch(lastDeviceName: String?)
    case restrictedDevice(deviceName: String)
    case spotifyHTTPStatus(Int)
    case error(String)
}

private enum SpotifyVolumeWriteError: Error, Sendable {
    case spotifyHTTPStatus(Int, String)
}

struct SpotifyConnectBridge: Sendable {
    private static let volumeMirrorLogger = os.Logger(
        subsystem: "com.fpieringer.SonosHandoffCore",
        category: "SpotifyVolumeMirror"
    )

    private let urlSession: URLSession
    private let tokenClient: SpotifyConnectTokenClient
    private let desktopCredentialProvider: SpotifyDesktopCredentialProvider
    private let projectAccessTokenProvider: SpotifyProjectAccessTokenProvider

    init(
        loginID: String?,
        appSupport: URL,
        urlSession: URLSession
    ) {
        self.urlSession = urlSession
        let tokenClient = SpotifyConnectTokenClient(urlSession: urlSession)
        self.tokenClient = tokenClient
        self.desktopCredentialProvider = SpotifyDesktopCredentialProvider(
            preferredLoginID: loginID,
            applicationSupportDirectory: appSupport,
            tokenClient: tokenClient
        )
        self.projectAccessTokenProvider = SpotifyProjectAccessTokenProvider(
            applicationSupportDirectory: appSupport,
            tokenClient: tokenClient
        )
    }

    func refreshedDesktopCredential() async throws -> ConnectDesktopCredential {
        try await desktopCredentialProvider.credential()
    }

    func spotifyConnectAuthorizationCode(from desktopAccessToken: String) async throws -> String {
        try await tokenClient.spotifyConnectAuthorizationCode(from: desktopAccessToken)
    }

    func verifyActiveDeviceIfAvailable(named roomName: String) async {
        do {
            _ = try await verifyActiveDevice(named: roomName)
        } catch {
            return
        }
    }

    func verifyActiveDevice(named roomName: String) async throws -> ConnectPlayerState {
        try await waitForActiveDevice(named: roomName)
    }

    func activePlaybackDeviceStatus() async throws -> SpotifyPlaybackDeviceStatus? {
        let accessToken = try await projectAccessTokenProvider.accessToken()
        guard let state = try await currentPlayerStateWithAuthRetry(accessToken: accessToken) else {
            return nil
        }

        return SpotifyPlaybackDeviceStatus(
            deviceName: state.device.name,
            isPlaying: state.isPlaying,
            volumePercent: state.device.volumePercent
        )
    }

    func setActivePlaybackDeviceVolume(_ requestedVolume: Int) async throws -> Int {
        let volume = max(0, min(100, requestedVolume))
        let accessToken = try await projectAccessTokenProvider.accessToken()
        guard let state = try await currentPlayerStateWithAuthRetry(accessToken: accessToken) else {
            throw ConnectHandoffError(.transferVerificationFailed, "Spotify has no active playback device.")
        }
        guard !state.device.isRestricted else {
            throw ConnectHandoffError(.transferVerificationFailed, "Spotify active device is restricted: \(state.device.name).")
        }

        do {
            try await setActiveDeviceVolume(volume, accessToken: accessToken)
        } catch let error as SpotifyVolumeWriteError {
            switch error {
            case .spotifyHTTPStatus(let statusCode, let body):
                throw ConnectHandoffError(
                    .transferVerificationFailed,
                    body.isEmpty ? "Spotify volume HTTP \(statusCode)" : body
                )
            }
        }
        return volume
    }

    @discardableResult
    func setActiveDeviceVolumeIfNeeded(roomName: String, volume: Int) async -> SpotifyVolumeMirrorResult {
        do {
            let accessToken = try await projectAccessTokenProvider.accessToken()
            let waiter = activeDeviceWaiter()
            let result = try await waiter.waitForRoom(
                named: roomName,
                accessToken: accessToken,
                policy: .volumeMirror
            )
            guard let state = result.state else {
                let lastDeviceName = result.lastDeviceName ?? "none"
                Self.volumeMirrorLogger.info("SpotifyVolumeMirror result=skipped reason=active_device_mismatch room=\(roomName, privacy: .public) volume=\(volume, privacy: .public) lastDevice=\(lastDeviceName, privacy: .public)")
                return .skipped(.activeDeviceMismatch(lastDeviceName: result.lastDeviceName))
            }
            guard !state.device.isRestricted else {
                Self.volumeMirrorLogger.info("SpotifyVolumeMirror result=skipped reason=restricted_device room=\(roomName, privacy: .public) device=\(state.device.name, privacy: .public) volume=\(volume, privacy: .public)")
                return .skipped(.restrictedDevice(deviceName: state.device.name))
            }

            try await setActiveDeviceVolume(volume, accessToken: accessToken)

            Self.volumeMirrorLogger.info("SpotifyVolumeMirror result=applied room=\(roomName, privacy: .public) volume=\(volume, privacy: .public)")
            return .applied
        } catch let error as SpotifyVolumeWriteError {
            switch error {
            case .spotifyHTTPStatus(let statusCode, let body):
                Self.volumeMirrorLogger.info("SpotifyVolumeMirror result=skipped reason=spotify_http_status room=\(roomName, privacy: .public) volume=\(volume, privacy: .public) status=\(statusCode, privacy: .public) body=\(body, privacy: .public)")
                return .skipped(.spotifyHTTPStatus(statusCode))
            }
        } catch {
            Self.volumeMirrorLogger.info("SpotifyVolumeMirror result=skipped reason=error room=\(roomName, privacy: .public) volume=\(volume, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .skipped(.error(error.localizedDescription))
        }
    }

    private func waitForActiveDevice(named roomName: String) async throws -> ConnectPlayerState {
        let accessToken = try await projectAccessTokenProvider.accessToken()
        let waiter = activeDeviceWaiter()
        let result = try await waiter.waitForRoom(
            named: roomName,
            accessToken: accessToken,
            policy: .transferVerification
        )
        guard let state = result.state else {
            throw ConnectHandoffError(.transferVerificationFailed, "Spotify active device is not \(roomName); last=\(result.lastDeviceName ?? "none")")
        }

        return state
    }

    private static let maxRateLimitRetries = 2

    private func currentPlayerState(accessToken: String) async throws -> ConnectPlayerState? {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        for attempt in 0 ... Self.maxRateLimitRetries {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ConnectHandoffError(.transferVerificationFailed, "Spotify returned a non-HTTP player response.")
            }
            if http.statusCode == 429, attempt < Self.maxRateLimitRetries {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 5) * 1_000_000_000))
                continue
            }
            if http.statusCode == 204 {
                return nil
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ConnectHandoffError(.authRequired, "Spotify player authentication failed (HTTP \(http.statusCode)).")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw ConnectHandoffError(.transferVerificationFailed, "Spotify player request failed (HTTP \(http.statusCode)).")
            }

            return try JSONDecoder().decode(ConnectPlayerState.self, from: data)
        }

        throw ConnectHandoffError(.transferVerificationFailed, "Spotify player rate limited.")
    }

    private func currentPlayerStateWithAuthRetry(accessToken: String) async throws -> ConnectPlayerState? {
        do {
            return try await currentPlayerState(accessToken: accessToken)
        } catch let error as ConnectHandoffError where error.code == .authRequired {
            let refreshedAccessToken = try await projectAccessTokenProvider.refreshAccessTokenAfterAuthFailure()
            return try await currentPlayerState(accessToken: refreshedAccessToken)
        }
    }

    private func setActiveDeviceVolume(_ volume: Int, accessToken: String) async throws {
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/volume")!
        components.queryItems = [URLQueryItem(name: "volume_percent", value: String(volume))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        var didRefreshAccessToken = false

        for attempt in 0 ... Self.maxRateLimitRetries {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SpotifyVolumeWriteError.spotifyHTTPStatus(-1, "Spotify volume request returned a non-HTTP response.")
            }

            if http.statusCode == 429, attempt < Self.maxRateLimitRetries {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 5) * 1_000_000_000))
                continue
            }

            if (http.statusCode == 401 || http.statusCode == 403), !didRefreshAccessToken {
                let refreshedAccessToken = try await projectAccessTokenProvider.refreshAccessTokenAfterAuthFailure()
                request.setValue("Bearer \(refreshedAccessToken)", forHTTPHeaderField: "Authorization")
                didRefreshAccessToken = true
                continue
            }

            guard http.statusCode == 204 || (200 ..< 300).contains(http.statusCode) else {
                throw SpotifyVolumeWriteError.spotifyHTTPStatus(http.statusCode, "Spotify volume request failed.")
            }

            return
        }

        throw SpotifyVolumeWriteError.spotifyHTTPStatus(429, "Spotify volume request rate limited.")
    }

    private func activeDeviceWaiter() -> SpotifyActiveDeviceWaiter {
        SpotifyActiveDeviceWaiter { accessToken in
            try await currentPlayerStateWithAuthRetry(accessToken: accessToken)
        }
    }
}
