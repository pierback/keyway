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
    func validatedStatus() async -> ConnectTokenStatus
    func deleteProjectToken() throws
}

public struct ConnectTokenStatusStore: ConnectTokenStatusChecking, @unchecked Sendable {
    private let applicationSupportDirectory: URL
    private let projectTokenStore: ProjectWebAPITokenStore
    private let projectAccessTokenProvider: SpotifyProjectAccessTokenProvider

    public init(
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory,
        urlSession: URLSession = .shared
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.projectTokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        self.projectAccessTokenProvider = SpotifyProjectAccessTokenProvider(
            applicationSupportDirectory: applicationSupportDirectory,
            tokenClient: SpotifyConnectTokenClient(urlSession: urlSession)
        )
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

    public func validatedStatus() async -> ConnectTokenStatus {
        let desktopTokenAvailable = FileManager.default.fileExists(atPath: desktopTokenURL.path)
        do {
            _ = try await projectAccessTokenProvider.accessToken()
            return ConnectTokenStatus(
                desktopTokenAvailable: desktopTokenAvailable,
                projectTokenAvailable: true
            )
        } catch {
            return ConnectTokenStatus(
                desktopTokenAvailable: desktopTokenAvailable,
                projectTokenAvailable: false
            )
        }
    }

    public func deleteProjectToken() throws {
        try projectTokenStore.delete()
    }

    private func hasCompleteProjectToken() -> Bool {
        projectTokenStore.hasCompleteToken()
    }
}
