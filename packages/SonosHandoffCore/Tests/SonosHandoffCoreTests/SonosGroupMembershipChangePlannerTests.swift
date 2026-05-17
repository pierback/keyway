import Testing
@testable import SonosHandoffCore

struct SonosGroupMembershipChangePlannerTests {
    private let planner = SonosGroupMembershipChangePlanner()

    @Test
    func availableSpeakerJoinsCurrentCoordinator() {
        let change = planner.change(
            for: row("Office", membership: .available, coordinatorRemovalAvailable: true),
            in: group(coordinator: "Kitchen", members: ["Kitchen", "Port"])
        )

        #expect(change == .join(roomName: "Office", coordinatorRoomName: "Kitchen"))
    }

    @Test
    func memberSpeakerIsRemovedFromGroup() {
        let change = planner.change(
            for: row("Port", membership: .member, coordinatorRemovalAvailable: true),
            in: group(coordinator: "Kitchen", members: ["Kitchen", "Port"])
        )

        #expect(change == .remove(roomName: "Port"))
    }

    @Test
    func coordinatorRemovalUsesReplacementMember() {
        let port = speaker("Port")
        let currentGroup = group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"])
        let change = planner.change(
            for: row("Kitchen", membership: .coordinator, coordinatorRemovalAvailable: true),
            in: currentGroup
        )

        #expect(change == .removeCoordinator(
            group: currentGroup,
            coordinatorRoomName: "Kitchen",
            replacement: port
        ))
    }

    @Test
    func disabledCoordinatorRemovalIsNoOp() {
        let change = planner.change(
            for: row("Kitchen", membership: .coordinator, coordinatorRemovalAvailable: false),
            in: group(coordinator: "Kitchen", members: ["Kitchen"])
        )

        #expect(change == .none)
    }

    @Test
    func rowThatDoesNotMatchGroupCoordinatorIsNoOp() {
        let change = planner.change(
            for: row("Port", membership: .coordinator, coordinatorRemovalAvailable: true),
            in: group(coordinator: "Kitchen", members: ["Kitchen", "Port"])
        )

        #expect(change == .none)
    }

    private func row(
        _ roomName: String,
        membership: SonosGroupMembership,
        coordinatorRemovalAvailable: Bool
    ) -> SonosGroupMembershipRow {
        SonosGroupMembershipRow(
            speaker: speaker(roomName),
            membership: membership,
            coordinatorRemovalAvailable: coordinatorRemovalAvailable
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
