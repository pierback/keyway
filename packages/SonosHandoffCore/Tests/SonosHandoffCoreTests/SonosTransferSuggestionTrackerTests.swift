import Testing
@testable import SonosHandoffCore

struct SonosTransferSuggestionTrackerTests {
    private let tracker = SonosTransferSuggestionTracker()

    @Test
    func recordsStartupSpeakersWithoutPromptingWhenSpotifyIsPlayingOutsideVisibleSonosOutputs() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: nil,
            currentSuggestions: []
        )

        #expect(update.action == .none)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_OFFICE"])
    }

    @Test
    func presentsSuggestionWhenSpeakerJoinsNetworkDuringPlayback() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSuggestions: []
        )

        #expect(update.action == .present(candidate("Office", source: "MacBook Pro")))
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_OFFICE"])
    }

    @Test
    func keepsCurrentSuggestionAndRecordsItAsSeen() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSuggestions: [
                SonosTransferSuggestionReference(speakerID: "RINCON_OFFICE"),
            ]
        )

        #expect(update.action == .keepCurrent)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_OFFICE"])
        #expect(update.staleSuggestionIDs.isEmpty)
        #expect(update.refreshedSuggestions == [candidate("Office", source: "MacBook Pro")])
    }

    @Test
    func presentsAnotherNewSpeakerWhileKeepingExistingSuggestionPending() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
                standalone("Bath"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_OFFICE"],
            currentSuggestions: [
                SonosTransferSuggestionReference(speakerID: "RINCON_OFFICE"),
            ]
        )

        #expect(update.action == .present(candidate("Bath", source: "MacBook Pro")))
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_OFFICE", "RINCON_BATH"])
        #expect(update.refreshedSuggestions == [candidate("Office", source: "MacBook Pro")])
    }

    @Test
    func refreshesPendingSuggestionWhenOutputDisplayNameChanges() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standalone("Office"),
            ]),
            activeDeviceName: "iPhone",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_PORT", "RINCON_OFFICE"],
            currentSuggestions: [
                SonosTransferSuggestionReference(speakerID: "RINCON_KITCHEN"),
            ]
        )

        #expect(update.action == .keepCurrent)
        #expect(update.refreshedSuggestions == [
            SonosTransferSuggestionCandidate(
                speaker: speaker("Kitchen"),
                outputDisplayName: "Kitchen + Port",
                sourceDeviceName: "iPhone"
            ),
        ])
    }

    @Test
    func clearsCurrentSuggestionWhenSpotifyMovesToVisibleSonosOutput() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: "Kitchen",
            selectedRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_OFFICE"],
            currentSuggestions: [
                SonosTransferSuggestionReference(speakerID: "RINCON_OFFICE"),
            ]
        )

        #expect(update.action == .clearCurrent)
        #expect(update.staleSuggestionIDs == ["RINCON_OFFICE"])
    }

    @Test
    func clearsCurrentSuggestionWhenSpotifyStopsPlaying() {
        let update = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: false,
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSuggestions: [
                SonosTransferSuggestionReference(speakerID: "RINCON_OFFICE"),
            ]
        )

        #expect(update.action == .clearCurrent)
        #expect(update.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_OFFICE"])
        #expect(update.staleSuggestionIDs == ["RINCON_OFFICE"])
    }

    @Test
    func doesNotSuggestSpeakerFirstSeenWhileSpotifyStopped() {
        let stoppedUpdate = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: nil,
            selectedRoomName: nil,
            spotifyPlaying: false,
            previousSpeakerIDs: ["RINCON_KITCHEN"],
            currentSuggestions: []
        )

        #expect(stoppedUpdate.action == .none)
        #expect(stoppedUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_OFFICE"])

        let resumedUpdate = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: stoppedUpdate.seenSpeakerIDs,
            currentSuggestions: []
        )

        #expect(resumedUpdate.action == .none)
        #expect(resumedUpdate.seenSpeakerIDs == ["RINCON_KITCHEN", "RINCON_OFFICE"])
    }

    @Test
    func staleSuggestionLeavesSpeakerEligibleAfterItRejoinsNetwork() {
        let missingUpdate = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: ["RINCON_KITCHEN", "RINCON_OFFICE"],
            currentSuggestions: [
                SonosTransferSuggestionReference(speakerID: "RINCON_OFFICE"),
            ]
        )

        #expect(missingUpdate.action == .clearCurrent)
        #expect(missingUpdate.seenSpeakerIDs == ["RINCON_KITCHEN"])
        #expect(missingUpdate.staleSuggestionIDs == ["RINCON_OFFICE"])

        let rejoinedUpdate = tracker.update(
            in: SonosGroupState(groups: [
                standalone("Kitchen"),
                standalone("Office"),
            ]),
            activeDeviceName: "MacBook Pro",
            selectedRoomName: nil,
            spotifyPlaying: true,
            previousSpeakerIDs: missingUpdate.seenSpeakerIDs,
            currentSuggestions: []
        )

        #expect(rejoinedUpdate.action == .present(candidate("Office", source: "MacBook Pro")))
    }

    private func candidate(_ roomName: String, source: String) -> SonosTransferSuggestionCandidate {
        SonosTransferSuggestionCandidate(
            speaker: speaker(roomName),
            outputDisplayName: roomName,
            sourceDeviceName: source
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
