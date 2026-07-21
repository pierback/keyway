import Foundation

public struct ConnectTokenStatus: Equatable, Sendable {
    public let desktopTokenAvailable: Bool
    public let projectTokenAvailable: Bool

    public init(desktopTokenAvailable: Bool, projectTokenAvailable: Bool) {
        self.desktopTokenAvailable = desktopTokenAvailable
        self.projectTokenAvailable = projectTokenAvailable
    }
}

public protocol ConnectTokenStatusChecking: Sendable {
    func validatedStatus() async throws -> ConnectTokenStatus
    func deleteProjectToken() throws
}

public struct ConnectTokenStatusStore: ConnectTokenStatusChecking, @unchecked Sendable {
    private let desktopTokenURL: URL
    private let urlSession: URLSession
    private let projectTokenStore: ProjectWebAPITokenStore
    private let projectAccessTokenProvider: SpotifyProjectAccessTokenProvider

    public init(
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory,
        urlSession: URLSession = .shared
    ) {
        self.desktopTokenURL = applicationSupportDirectory.appendingPathComponent("spotify-desktop-connect-tokens.json")
        self.urlSession = urlSession
        self.projectTokenStore = ProjectWebAPITokenStore(applicationSupportDirectory: applicationSupportDirectory)
        self.projectAccessTokenProvider = SpotifyProjectAccessTokenProvider(
            applicationSupportDirectory: applicationSupportDirectory,
            tokenClient: SpotifyConnectTokenClient(urlSession: urlSession)
        )
    }

    public func validatedStatus() async throws -> ConnectTokenStatus {
        let desktopTokenAvailable = try desktopTokenAvailable()
        guard let projectToken = try projectTokenStore.load(), projectToken.hasCredentials else {
            return ConnectTokenStatus(
                desktopTokenAvailable: desktopTokenAvailable,
                projectTokenAvailable: false
            )
        }

        do {
            let accessToken = try await projectAccessTokenProvider.accessToken()
            let projectTokenAvailable: Bool
            do {
                projectTokenAvailable = try await accountProductAvailable(accessToken: accessToken)
            } catch let error as ConnectHandoffError where error.code == .authRequired {
                let refreshedAccessToken = try await projectAccessTokenProvider.refreshAccessTokenAfterAuthFailure()
                projectTokenAvailable = try await accountProductAvailable(accessToken: refreshedAccessToken)
            }
            return ConnectTokenStatus(
                desktopTokenAvailable: desktopTokenAvailable,
                projectTokenAvailable: projectTokenAvailable
            )
        } catch let error as ConnectHandoffError where error.code == .authRequired {
            return ConnectTokenStatus(
                desktopTokenAvailable: desktopTokenAvailable,
                projectTokenAvailable: false
            )
        }
    }

    public func deleteProjectToken() throws {
        try projectTokenStore.delete()
    }

    private func desktopTokenAvailable() throws -> Bool {
        guard FileManager.default.fileExists(atPath: desktopTokenURL.path) else {
            return false
        }

        let tokens = try JSONDecoder().decode(
            [String: ConnectDesktopToken].self,
            from: ProjectWebAPITokenStore.sensitiveFileData(at: desktopTokenURL)
        )
        guard let key = tokens.keys.sorted().first,
              SonosRuntimeSupport.loginID(fromDesktopTokenKey: key) != nil,
              let token = tokens[key]
        else {
            return false
        }

        return !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func accountProductAvailable(accessToken: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectHandoffError(.unsupported, "Spotify account check returned a non-HTTP response.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ConnectHandoffError(.authRequired, "Spotify account authentication failed (HTTP \(http.statusCode)).")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ConnectHandoffError(.unsupported, "Spotify account check failed (HTTP \(http.statusCode)).")
        }
        let account = try JSONDecoder().decode(SpotifyAccountProfile.self, from: data)
        return account.product?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private struct SpotifyAccountProfile: Decodable {
    let product: String?
}
