import Foundation

public struct SavedTarget: Codable, Equatable, Sendable {
    public let alias: String
    public let spotifyDeviceName: String
    public let lastSpotifyDeviceId: String?

    public init(alias: String, spotifyDeviceName: String, lastSpotifyDeviceId: String? = nil) {
        self.alias = alias
        self.spotifyDeviceName = spotifyDeviceName
        self.lastSpotifyDeviceId = lastSpotifyDeviceId
    }
}

