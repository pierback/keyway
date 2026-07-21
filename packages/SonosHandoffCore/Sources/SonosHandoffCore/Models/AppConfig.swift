public struct AppConfig: Codable, Equatable, Sendable {
    public let spotifyClientID: String?

    public init(spotifyClientID: String? = nil) {
        self.spotifyClientID = spotifyClientID
    }
}
