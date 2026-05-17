import Testing
@testable import SonosHandoffCore

struct SonosGroupMembershipResolverTests {
    private let resolver = SonosGroupMembershipResolver()

    @Test
    func returnsNoRowsWithoutSelectedGroup() {
        let rows = resolver.rows(
            speakers: [speaker("Kitchen")],
            selectedGroup: nil
        )

        #expect(rows.isEmpty)
    }

    @Test
    func marksCoordinatorMembersAndAvailableSpeakers() {
        let rows = resolver.rows(
            speakers: [
                speaker("Kitchen"),
                speaker("Port"),
                speaker("Office"),
            ],
            selectedGroup: group(coordinator: "Kitchen", members: ["Kitchen", "Port"])
        )

        #expect(rows.map(\.speaker.roomName) == ["Kitchen", "Port", "Office"])
        #expect(rows.map(\.membership) == [.coordinator, .member, .available])
        #expect(rows.map(\.canToggle) == [true, true, true])
    }

    @Test
    func ordersSelectedGroupBeforeAvailableSpeakers() {
        let rows = resolver.rows(
            speakers: [
                speaker("Office"),
                speaker("Port"),
                speaker("Kitchen"),
                speaker("Bath"),
            ],
            selectedGroup: group(coordinator: "Kitchen", members: ["Port", "Kitchen"])
        )

        #expect(rows.map(\.speaker.roomName) == ["Kitchen", "Port", "Bath", "Office"])
        #expect(rows.map(\.membership) == [.coordinator, .member, .available, .available])
    }

    @Test
    func disablesCoordinatorRemovalForSingleSpeakerGroup() {
        let rows = resolver.rows(
            speakers: [speaker("Kitchen"), speaker("Office")],
            selectedGroup: group(coordinator: "Kitchen", members: ["Kitchen"])
        )

        #expect(rows[0].membership == .coordinator)
        #expect(rows[0].canToggle == false)
        #expect(rows[1].membership == .available)
        #expect(rows[1].canToggle == true)
    }

    @Test
    func marksEffectiveCoordinatorWhenCoordinatorIDIsMissingFromMembers() {
        let rows = resolver.rows(
            speakers: [
                speaker("Kitchen"),
                speaker("Port"),
                speaker("Office"),
            ],
            selectedGroup: SonosSpeakerGroup(
                id: "RINCON_MISSING:group",
                coordinatorID: "RINCON_MISSING",
                members: [speaker("Kitchen"), speaker("Port")]
            )
        )

        #expect(rows.map(\.speaker.roomName) == ["Kitchen", "Port", "Office"])
        #expect(rows.map(\.membership) == [.coordinator, .member, .available])
        #expect(rows.map(\.canToggle) == [true, true, true])
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
