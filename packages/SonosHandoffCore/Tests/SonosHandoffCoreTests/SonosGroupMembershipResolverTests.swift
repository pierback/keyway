import Testing
@testable import SonosHandoffCore

struct SonosGroupMembershipResolverTests {
    private let resolver = SonosGroupMembershipResolver()

    @Test
    func returnsNoRowsWithoutSelectedGroup() {
        let rows = resolver.rows(
            groups: [standalone("Kitchen")],
            selectedGroup: nil
        )

        #expect(rows.isEmpty)
    }

    @Test
    func marksCoordinatorMembersAndAvailableSpeakers() {
        let selectedGroup = group(coordinator: "Kitchen", members: ["Kitchen", "Port"])
        let rows = resolver.rows(
            groups: [
                selectedGroup,
                standalone("Office"),
            ],
            selectedGroup: selectedGroup
        )

        #expect(rows.map(\.speaker.roomName) == ["Kitchen", "Port", "Office"])
        #expect(rows.map(\.membership) == [.coordinator, .member, .available])
        #expect(rows.map(\.canToggle) == [true, true, true])
    }

    @Test
    func ordersSelectedGroupBeforeAvailableSpeakers() {
        let selectedGroup = group(coordinator: "Kitchen", members: ["Port", "Kitchen"])
        let rows = resolver.rows(
            groups: [
                standalone("Office"),
                selectedGroup,
                standalone("Bath"),
            ],
            selectedGroup: selectedGroup
        )

        #expect(rows.map(\.speaker.roomName) == ["Kitchen", "Port", "Bath", "Office"])
        #expect(rows.map(\.membership) == [.coordinator, .member, .available, .available])
    }

    @Test
    func disablesCoordinatorRemovalForSingleSpeakerGroup() {
        let selectedGroup = standalone("Kitchen")
        let rows = resolver.rows(
            groups: [selectedGroup, standalone("Office")],
            selectedGroup: selectedGroup
        )

        #expect(rows[0].membership == .coordinator)
        #expect(rows[0].canToggle == false)
        #expect(rows[1].membership == .available)
        #expect(rows[1].canToggle == true)
    }

    @Test
    func marksEffectiveCoordinatorWhenCoordinatorIDIsMissingFromMembers() {
        let selectedGroup = SonosSpeakerGroup(
            id: "RINCON_MISSING:group",
            coordinatorID: "RINCON_MISSING",
            members: [speaker("Kitchen"), speaker("Port")]
        )
        let rows = resolver.rows(
            groups: [
                selectedGroup,
                standalone("Office"),
            ],
            selectedGroup: selectedGroup
        )

        #expect(rows.map(\.speaker.roomName) == ["Kitchen", "Port", "Office"])
        #expect(rows.map(\.membership) == [.coordinator, .member, .available])
        #expect(rows.map(\.canToggle) == [true, true, true])
    }

    @Test
    func excludesMembersOfOtherGroupsFromAvailableSpeakers() {
        let selectedGroup = group(coordinator: "Kitchen", members: ["Kitchen", "Port"])
        let rows = resolver.rows(
            groups: [
                selectedGroup,
                group(coordinator: "Office", members: ["Office", "Bath"]),
                standalone("Hall"),
            ],
            selectedGroup: selectedGroup
        )

        #expect(rows.map(\.speaker.roomName) == ["Kitchen", "Port", "Hall"])
        #expect(rows.map(\.membership) == [.coordinator, .member, .available])
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
