import Foundation
import Testing
@testable import SonosHandoffCore

struct SpotifyActiveDeviceWaiterTests {
    @Test
    func volumeMirrorDoesNotRequirePlayback() async throws {
        let source = PlayerStateSource([
            .state(deviceName: "Port", isPlaying: false),
        ])
        let waiter = SpotifyActiveDeviceWaiter(currentPlayerState: source.nextState(accessToken:))

        let result = try await waiter.waitForRoom(
            named: "Port",
            accessToken: "token",
            policy: SpotifyActiveDeviceWaitPolicy(attemptsMax: 1, retryNanoseconds: 0, requiresPlaying: false)
        )

        #expect(result.state?.device.name == "Port")
        #expect(await source.requestCount == 1)
    }

    @Test
    func activeDeviceMatchingUsesSharedRoomNamePolicy() async throws {
        let source = PlayerStateSource([
            .state(deviceName: " Port\n", isPlaying: false),
        ])
        let waiter = SpotifyActiveDeviceWaiter(currentPlayerState: source.nextState(accessToken:))

        let result = try await waiter.waitForRoom(
            named: "port",
            accessToken: "token",
            policy: SpotifyActiveDeviceWaitPolicy(attemptsMax: 1, retryNanoseconds: 0, requiresPlaying: false)
        )

        #expect(result.state?.device.name == " Port\n")
        #expect(await source.requestCount == 1)
    }

    @Test
    func activeDeviceMatchingAcceptsSpotifyGroupNameForCoordinator() async throws {
        let source = PlayerStateSource([
            .state(deviceName: "Kitchen + Port", isPlaying: false),
        ])
        let waiter = SpotifyActiveDeviceWaiter(currentPlayerState: source.nextState(accessToken:))

        let result = try await waiter.waitForRoom(
            named: "Kitchen",
            accessToken: "token",
            policy: SpotifyActiveDeviceWaitPolicy(attemptsMax: 1, retryNanoseconds: 0, requiresPlaying: false)
        )

        #expect(result.state?.device.name == "Kitchen + Port")
        #expect(await source.requestCount == 1)
    }

    @Test
    func activeDeviceMatchingAcceptsSpotifyGroupCountSuffixForCoordinator() async throws {
        let source = PlayerStateSource([
            .state(deviceName: "Kitchen + 1", isPlaying: true),
        ])
        let waiter = SpotifyActiveDeviceWaiter(currentPlayerState: source.nextState(accessToken:))

        let result = try await waiter.waitForRoom(
            named: "Kitchen",
            accessToken: "token",
            policy: SpotifyActiveDeviceWaitPolicy(attemptsMax: 1, retryNanoseconds: 0, requiresPlaying: true)
        )

        #expect(result.state?.device.name == "Kitchen + 1")
        #expect(await source.requestCount == 1)
    }

    @Test
    func transferVerificationRequiresPlayback() async throws {
        let source = PlayerStateSource([
            .state(deviceName: "Port", isPlaying: false),
            .state(deviceName: "Port", isPlaying: true),
        ])
        let waiter = SpotifyActiveDeviceWaiter(currentPlayerState: source.nextState(accessToken:))

        let result = try await waiter.waitForRoom(
            named: "port",
            accessToken: "token",
            policy: SpotifyActiveDeviceWaitPolicy(attemptsMax: 2, retryNanoseconds: 0, requiresPlaying: true)
        )

        #expect(result.state?.isPlaying == true)
        #expect(result.lastDeviceName == "Port")
        #expect(await source.requestCount == 2)
    }

    @Test
    func returnsLastObservedDeviceWhenRoomNeverMatches() async throws {
        let source = PlayerStateSource([
            .none,
            .state(deviceName: "This computer", isPlaying: true),
            .state(deviceName: "Kitchen", isPlaying: true),
        ])
        let waiter = SpotifyActiveDeviceWaiter(currentPlayerState: source.nextState(accessToken:))

        let result = try await waiter.waitForRoom(
            named: "Port",
            accessToken: "token",
            policy: SpotifyActiveDeviceWaitPolicy(attemptsMax: 3, retryNanoseconds: 0, requiresPlaying: true)
        )

        #expect(result.state == nil)
        #expect(result.lastDeviceName == "Kitchen")
        #expect(await source.requestCount == 3)
    }
}

private actor PlayerStateSource {
    enum Response: Sendable {
        case none
        case state(deviceName: String, isPlaying: Bool)
    }

    private var responses: [Response]
    private var recordedRequestCount = 0

    init(_ responses: [Response]) {
        self.responses = responses
    }

    var requestCount: Int {
        recordedRequestCount
    }

    func nextState(accessToken: String) async throws -> ConnectPlayerState? {
        recordedRequestCount += 1
        let response = responses.isEmpty ? Response.none : responses.removeFirst()

        switch response {
        case .none:
            return nil
        case let .state(deviceName, isPlaying):
            return ConnectPlayerState(
                isPlaying: isPlaying,
                device: ConnectPlayerDevice(name: deviceName, isRestricted: false, volumePercent: nil)
            )
        }
    }
}
