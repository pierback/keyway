import Testing
@testable import SonosHandoffCore

struct SonosGroupSuggestionTrackerTests {
    private let tracker = SonosGroupSuggestionTracker()

    @Test
    func presentsStartupSuggestionWhenSpotifyIsPlayingOnVisibleGroup() {
        let update = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: nil,
            currentSuggestion: nil
        )

        #expect(update.action == .present(candidate("Office", coordinator: "Kitchen", group: "Kitchen + Port")))
        #expect(update.seenSpeakerIDs == ["RINCON_OFFICE"])
    }

    @Test
    func presentsSuggestionWhenStandaloneSpeakerJoinsNetworkDuringPlayback() {
        let update = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            currentSuggestion: nil
        )

        #expect(update.action == .present(candidate("Office", coordinator: "Kitchen", group: "Kitchen + Port")))
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
    }

    @Test
    func keepsCurrentSuggestionAndRecordsItAsSeen() {
        let update = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            currentSuggestion: SonosGroupSuggestionReference(
                speakerID: "RINCON_OFFICE",
                coordinatorRoomName: "Kitchen"
            )
        )

        #expect(update.action == .keepCurrent)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
    }

    @Test
    func clearsCurrentSuggestionWhenSpotifyStopsPlaying() {
        let update = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: false,
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSuggestion: SonosGroupSuggestionReference(
                speakerID: "RINCON_OFFICE",
                coordinatorRoomName: "Kitchen"
            )
        )

        #expect(update.action == .clearCurrent)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
    }

    @Test
    func clearsCurrentSuggestionAfterSpeakerJoinedGroup() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"]),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"],
            currentSuggestion: SonosGroupSuggestionReference(
                speakerID: "RINCON_OFFICE",
                coordinatorRoomName: "Kitchen"
            )
        )

        #expect(update.action == .clearCurrent)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
    }

    @Test
    func presentsAnotherNewStandaloneSpeakerAfterCurrentSuggestionBecomesInvalid() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"]),
                standalone("Bath"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"],
            currentSuggestion: SonosGroupSuggestionReference(
                speakerID: "RINCON_OFFICE",
                coordinatorRoomName: "Kitchen"
            )
        )

        #expect(update.action == .present(candidate("Bath", coordinator: "Kitchen", group: "Kitchen + 2")))
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE", "RINCON_BATH"])
    }

    private var groupState: SonosGroupState {
        SonosGroupState(groups: [
            group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
            standalone("Office"),
        ])
    }

    private func candidate(
        _ roomName: String,
        coordinator coordinatorRoomName: String,
        group groupDisplayName: String
    ) -> SonosGroupSuggestionCandidate {
        SonosGroupSuggestionCandidate(
            speaker: speaker(roomName),
            coordinatorRoomName: coordinatorRoomName,
            groupDisplayName: groupDisplayName
        )
    }

    private func standalone(_ roomName: String) -> SonosSpeakerGroup {
        let speaker = speaker(roomName)
        return SonosSpeakerGroup(id: speaker.id, coordinatorID: speaker.id, members: [speaker])
    }

    private func group(coordinator: String, members roomNames: [String]) -> SonosSpeakerGroup {
        SonosSpeakerGroup(
            id: "RINCON_\(coordinator.uppercased()):group",
            coordinatorID: "RINCON_\(coordinator.uppercased())",
            members: roomNames.map(speaker)
        )
    }

    private func speaker(_ roomName: String) -> SonosSpeaker {
        SonosSpeaker(
            id: "RINCON_\(roomName.uppercased())",
            roomName: roomName,
            host: "\(roomName.lowercased()).local"
        )
    }
}
