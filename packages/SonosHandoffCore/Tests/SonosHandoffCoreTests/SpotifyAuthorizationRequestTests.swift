import Foundation
import Testing
@testable import SonosHandoffCore

struct SpotifyAuthorizationRequestTests {
    @Test
    func buildsAuthorizationURLWithPKCEChallengeAndState() throws {
        let request = SpotifyAuthorizationRequest(
            clientID: "client-id",
            redirectURI: URL(string: "http://127.0.0.1:43821/callback")!,
            state: "state-token",
            codeVerifier: "verifier"
        )

        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "accounts.spotify.com")
        #expect(components.path == "/authorize")
        #expect(queryItems["response_type"] == "code")
        #expect(queryItems["client_id"] == "client-id")
        #expect(queryItems["redirect_uri"] == "http://127.0.0.1:43821/callback")
        #expect(queryItems["state"] == "state-token")
        #expect(queryItems["code_challenge_method"] == "S256")
        #expect(queryItems["code_challenge"] == SpotifyAuthorizationRequest.codeChallenge(for: "verifier"))
        #expect(queryItems["scope"] == SpotifyScopes.required.joined(separator: " "))
    }

    @Test
    func derivesRFC7636CodeChallenge() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        let challenge = SpotifyAuthorizationRequest.codeChallenge(for: verifier)

        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}
