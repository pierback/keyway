import Foundation

public protocol SpotifyControlling {
    func currentPlayback() async throws -> PlaybackState?
}

public final class SpotifyClient: SpotifyControlling {
    private let tokenStore: TokenStoring
    private let configStore: ConfigStoring
    private let urlSession: URLSession

    public init(
        tokenStore: TokenStoring,
        configStore: ConfigStoring,
        urlSession: URLSession = .shared
    ) {
        self.tokenStore = tokenStore
        self.configStore = configStore
        self.urlSession = urlSession
    }

    public func currentPlayback() async throws -> PlaybackState? {
        let token = try await accessToken()
        let endpoint = SpotifyEndpoints.apiBaseURL.appending(path: "me/player")
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransferErrorCode.unsupported
        }

        if httpResponse.statusCode == 204 {
            return nil
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw mapRequestFailure(statusCode: httpResponse.statusCode, data: data)
        }

        let payload = try JSONDecoder().decode(CurrentPlaybackResponse.self, from: data)
        return PlaybackState(
            isPlaying: payload.isPlaying,
            deviceID: payload.device.id,
            deviceName: payload.device.name
        )
    }

    private func accessToken() async throws -> String {
        let config = try configStore.load()
        guard let clientID = config.spotifyClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else {
            throw TransferErrorCode.authRequired
        }

        guard let refreshToken = try tokenStore.loadRefreshToken(), !refreshToken.isEmpty else {
            throw TransferErrorCode.authRequired
        }

        var request = URLRequest(url: SpotifyEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransferErrorCode.unsupported
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw mapRequestFailure(statusCode: httpResponse.statusCode, data: data)
        }

        let payload = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
        if let replacementRefreshToken = payload.refreshToken, !replacementRefreshToken.isEmpty {
            try tokenStore.saveRefreshToken(replacementRefreshToken)
        }

        return payload.accessToken
    }

    private func mapRequestFailure(statusCode: Int, data: Data?) -> TransferErrorCode {
        if statusCode == 401 || statusCode == 403 {
            return .authRequired
        }

        return .unsupported
    }

    private func formEncodedBody(_ parameters: [String: String]) -> Data {
        let value = parameters.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .sorted()
        .joined(separator: "&")

        return Data(value.utf8)
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}

private struct CurrentPlaybackResponse: Decodable {
    let isPlaying: Bool
    let device: PlaybackDevice

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case device
    }
}

private struct PlaybackDevice: Decodable {
    let id: String?
    let name: String
}

private struct RefreshTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
