import Testing
@testable import SonosHandoffCore

struct SonosGroupingInspectionResolverTests {
    private let resolver = SonosGroupingInspectionResolver()

    @Test
    func reportsGroupedOutputOptionRowsAndSuggestionFromOneSnapshot() throws {
        let state = SonosGroupState(groups: [
            group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
            standalone("Office"),
        ])

        let report = resolver.report(
            in: state,
            activeRoomName: "Port",
            spotifyPlaying: true,
            previousSpeakerIDs: nil
        )

        #expect(report.selectedRoomName == "Kitchen")
        #expect(report.selectedGroup?.displayName == "Kitchen + Port")
        #expect(report.outputRows.map(\.displayName) == ["Kitchen + Port", "Office"])
        #expect(report.groupEditRows.map(\.displayName) == ["Kitchen", "Port", "Office"])
        #expect(report.groupEditRows.map(\.membership) == [.coordinator, .member, .available])
        #expect(report.suggestionCandidate?.speaker.roomName == "Office")
        #expect(report.suggestionCandidate?.coordinatorRoomName == "Kitchen")
    }

    @Test
    func doesNotTreatAVisibleGroupAsActiveWithoutPlayback() {
        let state = SonosGroupState(groups: [
            standalone("Office"),
            group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
        ])

        let report = resolver.report(
            in: state,
            activeRoomName: nil,
            spotifyPlaying: false,
            previousSpeakerIDs: nil
        )

        #expect(report.selectedRoomName == nil)
        #expect(report.selectedGroup == nil)
        #expect(report.groupEditRows.isEmpty)
        #expect(report.outputRows.map(\.displayName) == ["Kitchen + Port", "Office"])
        #expect(report.suggestionCandidate == nil)
    }

    @Test
    func reportsAvailableGroupsAsSingleOptionRows() {
        let state = SonosGroupState(groups: [
            group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
            group(coordinator: "Office", members: ["Office", "Bath"]),
        ])

        let report = resolver.report(
            in: state,
            activeRoomName: "Kitchen",
            spotifyPlaying: true,
            previousSpeakerIDs: nil
        )

        #expect(report.groupEditRows.map(\.displayName) == ["Kitchen", "Port", "Office + Bath"])
        #expect(report.groupEditRows.map(\.membership) == [.coordinator, .member, .availableGroup])
        #expect(report.groupEditRows.last?.joinSpeakers.map(\.roomName) == ["Office", "Bath"])
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
