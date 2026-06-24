import Testing
@testable import SonosHandoffCore

struct SpotifyConnectTransferReadinessPolicyTests {
    private let policy = SpotifyConnectTransferReadinessPolicy()

    @Test
    func fullTransferOptionallyChecksActiveDeviceAfterTransportStarts() {
        let action = policy.action(
            verification: .full,
            readiness: .transportStarted
        )

        #expect(action == .verifyIfAvailable)
    }

    @Test
    func fullTransferRequiresActiveDeviceWhenOnlySpotifyConnectModeIsVisible() {
        let action = policy.action(
            verification: .full,
            readiness: .spotifyConnectModeOnly
        )

        #expect(action == .verifyRequired)
    }

    @Test
    func coordinatorMigrationDoesNotUseLongActiveDeviceWait() {
        #expect(policy.action(
            verification: .coordinatorMigration,
            readiness: .transportStarted
        ) == .acceptSonosReadiness)
        #expect(policy.action(
            verification: .coordinatorMigration,
            readiness: .spotifyConnectModeOnly
        ) == .acceptSonosReadiness)
    }

    @Test
    func connectOnlyAcceptsSonosReadinessWithoutActivePlaybackVerification() {
        #expect(policy.action(
            verification: .connectOnly,
            readiness: .transportStarted
        ) == .acceptSonosReadiness)
        #expect(policy.action(
            verification: .connectOnly,
            readiness: .spotifyConnectModeOnly
        ) == .acceptSonosReadiness)
    }
}
