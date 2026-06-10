import Foundation
import Network

enum SpotifyAuthCallbackServer {
    static let host = "127.0.0.1"
    static let port: UInt16 = 43821
    static let ports: [UInt16] = Array(43821 ... 43825)
    static let path = "/callback"
    static let timeoutSeconds = 120

    static var redirectURI: URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    static func completeAuthorization(
        expectedState: String,
        completion: @escaping @Sendable (String, URL) async throws -> Void,
        openAuthorizationURL: @escaping @Sendable (URL) -> Bool
    ) async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "keyway.spotify-auth")
            let session = SpotifyAuthCallbackListenerSession(
                expectedState: expectedState,
                params: params,
                queue: queue,
                continuation: continuation,
                completion: completion,
                openAuthorizationURL: openAuthorizationURL
            )
            session.start()
        }
    }
}

private final class SpotifyAuthCallbackListenerSession: @unchecked Sendable {
    private let expectedState: String
    private let params: NWParameters
    private let queue: DispatchQueue
    private let continuation: CheckedContinuation<Void, Error>
    private let completion: @Sendable (String, URL) async throws -> Void
    private let openAuthorizationURL: @Sendable (URL) -> Bool
    private var nextPortIndex = 0
    private var browserOpened = false
    private var didFinish = false
    private var listener: NWListener?
    private var resolver: SpotifyAuthCallbackResolver?

    init(
        expectedState: String,
        params: NWParameters,
        queue: DispatchQueue,
        continuation: CheckedContinuation<Void, Error>,
        completion: @escaping @Sendable (String, URL) async throws -> Void,
        openAuthorizationURL: @escaping @Sendable (URL) -> Bool
    ) {
        self.expectedState = expectedState
        self.params = params
        self.queue = queue
        self.continuation = continuation
        self.completion = completion
        self.openAuthorizationURL = openAuthorizationURL
    }

    func start() {
        queue.asyncAfter(deadline: .now() + .seconds(SpotifyAuthCallbackServer.timeoutSeconds)) {
            self.finish(with: .failure(SpotifyAuthError.callbackTimedOut))
        }
        startNextListener()
    }

    private func startNextListener() {
        guard nextPortIndex < SpotifyAuthCallbackServer.ports.count else {
            finish(with: .failure(SpotifyAuthError.callbackListenerFailed))
            return
        }

        let candidatePort = SpotifyAuthCallbackServer.ports[nextPortIndex]
        nextPortIndex += 1
        let nwPort = NWEndpoint.Port(rawValue: candidatePort)!
        let redirectURI = URL(
            string: "http://\(SpotifyAuthCallbackServer.host):\(candidatePort)\(SpotifyAuthCallbackServer.path)"
        )!

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            startNextListener()
            return
        }

        let resolver = SpotifyAuthCallbackResolver(
            expectedState: expectedState,
            redirectURI: redirectURI,
            continuation: continuation,
            completion: completion
        )
        self.listener = listener
        self.resolver = resolver

        listener.stateUpdateHandler = { [self, weak listener] state in
            guard let listener else {
                return
            }
            handle(state: state, listener: listener, redirectURI: redirectURI)
        }

        listener.newConnectionHandler = { [self, weak listener] connection in
            guard let listener,
                  let currentListener = self.listener,
                  listener === currentListener,
                  let resolver = self.resolver
            else {
                connection.cancel()
                return
            }
            resolver.handle(connection: connection, listener: listener)
        }

        listener.start(queue: queue)
    }

    private func handle(state: NWListener.State, listener: NWListener, redirectURI: URL) {
        guard let currentListener = self.listener, listener === currentListener else {
            return
        }

        switch state {
        case .ready:
            guard !browserOpened else {
                return
            }
            browserOpened = true
            guard openAuthorizationURL(redirectURI) else {
                finish(with: .failure(SpotifyAuthError.couldNotOpenBrowser))
                return
            }
        case .failed:
            guard browserOpened else {
                clearCurrentListener()
                startNextListener()
                return
            }
            finish(with: .failure(SpotifyAuthError.callbackListenerFailed))
        default:
            break
        }
    }

    private func finish(with result: Result<Void, Error>) {
        guard !didFinish else {
            return
        }
        didFinish = true
        let resolver = resolver
        clearCurrentListener()
        guard let resolver else {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
            return
        }
        resolver.finish(with: result)
    }

    private func clearCurrentListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        resolver = nil
    }
}

private final class SpotifyAuthCallbackResolver: @unchecked Sendable {
    private let expectedState: String
    private let redirectURI: URL
    private let completion: @Sendable (String, URL) async throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(
        expectedState: String,
        redirectURI: URL,
        continuation: CheckedContinuation<Void, Error>,
        completion: @escaping @Sendable (String, URL) async throws -> Void
    ) {
        self.expectedState = expectedState
        self.redirectURI = redirectURI
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
                    try await self.completion(code, self.redirectURI)
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
