import Foundation
import Testing
@testable import SonosHandoffCore

struct SpotifyAuthCallbackRequestTests {
    @Test
    func parsesAuthorizationCodeForExpectedState() throws {
        let request = Self.request(path: "/callback?code=authorization-code&state=expected-state")

        let code = try SpotifyAuthCallbackRequest.authorizationCode(
            from: Data(request.utf8),
            expectedState: "expected-state"
        )

        #expect(code == "authorization-code")
    }

    @Test
    func rejectsInvalidState() throws {
        let request = Self.request(path: "/callback?code=authorization-code&state=wrong-state")

        #expect(throws: SpotifyAuthError.invalidCallbackState) {
            try SpotifyAuthCallbackRequest.authorizationCode(
                from: Data(request.utf8),
                expectedState: "expected-state"
            )
        }
    }

    @Test
    func rejectsMissingCode() throws {
        let request = Self.request(path: "/callback?state=expected-state")

        #expect(throws: SpotifyAuthError.missingAuthorizationCode) {
            try SpotifyAuthCallbackRequest.authorizationCode(
                from: Data(request.utf8),
                expectedState: "expected-state"
            )
        }
    }

    @Test
    func rejectsUnexpectedCallbackPath() throws {
        let request = Self.request(path: "/wrong?code=authorization-code&state=expected-state")

        #expect(throws: SpotifyAuthError.missingAuthorizationCode) {
            try SpotifyAuthCallbackRequest.authorizationCode(
                from: Data(request.utf8),
                expectedState: "expected-state"
            )
        }
    }

    private static func request(path: String) -> String {
        """
        GET \(path) HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """
    }
}
