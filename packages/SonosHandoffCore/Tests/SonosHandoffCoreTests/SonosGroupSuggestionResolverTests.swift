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

    private func speaker(_ roomName: String) -> SonosSpeaker {
        SonosSpeaker(
            id: "RINCON_\(roomName.uppercased())",
            roomName: roomName,
            host: "\(roomName.lowercased()).local"
        )
    }
}
