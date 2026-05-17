import Testing
@testable import SonosHandoffCore

struct SonosGroupSuggestionTrackerTests {
    private let tracker = SonosGroupSuggestionTracker()

    @Test
    func suggestionReferenceMatchesCurrentOrRetargetedIdentifier() {
        let reference = SonosGroupSuggestionReference(
            speakerID: "RINCON_BATH",
            coordinatorRoomName: "Port"
        )

        #expect(reference.matches(identifier: "RINCON_BATH|Port"))
        #expect(reference.matches(identifier: "RINCON_BATH|Kitchen"))
        #expect(reference.matches(identifier: "RINCON_BATH"))
        #expect(!reference.matches(identifier: "RINCON_OFFICE|Port"))
    }

    @Test
    func presentsStartupSuggestionWhenSpotifyIsPlayingOnVisibleGroup() {
        let update = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: nil,
            currentSuggestions: []
        )

        #expect(update.action == .present(candidate("Office", coordinator: "Kitchen", group: "Kitchen + Port")))
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
    }

    @Test
    func presentsSuggestionWhenStandaloneSpeakerJoinsNetworkDuringPlayback() {
        let update = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            currentSuggestions: []
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
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(update.action == .keepCurrent)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
        #expect(update.staleSuggestionIDs.isEmpty)
        #expect(update.refreshedSuggestions == [candidate("Office", coordinator: "Kitchen", group: "Kitchen + Port")])
    }

    @Test
    func startupBaselineKeepsOtherStandaloneSpeakersEligible() {
        let firstUpdate = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standalone("Office"),
                standalone("Bath"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: nil,
            currentSuggestions: []
        )

        #expect(firstUpdate.action == .present(candidate("Bath", coordinator: "Kitchen", group: "Kitchen + Port")))
        #expect(firstUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_BATH"])

        let secondUpdate = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standalone("Office"),
                standalone("Bath"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: firstUpdate.seenSpeakerIDs,
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_BATH",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(secondUpdate.action == .present(candidate("Office", coordinator: "Kitchen", group: "Kitchen + Port")))
        #expect(secondUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_BATH", "RINCON_OFFICE"])
        #expect(secondUpdate.refreshedSuggestions == [candidate("Bath", coordinator: "Kitchen", group: "Kitchen + Port")])
    }

    @Test
    func startupBaselineDoesNotSuggestMemberThatLeavesCurrentGroup() {
        let startupUpdate = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: nil,
            currentSuggestions: []
        )

        let laterUpdate = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen"]),
                standalone("Port"),
                standalone("Office"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: startupUpdate.seenSpeakerIDs,
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(laterUpdate.action == .keepCurrent)
        #expect(laterUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
        #expect(laterUpdate.refreshedSuggestions == [candidate("Office", coordinator: "Kitchen", group: "Kitchen")])
    }

    @Test
    func presentsNewJoinedSpeakerWhileKeepingExistingSuggestionPending() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standalone("Office"),
                standalone("Bath"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"],
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(update.action == .present(candidate("Bath", coordinator: "Kitchen", group: "Kitchen + Port")))
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE", "RINCON_BATH"])
        #expect(update.staleSuggestionIDs.isEmpty)
        #expect(update.refreshedSuggestions == [candidate("Office", coordinator: "Kitchen", group: "Kitchen + Port")])
    }

    @Test
    func refreshesPendingSuggestionAfterAnotherSpeakerJoinedGroup() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"]),
                standalone("Bath"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE", "RINCON_BATH"],
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_BATH",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(update.action == .keepCurrent)
        #expect(update.refreshedSuggestions == [candidate("Bath", coordinator: "Kitchen", group: "Kitchen + 2")])
    }

    @Test
    func refreshReturnsRetargetedPendingSuggestionsAndStaleIDs() {
        let refresh = tracker.refresh(
            in: SonosGroupState(groups: [
                group(coordinator: "Port", members: ["Port", "Kitchen", "Office"]),
                standalone("Bath"),
            ]),
            selectedRoomName: "Port",
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_BATH",
                    coordinatorRoomName: "Kitchen"
                ),
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(refresh.staleSuggestionIDs == ["RINCON_OFFICE|Kitchen"])
        #expect(refresh.refreshedSuggestions == [candidate("Bath", coordinator: "Port", group: "Port + 2")])
    }

    @Test
    func keepsPendingSuggestionAfterCoordinatorMigration() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Port", members: ["Port", "Kitchen", "Office"]),
                standalone("Bath"),
            ]),
            selectedRoomName: "Port",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE", "RINCON_BATH"],
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_BATH",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(update.action == .keepCurrent)
        #expect(update.staleSuggestionIDs.isEmpty)
        #expect(update.refreshedSuggestions == [candidate("Bath", coordinator: "Port", group: "Port + 2")])
    }

    @Test
    func clearsPendingSuggestionWhenPlaybackMovesToDifferentGroup() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Living", members: ["Living", "Bath"]),
                standalone("Office"),
            ]),
            selectedRoomName: "Living",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE", "RINCON_LIVING", "RINCON_BATH"],
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(update.action == .clearCurrent)
        #expect(update.staleSuggestionIDs == ["RINCON_OFFICE|Kitchen"])
        #expect(update.refreshedSuggestions.isEmpty)
    }

    @Test
    func clearsCurrentSuggestionWhenSpotifyStopsPlaying() {
        let update = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: false,
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
        )

        #expect(update.action == .clearCurrent)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
        #expect(update.staleSuggestionIDs == ["RINCON_OFFICE|Kitchen"])
    }

    @Test
    func doesNotSuggestSpeakerFirstSeenWhileSpotifyStopped() {
        let stoppedUpdate = tracker.update(
            in: groupState,
            selectedRoomName: nil,
            spotifyPlaying: false,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT"],
            currentSuggestions: []
        )

        #expect(stoppedUpdate.action == .none)
        #expect(stoppedUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])

        let resumedUpdate = tracker.update(
            in: groupState,
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: stoppedUpdate.seenSpeakerIDs,
            currentSuggestions: []
        )

        #expect(resumedUpdate.action == .none)
        #expect(resumedUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"])
    }

    @Test
    func activePlaybackWithoutVisibleGroupDoesNotMarkJoinedSpeakerSeen() {
        let unmatchedUpdate = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Port"),
            ]),
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSuggestions: []
        )

        #expect(unmatchedUpdate.action == .none)
        #expect(unmatchedUpdate.seenSpeakerIDs == ["RINCON_KITCHEN"])

        let matchedUpdate = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Port"),
            ]),
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: unmatchedUpdate.seenSpeakerIDs,
            currentSuggestions: []
        )

        #expect(matchedUpdate.action == .present(candidate("Port", coordinator: "Kitchen", group: "Kitchen")))
        #expect(matchedUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_PORT"])
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
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
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
            currentSuggestions: [
                SonosGroupSuggestionReference(
                    speakerID: "RINCON_OFFICE",
                    coordinatorRoomName: "Kitchen"
                ),
            ]
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
