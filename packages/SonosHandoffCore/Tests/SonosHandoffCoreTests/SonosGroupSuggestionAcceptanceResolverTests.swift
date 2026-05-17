import Testing
@testable import SonosHandoffCore

struct SonosGroupSuggestionAcceptanceResolverTests {
    private let resolver = SonosGroupSuggestionAcceptanceResolver()

    @Test
    func acceptsAgainstCurrentCoordinatorWhenTargetGroupStillContainsOriginalCoordinator() {
        let decision = resolver.decision(
            for: suggestion("Office", coordinator: "Kitchen", group: "Kitchen + Port"),
            selectedGroup: group(coordinator: "Port", members: ["Port", "Kitchen"])
        )

        #expect(decision == .accept(coordinatorRoomName: "Port"))
    }

    @Test
    func rejectsWhenThereIsNoActiveSonosGroup() {
        let decision = resolver.decision(
            for: suggestion("Office", coordinator: "Kitchen", group: "Kitchen"),
            selectedGroup: nil
        )

        #expect(decision == .reject(.noActiveSonosGroup))
    }

    @Test
    func rejectsWhenPlaybackMovedToAnotherGroup() {
        let decision = resolver.decision(
            for: suggestion("Office", coordinator: "Kitchen", group: "Kitchen"),
            selectedGroup: group(coordinator: "Port", members: ["Port"])
        )

        #expect(decision == .reject(.targetGroupChanged))
    }

    @Test
    func rejectsWhenSuggestedSpeakerAlreadyJoinedTheGroup() {
        let decision = resolver.decision(
            for: suggestion("Office", coordinator: "Kitchen", group: "Kitchen"),
            selectedGroup: group(coordinator: "Kitchen", members: ["Kitchen", "Office"])
        )

        #expect(decision == .reject(.speakerAlreadyGrouped))
    }

    private func suggestion(
        _ roomName: String,
        coordinator: String,
        group: String
    ) -> SonosGroupSuggestion {
        SonosGroupSuggestion(
            speaker: speaker(roomName),
            coordinatorRoomName: coordinator,
            groupDisplayName: group,
            detectedAt: .distantPast
        )
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
