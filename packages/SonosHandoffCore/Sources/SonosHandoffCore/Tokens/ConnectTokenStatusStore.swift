import Foundation

public struct ConnectTokenStatus: Equatable, Sendable {
    public let desktopTokenAvailable: Bool
    public let projectTokenAvailable: Bool

    public init(desktopTokenAvailable: Bool, projectTokenAvailable: Bool) {
        self.desktopTokenAvailable = desktopTokenAvailable
        self.projectTokenAvailable = projectTokenAvailable
    }

    public var isReadyForHandoff: Bool {
        desktopTokenAvailable && projectTokenAvailable
    }
}

public protocol ConnectTokenStatusChecking: Sendable {
    func status() -> ConnectTokenStatus
    func deleteProjectToken() throws
}

public struct ConnectTokenStatusStore: ConnectTokenStatusChecking, @unchecked Sendable {
    private let applicationSupportDirectory: URL

    public init(
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var desktopTokenURL: URL {
        applicationSupportDirectory.appendingPathComponent("spotify-desktop-connect-tokens.json")
    }

    public var projectTokenURL: URL {
        applicationSupportDirectory.appendingPathComponent("project-webapi-token.json")
    }

    public func status() -> ConnectTokenStatus {
        ConnectTokenStatus(
            desktopTokenAvailable: FileManager.default.fileExists(atPath: desktopTokenURL.path),
            projectTokenAvailable: hasCompleteProjectToken()
        )
    }

    public func deleteProjectToken() throws {
        guard FileManager.default.fileExists(atPath: projectTokenURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: projectTokenURL)
    }

    private func hasCompleteProjectToken() -> Bool {
        guard
            FileManager.default.fileExists(atPath: projectTokenURL.path),
            let data = try? Data(contentsOf: projectTokenURL),
            let token = try? JSONDecoder().decode(ProjectWebAPITokenStatusFile.self, from: data)
        else {
            return false
        }

        return !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(token.clientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct ProjectWebAPITokenStatusFile: Decodable {
    let accessToken: String
    let refreshToken: String
    let clientID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
    }
}
