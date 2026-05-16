import Foundation

struct SpotifyActiveDeviceWaitPolicy: Sendable {
    let attemptsMax: Int
    let retryNanoseconds: UInt64
    let requiresPlaying: Bool

    init(attemptsMax: Int, retryNanoseconds: UInt64, requiresPlaying: Bool) {
        precondition(attemptsMax > 0, "Spotify active-device wait must have at least one attempt.")
        self.attemptsMax = attemptsMax
        self.retryNanoseconds = retryNanoseconds
        self.requiresPlaying = requiresPlaying
    }

    static let transferVerification = SpotifyActiveDeviceWaitPolicy(
        attemptsMax: 20,
        retryNanoseconds: 500_000_000,
        requiresPlaying: true
    )

    static let volumeMirror = SpotifyActiveDeviceWaitPolicy(
        attemptsMax: 6,
        retryNanoseconds: 250_000_000,
        requiresPlaying: false
    )
}

struct SpotifyActiveDeviceWaitResult: Sendable {
    let state: ConnectPlayerState?
    let lastDeviceName: String?
}

struct SpotifyActiveDeviceWaiter: Sendable {
    typealias CurrentPlayerState = @Sendable (_ accessToken: String) async throws -> ConnectPlayerState?

    private let currentPlayerState: CurrentPlayerState

    init(currentPlayerState: @escaping CurrentPlayerState) {
        self.currentPlayerState = currentPlayerState
    }

    func waitForRoom(
        named roomName: String,
        accessToken: String,
        policy: SpotifyActiveDeviceWaitPolicy
    ) async throws -> SpotifyActiveDeviceWaitResult {
        var lastDeviceName: String?

        for attempt in 0 ..< policy.attemptsMax {
            if let state = try await currentPlayerState(accessToken) {
                lastDeviceName = state.device.name
                if matches(roomName: roomName, state: state, policy: policy) {
                    return SpotifyActiveDeviceWaitResult(state: state, lastDeviceName: lastDeviceName)
                }
            }

            if attempt + 1 < policy.attemptsMax {
                try await Task.sleep(nanoseconds: policy.retryNanoseconds)
            }
        }

        return SpotifyActiveDeviceWaitResult(state: nil, lastDeviceName: lastDeviceName)
    }

    private func matches(
        roomName: String,
        state: ConnectPlayerState,
        policy: SpotifyActiveDeviceWaitPolicy
    ) -> Bool {
        guard SonosRoomName.matches(state.device.name, roomName) else {
            return false
        }

        return !policy.requiresPlaying || state.isPlaying
    }
}
