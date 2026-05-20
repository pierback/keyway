import Foundation
import Network

enum SpotifyAuthCallbackServer {
    static let host = "127.0.0.1"
    static let port: UInt16 = 43821
    static let path = "/callback"
    static let timeoutSeconds = 120

    static var redirectURI: URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    static func completeAuthorization(
        expectedState: String,
        completion: @escaping @Sendable (String) async throws -> Void,
        openAuthorizationURL: @escaping @Sendable () -> Bool
    ) async throws {
        guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
            throw SpotifyAuthError.callbackListenerFailed
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: listenerPort)
        } catch {
            throw SpotifyAuthError.callbackListenerFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "keyway.spotify-auth")
            let resolver = SpotifyAuthCallbackResolver(
                expectedState: expectedState,
                continuation: continuation,
                completion: completion
            )
            let browser = OneShotBrowserOpener(openAuthorizationURL)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let didOpen = browser.openOnce() else {
                        return
                    }
                    guard didOpen else {
                        resolver.finish(with: .failure(SpotifyAuthError.couldNotOpenBrowser))
                        listener.cancel()
                        return
                    }
                case .failed:
                    resolver.finish(with: .failure(SpotifyAuthError.callbackListenerFailed))
                    listener.cancel()
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                resolver.handle(connection: connection, listener: listener)
            }

            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                resolver.finish(with: .failure(SpotifyAuthError.callbackTimedOut))
                listener.cancel()
            }
        }
    }
}

private final class OneShotBrowserOpener: @unchecked Sendable {
    private let opener: @Sendable () -> Bool
    private let lock = NSLock()
    private var didOpen = false

    init(_ opener: @escaping @Sendable () -> Bool) {
        self.opener = opener
    }

    func openOnce() -> Bool? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !didOpen else {
            return nil
        }

        didOpen = true
        return opener()
    }
}

private final class SpotifyAuthCallbackResolver: @unchecked Sendable {
    private let expectedState: String
    private let completion: @Sendable (String) async throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(
        expectedState: String,
        continuation: CheckedContinuation<Void, Error>,
        completion: @escaping @Sendable (String) async throws -> Void
    ) {
        self.expectedState = expectedState
        self.continuation = continuation
        self.completion = completion
    }

    func handle(connection: NWConnection, listener: NWListener) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                self.finish(with: .failure(SpotifyAuthError.callbackListenerFailed))
                listener.cancel()
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, _, error in
            if let error {
                self.finish(with: .failure(error))
                connection.cancel()
                listener.cancel()
                return
            }

            guard let data else {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed before an authorization code was received. You can close this window.",
                    result: .failure(SpotifyAuthError.missingAuthorizationCode)
                )
                return
            }

            let code: String
            do {
                code = try SpotifyAuthCallbackRequest.authorizationCode(
                    from: data,
                    expectedState: expectedState
                )
            } catch SpotifyAuthError.invalidCallbackState {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed because the callback state did not match. You can close this window.",
                    result: .failure(SpotifyAuthError.invalidCallbackState)
                )
                return
            } catch {
                self.sendResponse(
                    connection: connection,
                    listener: listener,
                    body: "Spotify sign-in failed because Spotify did not return an authorization code. You can close this window.",
                    result: .failure(SpotifyAuthError.missingAuthorizationCode)
                )
                return
            }

            Task {
                do {
                    try await self.completion(code)
                    self.sendResponse(
                        connection: connection,
                        listener: listener,
                        body: "Spotify sign-in completed. You can close this window and return to Keyway.",
                        result: .success(())
                    )
                } catch {
                    self.sendResponse(
                        connection: connection,
                        listener: listener,
                        body: "Spotify sign-in failed while saving the token. You can close this window and try again from Keyway.",
                        result: .failure(error)
                    )
                }
            }
        }
    }

    func finish(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else {
            return
        }

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func sendResponse(
        connection: NWConnection,
        listener: NWListener,
        body: String,
        result: Result<Void, Error>
    ) {
        let response = Self.httpResponse(body: body)
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            listener.cancel()
            self.finish(with: result)
        })
    }

    private static func httpResponse(body: String) -> String {
        """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
    }
}
