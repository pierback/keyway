import Foundation

struct ConnectSonosTarget: Sendable {
    let roomName: String
    let host: String
    let version: String?
    let deviceID: String?
}

struct ConnectDesktopToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

struct ConnectDesktopCredential {
    let loginID: String
    let token: ConnectDesktopToken
}

struct ConnectPlayerState: Decodable, Sendable {
    let isPlaying: Bool
    let device: ConnectPlayerDevice

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case device
    }
}

struct ConnectPlayerDevice: Decodable, Sendable {
    let name: String
    let isRestricted: Bool
    let volumePercent: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
    }
}

struct ConnectHandoffError: Error {
    let code: TransferErrorCode
    let message: String

    init(_ code: TransferErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension ConnectHandoffError: LocalizedError {
    var errorDescription: String? {
        message
    }
}

public enum SpotifyAuthRecovery {
    public static func isAuthRequired(_ error: Error) -> Bool {
        guard let error = error as? ConnectHandoffError else {
            return false
        }

        return error.code == .authRequired
    }

    public static func message(for error: Error) -> String? {
        guard let error = error as? ConnectHandoffError,
              error.code == .authRequired
        else {
            return nil
        }

        return error.message
    }
}
