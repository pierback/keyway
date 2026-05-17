import Testing
@testable import SonosHandoffCore

struct SonosGroupSuggestionResolverTests {
    private let resolver = SonosGroupSuggestionResolver()

    @Test
    func suggestsStandaloneSpeakerOnStartupWhenSpotifyIsPlayingOnGroup() {
        let candidate = resolver.suggestion(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: nil
        )

        #expect(candidate?.speaker.roomName == "Office")
        #expect(candidate?.coordinatorRoomName == "Kitchen")
        #expect(candidate?.groupDisplayName == "Kitchen + Port")
    }

    @Test
    func suggestsOnlyNewStandaloneSpeakerAfterInitialSnapshot() {
        let candidate = resolver.suggestion(
            in: groupStateWithOfficeAndBath,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"]
        )

        #expect(candidate?.speaker.roomName == "Bath")
    }

    @Test
    func suggestsStandaloneSpeakerWhenPlaybackIsOnOneSpeaker() {
        let candidate = resolver.suggestion(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Port"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: nil
        )

        #expect(candidate?.speaker.roomName == "Port")
        #expect(candidate?.coordinatorRoomName == "Kitchen")
        #expect(candidate?.groupDisplayName == "Kitchen")
    }

    @Test
    func doesNotSuggestAlreadySeenStandaloneSpeakerAfterInitialSnapshot() {
        let candidate = resolver.suggestion(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"]
        )

        #expect(candidate == nil)
    }

    @Test
    func doesNotSuggestWhenSpotifyIsNotPlaying() {
        let candidate = resolver.suggestion(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: false,
            previousSpeakerIDs: nil
        )

        #expect(candidate == nil)
    }

    @Test
    func doesNotSuggestCurrentGroupMembers() {
        let candidate = resolver.suggestion(
            in: SonosGroupState(groups: [kitchenPortGroup]),
            selectedRoomName: "Port",
            spotifyPlaying: true,
            previousSpeakerIDs: nil
        )

        #expect(candidate == nil)
    }

    @Test
    func keepsCurrentSuggestionWhileStandaloneSpeakerStillTargetsCurrentCoordinator() {
        let keepSuggestion = resolver.suggestionStillValid(
            speakerID: "RINCON_OFFICE",
            coordinatorRoomName: "Kitchen",
            in: groupState,
            selectedRoomName: "Kitchen"
        )

        #expect(keepSuggestion)
    }

    @Test
    func clearsCurrentSuggestionAfterSpeakerJoinedCurrentGroup() {
        let keepSuggestion = resolver.suggestionStillValid(
            speakerID: "RINCON_OFFICE",
            coordinatorRoomName: "Kitchen",
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"]),
            ]),
            selectedRoomName: "Kitchen"
        )

        #expect(!keepSuggestion)
    }

    @Test
    func clearsCurrentSuggestionWhenPlaybackMovedToAnotherCoordinator() {
        let keepSuggestion = resolver.suggestionStillValid(
            speakerID: "RINCON_OFFICE",
            coordinatorRoomName: "Kitchen",
            in: groupState,
            selectedRoomName: "Office"
        )

        #expect(!keepSuggestion)
    }

    @Test
    func clearsCurrentSuggestionWhenSpeakerIsNoLongerStandalone() {
        let keepSuggestion = resolver.suggestionStillValid(
            speakerID: "RINCON_OFFICE",
            coordinatorRoomName: "Kitchen",
            in: SonosGroupState(groups: [
                kitchenPortGroup,
                group(coordinator: "Office", members: ["Office", "Bath"]),
            ]),
            selectedRoomName: "Kitchen"
        )

        #expect(!keepSuggestion)
    }

    @Test
    func recordingPromptedSpeakerLeavesOtherNewSpeakersEligible() {
        let seenSpeakerIDs = resolver.seenSpeakerIDsAfterSuggestion(
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            currentSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE", "RINCON_BATH"],
            suggestedSpeakerID: "RINCON_OFFICE"
        )
        let nextCandidate = resolver.suggestion(
            in: groupStateWithOfficeAndBath,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: seenSpeakerIDs
        )

        #expect(seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
        #expect(nextCandidate?.speaker.roomName == "Bath")
    }

    @Test
    func recordingNoSuggestionMarksCurrentSpeakersSeen() {
        let seenSpeakerIDs = resolver.seenSpeakerIDsAfterSuggestion(
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            suggestedSpeakerID: nil
        )

        #expect(seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT"])
    }

    @Test
    func speakerLeavingNetworkIsNoLongerSeen() {
        let seenSpeakerIDs = resolver.seenSpeakerIDsAfterSuggestion(
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"],
            currentSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            suggestedSpeakerID: nil
        )

        #expect(seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT"])
    }

    @Test
    func suggestsSpeakerAgainAfterItRejoinsNetwork() {
        let seenAfterLeaving = resolver.seenSpeakerIDsAfterSuggestion(
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"],
            currentSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            suggestedSpeakerID: nil
        )
        let candidate = resolver.suggestion(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: seenAfterLeaving
        )

        #expect(candidate?.speaker.roomName == "Office")
        #expect(candidate?.coordinatorRoomName == "Kitchen")
    }

    private var groupState: SonosGroupState {
        SonosGroupState(groups: [
            kitchenPortGroup,
            standalone("Office"),
        ])
    }

    private var groupStateWithOfficeAndBath: SonosGroupState {
        SonosGroupState(groups: [
            kitchenPortGroup,
            standalone("Office"),
            standalone("Bath"),
        ])
    }

    private var kitchenPortGroup: SonosSpeakerGroup {
        SonosSpeakerGroup(
            id: "RINCON_KITCHEN:123",
            coordinatorID: "RINCON_KITCHEN",
            members: [
                speaker("Kitchen"),
                speaker("Port"),
            ]
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
