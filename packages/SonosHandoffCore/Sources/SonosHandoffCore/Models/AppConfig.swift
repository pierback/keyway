import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public let targets: [SavedTarget]
    public let spotifyClientID: String?
    public let spotifyVirtualDisplayName: String?

    public init(
        targets: [SavedTarget] = [],
        spotifyClientID: String? = nil,
        spotifyVirtualDisplayName: String? = nil
    ) {
        self.targets = targets
        self.spotifyClientID = spotifyClientID
        self.spotifyVirtualDisplayName = spotifyVirtualDisplayName
    }

    enum CodingKeys: String, CodingKey {
        case targets
        case spotifyClientID
        case spotifyVirtualDisplayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targets = try container.decodeIfPresent([SavedTarget].self, forKey: .targets) ?? []
        spotifyClientID = try container.decodeIfPresent(String.self, forKey: .spotifyClientID)
        spotifyVirtualDisplayName = try container.decodeIfPresent(String.self, forKey: .spotifyVirtualDisplayName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targets, forKey: .targets)
        try container.encodeIfPresent(spotifyClientID, forKey: .spotifyClientID)
        try container.encodeIfPresent(spotifyVirtualDisplayName, forKey: .spotifyVirtualDisplayName)
    }
}
