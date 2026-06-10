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
    private let urlSession: URLSession
    private let projectTokenStore: ProjectWebAPITokenStore
    private let projectAccessTokenProvider: SpotifyProjectAccessTokenProvider

    public init(
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory,
        urlSession: URLSession = .shared
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.urlSession = urlSession
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
            let accessToken = try await projectAccessTokenProvider.accessToken()
            let accountProductAvailable = try await accountProductAvailable(accessToken: accessToken)
            return ConnectTokenStatus(
                desktopTokenAvailable: desktopTokenAvailable,
                projectTokenAvailable: accountProductAvailable
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

    private func accountProductAvailable(accessToken: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            return false
        }
        let account = try JSONDecoder().decode(SpotifyAccountProfile.self, from: data)
        return account.product?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private struct SpotifyAccountProfile: Decodable {
    let product: String?
}
