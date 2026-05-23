import Foundation

struct SpotifyRefreshedAccessToken: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
}

struct SpotifyConnectTokenClient: Sendable {
    static let desktopClientID = "65b708073fc0480ea92a077233ca87bd"
    static let sonosClientID = "9b377073ea334637b1406f329ce005de"
    private static let maxRateLimitRetries = 2

    private let urlSession: URLSession

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    func refreshedAccessToken(
        clientID: String,
        refreshToken: String,
        failureMessage: String
    ) async throws -> SpotifyRefreshedAccessToken {
        var request = URLRequest(url: SpotifyEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SonosRuntimeSupport.formBody([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ])

        let payload = try await spotifyJSON(request)
        guard let accessToken = payload["access_token"] as? String else {
            throw ConnectHandoffError(.authRequired, failureMessage)
        }

        return SpotifyRefreshedAccessToken(
            accessToken: accessToken,
            refreshToken: payload["refresh_token"] as? String,
            expiresIn: Self.expiresIn(from: payload)
        )
    }

    func spotifyConnectAuthorizationCode(from desktopAccessToken: String) async throws -> String {
        var request = URLRequest(url: SpotifyEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Spotify/124300420 Win32_x86_64/0 (PC desktop)", forHTTPHeaderField: "User-Agent")
        request.setValue("en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.httpBody = SonosRuntimeSupport.formBody([
            "audience": Self.sonosClientID,
            "client_id": Self.desktopClientID,
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "requested_token_type": "urn:spotify:params:oauth:authorization_code",
            "resource": "urn:spotify:resources:connect",
            "scope": "streaming",
            "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "subject_token": desktopAccessToken,
        ])

        let payload = try await spotifyJSON(request)
        guard let accessToken = payload["access_token"] as? String else {
            throw ConnectHandoffError(.authRequired, "Spotify Connect token exchange failed.")
        }
        return accessToken
    }

    private static func expiresIn(from payload: [String: Any]) -> Int {
        if let expiresIn = payload["expires_in"] as? Int {
            return max(expiresIn, 60)
        }
        if let expiresIn = payload["expires_in"] as? Double {
            return max(Int(expiresIn), 60)
        }
        return 3600
    }

    private func spotifyJSON(_ request: URLRequest) async throws -> [String: Any] {
        for attempt in 0 ... Self.maxRateLimitRetries {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ConnectHandoffError(.unsupported, "Spotify returned a non-HTTP response.")
            }

            if http.statusCode == 429, attempt < Self.maxRateLimitRetries {
                try await Self.sleepForRateLimitRetry(http)
                continue
            }

            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if SonosRuntimeSupport.isSpotifyAuthFailure(statusCode: http.statusCode, payload: nil) {
                    throw ConnectHandoffError(.authRequired, "Spotify authentication failed (HTTP \(http.statusCode)).")
                }
                throw ConnectHandoffError(.unsupported, "Spotify returned an invalid response (HTTP \(http.statusCode)).")
            }

            guard (200 ..< 300).contains(http.statusCode) else {
                if SonosRuntimeSupport.isSpotifyAuthFailure(statusCode: http.statusCode, payload: payload) {
                    throw ConnectHandoffError(.authRequired, "Spotify authentication failed (HTTP \(http.statusCode)).")
                }
                throw ConnectHandoffError(.unsupported, "Spotify request failed (HTTP \(http.statusCode)).")
            }

            return payload
        }

        throw ConnectHandoffError(.unsupported, "Spotify request rate limited.")
    }

    private static func sleepForRateLimitRetry(_ response: HTTPURLResponse) async throws {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
        try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 5) * 1_000_000_000))
    }
}
