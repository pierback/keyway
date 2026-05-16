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
    private let projectTokenStore: ProjectWebAPITokenStore

    public init(
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.projectTokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
    }

    public var desktopTokenURL: URL {
        applicationSupportDirectory.appendingPathComponent("spotify-desktop-connect-tokens.json")
    }

    public var projectTokenURL: URL {
        projectTokenStore.tokenURL
    }

    public func status() -> ConnectTokenStatus {
        ConnectTokenStatus(
            desktopTokenAvailable: FileManager.default.fileExists(atPath: desktopTokenURL.path),
            projectTokenAvailable: hasCompleteProjectToken()
        )
    }

    public func deleteProjectToken() throws {
        try projectTokenStore.delete()
    }

    private func hasCompleteProjectToken() -> Bool {
        projectTokenStore.hasCompleteToken()
    }
}
