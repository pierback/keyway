import Foundation

enum SpotifyAuthCallbackRequest {
    static func authorizationCode(from data: Data, expectedState: String) throws -> String {
        guard
            let request = String(data: data, encoding: .utf8),
            let requestLine = request.components(separatedBy: "\r\n").first
        else {
            throw SpotifyAuthError.missingAuthorizationCode
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            throw SpotifyAuthError.missingAuthorizationCode
        }

        guard parts[0] == "GET" else {
            throw SpotifyAuthError.missingAuthorizationCode
        }

        let requestPath = String(parts[1])
        guard let components = URLComponents(
            string: "http://\(SpotifyAuthCallbackServer.host):\(SpotifyAuthCallbackServer.port)\(requestPath)"
        ) else {
            throw SpotifyAuthError.missingAuthorizationCode
        }

        guard components.path == SpotifyAuthCallbackServer.path else {
            throw SpotifyAuthError.missingAuthorizationCode
        }

        let queryItems = components.queryItems ?? []
        let state = queryItems.first(where: { $0.name == "state" })?.value
        guard state == expectedState else {
            throw SpotifyAuthError.invalidCallbackState
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw SpotifyAuthError.missingAuthorizationCode
        }

        return code
    }
}
