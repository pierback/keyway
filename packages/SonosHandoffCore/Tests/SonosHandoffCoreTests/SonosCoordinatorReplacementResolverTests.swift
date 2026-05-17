import Testing
@testable import SonosHandoffCore

struct SonosCoordinatorReplacementResolverTests {
    private let resolver = SonosCoordinatorReplacementResolver()

    @Test
    func choosesFirstNonCoordinatorMemberAsReplacement() {
        let replacement = resolver.replacement(
            in: group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"]),
            removingCoordinatorID: "RINCON_KITCHEN"
        )

        #expect(replacement?.roomName == "Port")
    }

    @Test
    func returnsNilForSingleSpeakerGroup() {
        let replacement = resolver.replacement(
            in: group(coordinator: "Kitchen", members: ["Kitchen"]),
            removingCoordinatorID: "RINCON_KITCHEN"
        )

        #expect(replacement == nil)
    }

    @Test
    func returnsNilWhenRemovedSpeakerIsNotCoordinator() {
        let replacement = resolver.replacement(
            in: group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
            removingCoordinatorID: "RINCON_PORT"
        )

        #expect(replacement == nil)
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
