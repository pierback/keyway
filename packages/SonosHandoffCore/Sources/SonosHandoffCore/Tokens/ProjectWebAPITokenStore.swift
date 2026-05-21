import Foundation

public struct ProjectWebAPIToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var clientID: String
    public var expiresAt: Int?

    public init(
        accessToken: String,
        refreshToken: String,
        clientID: String,
        expiresAt: Int? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.expiresAt = expiresAt
    }

    public var isComplete: Bool {
        hasCredentials && expiresAt != nil
    }

    public var hasCredentials: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        clientID = try container.decode(String.self, forKey: .clientID)
        expiresAt = try container.decodeIfPresent(Int.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(clientID, forKey: .clientID)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }
}

public struct ProjectWebAPITokenStore: Sendable {
    public let tokenURL: URL

    public init(applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory) {
        self.tokenURL = applicationSupportDirectory.appendingPathComponent("project-webapi-token.json")
    }

    static let maxTokenFileSize = 1_048_576

    public func load() throws -> ProjectWebAPIToken? {
        guard FileManager.default.fileExists(atPath: tokenURL.path) else {
            return nil
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        if let fileSize = attributes[.size] as? Int, fileSize > Self.maxTokenFileSize {
            return nil
        }

        return try JSONDecoder().decode(ProjectWebAPIToken.self, from: Data(contentsOf: tokenURL))
    }

    public func save(_ token: ProjectWebAPIToken) throws {
        try FileManager.default.createDirectory(
            at: tokenURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.projectWebAPITokenFile.encode(token)
        try data.write(to: tokenURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tokenURL.path
        )
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: tokenURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: tokenURL)
    }

    public func hasCompleteToken() -> Bool {
        guard let token = try? load() else {
            return false
        }

        return token.isComplete
    }
}

private extension JSONEncoder {
    static var projectWebAPITokenFile: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
