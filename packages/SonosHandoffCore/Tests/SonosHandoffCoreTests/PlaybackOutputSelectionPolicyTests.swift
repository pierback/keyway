import Testing
@testable import SonosHandoffCore

struct PlaybackOutputSelectionPolicyTests {
    @Test
    func activePlaybackObservationCannotReplaceUserSelection() {
        var policy = PlaybackOutputSelectionPolicy()

        policy.update(roomName: "Kitchen", source: .activePlaybackObservation)
        policy.update(roomName: "Port", source: .userSelection)
        let accepted = policy.update(roomName: "Kitchen", source: .activePlaybackObservation)

        #expect(!accepted)
        #expect(policy.roomName == "Port")
    }

    @Test
    func sameRoomObservationCanRefreshUserSelectionMetadata() {
        var policy = PlaybackOutputSelectionPolicy()

        policy.update(roomName: " Port ", source: .userSelection)
        let accepted = policy.update(roomName: "port", source: .activePlaybackObservation)

        #expect(accepted)
        #expect(policy.roomName == "port")
    }

    @Test
    func playbackTransactionReleasesUserSelection() {
        var policy = PlaybackOutputSelectionPolicy()

        policy.update(roomName: "Port", source: .userSelection)
        policy.update(roomName: "Kitchen", source: .playbackTransaction)
        let accepted = policy.update(roomName: "Office", source: .activePlaybackObservation)

        #expect(accepted)
        #expect(policy.roomName == "Office")
    }

    @Test
    func directoryRefreshPreservesUserAuthorityWhileRoomRemainsVisible() {
        var policy = PlaybackOutputSelectionPolicy()

        policy.update(roomName: "Port", source: .userSelection)
        policy.update(roomName: "port", source: .directoryRefresh)
        let accepted = policy.update(roomName: "Kitchen", source: .activePlaybackObservation)

        #expect(!accepted)
        #expect(policy.roomName == "port")
    }

    @Test
    func directoryRefreshReleasesMissingUserSelection() {
        var policy = PlaybackOutputSelectionPolicy()

        policy.update(roomName: "Port", source: .userSelection)
        policy.update(roomName: "Kitchen", source: .directoryRefresh)
        let accepted = policy.update(roomName: "Office", source: .activePlaybackObservation)

        #expect(accepted)
        #expect(policy.roomName == "Office")
    }

    @Test
    func resetReleasesUserSelection() {
        var policy = PlaybackOutputSelectionPolicy()

        policy.update(roomName: "Port", source: .userSelection)
        policy.update(roomName: nil, source: .reset)
        let accepted = policy.update(roomName: "Kitchen", source: .activePlaybackObservation)

        #expect(accepted)
        #expect(policy.roomName == "Kitchen")
    }
}
