import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosTransferVerifierTests {
    @Test
    func acceptsSpotifyConnectMediaInfo() async throws {
        let router = TransferVerifierRouter()
        router.setResponses([
            "GetMediaInfo": [Self.mediaInfo(uri: "x-sonos-vli:spotify:track:123")],
        ])
        let verifier = Self.verifier(router: router)

        try await verifier.waitForSpotifyConnectMode(on: Self.target)

        #expect(router.recordedActions() == ["GetMediaInfo"])
    }

    @Test
    func pollsForSpotifyConnectMediaInfoDuringActivationLag() async throws {
        let router = TransferVerifierRouter()
        router.setResponses([
            "GetMediaInfo": [
                Self.mediaInfo(uri: "x-rincon-queue:RINCON_123#0"),
                Self.mediaInfo(uri: "x-sonos-vli:spotify:track:123"),
            ],
        ])
        let verifier = Self.verifier(router: router, activationPollAttempts: 2)

        try await verifier.waitForSpotifyConnectMode(on: Self.target)

        #expect(router.recordedActions() == ["GetMediaInfo", "GetMediaInfo"])
    }

    @Test
    func reportsTransportStartedWhenPlaybackBeginsAfterLag() async throws {
        let router = TransferVerifierRouter()
        router.setResponses([
            "Play": [""],
            "GetTransportInfo": [
                Self.transportInfo(state: "STOPPED"),
                Self.transportInfo(state: "PLAYING"),
            ],
        ])
        let verifier = Self.verifier(router: router, playbackPollAttempts: 2)

        let readiness = try await verifier.playAndVerifyReadiness(on: Self.target)

        #expect(readiness == .transportStarted)
        #expect(router.recordedActions() == ["Play", "GetTransportInfo", "GetTransportInfo"])
    }

    @Test
    func reportsSpotifyConnectModeOnlyWhenTransportNeverStarts() async throws {
        let router = TransferVerifierRouter()
        router.setResponses([
            "Play": [""],
            "GetTransportInfo": [
                Self.transportInfo(state: "STOPPED"),
                Self.transportInfo(state: "PAUSED_PLAYBACK"),
            ],
            "GetMediaInfo": [Self.mediaInfo(uri: "x-sonos-vli:spotify:track:123")],
        ])
        let verifier = Self.verifier(router: router, playbackPollAttempts: 2)

        let readiness = try await verifier.playAndVerifyReadiness(on: Self.target)

        #expect(readiness == .spotifyConnectModeOnly)
        #expect(router.recordedActions() == ["Play", "GetTransportInfo", "GetTransportInfo", "GetMediaInfo"])
    }

    @Test
    func failsWhenTargetLeavesSpotifyConnectModeBeforePlaybackStarts() async throws {
        let router = TransferVerifierRouter()
        router.setResponses([
            "Play": [""],
            "GetTransportInfo": [Self.transportInfo(state: "STOPPED")],
            "GetMediaInfo": [Self.mediaInfo(uri: "x-rincon-queue:RINCON_123#0")],
        ])
        let verifier = Self.verifier(router: router, playbackPollAttempts: 1)

        do {
            _ = try await verifier.playAndVerifyReadiness(on: Self.target)
            Issue.record("Expected transfer verification to fail.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .transferVerificationFailed)
            #expect(error.message.contains("left Spotify Connect mode"))
        } catch {
            Issue.record("Expected ConnectHandoffError, got \(error).")
        }
    }

    private static let target = ConnectSonosTarget(
        roomName: "Port",
        host: "port.local",
        version: "1.0",
        deviceID: "RINCON_123"
    )

    private static func verifier(
        router: TransferVerifierRouter,
        activationPollAttempts: Int = 1,
        playbackPollAttempts: Int = 2
    ) -> SonosTransferVerifier {
        TransferVerifierURLProtocol.router = router
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferVerifierURLProtocol.self]
        return SonosTransferVerifier(
            soapClient: SonosSOAPClient(urlSession: URLSession(configuration: configuration)),
            activationDelayNanoseconds: 0,
            activationPollAttempts: activationPollAttempts,
            activationPollDelayNanoseconds: 0,
            playbackPollAttempts: playbackPollAttempts,
            playbackPollDelayNanoseconds: 0
        )
    }

    private static func mediaInfo(uri: String) -> String {
        "<CurrentURI>\(uri)</CurrentURI>"
    }

    private static func transportInfo(state: String) -> String {
        "<CurrentTransportState>\(state)</CurrentTransportState>"
    }
}

private final class TransferVerifierURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var router = TransferVerifierRouter()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseBody = Self.router.response(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TransferVerifierRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var responsesByAction: [String: [String]] = [:]
    private var actions: [String] = []

    func setResponses(_ responsesByAction: [String: [String]]) {
        lock.lock()
        self.responsesByAction = responsesByAction
        actions = []
        lock.unlock()
    }

    func recordedActions() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    func response(for request: URLRequest) -> String {
        let action = Self.actionName(from: request)
        lock.lock()
        actions.append(action)
        let response = responsesByAction[action]?.first ?? ""
        if var responses = responsesByAction[action], !responses.isEmpty {
            responses.removeFirst()
            responsesByAction[action] = responses
        }
        lock.unlock()
        return response
    }

    private static func actionName(from request: URLRequest) -> String {
        let soapAction = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
        return soapAction.split(separator: "#").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "unknown"
    }
}
