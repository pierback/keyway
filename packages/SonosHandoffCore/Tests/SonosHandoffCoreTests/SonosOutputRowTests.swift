import Testing
@testable import SonosHandoffCore

struct SonosOutputRowTests {
    @Test
    func representsGroupedSpeakersAsOneOutputRow() throws {
        let row = try #require(SonosOutputRow(group: group(coordinator: "Kitchen", members: ["Kitchen", "Port"])))

        #expect(row.id == "RINCON_KITCHEN:group")
        #expect(row.displayName == "Kitchen + Port")
        #expect(row.coordinator.roomName == "Kitchen")
        #expect(row.isGroup)
        #expect(row.contains(roomName: "Port"))
        #expect(row.contains(roomName: "Kitchen + Port"))
    }

    @Test
    func rejectsEmptyGroup() {
        let row = SonosOutputRow(
            group: SonosSpeakerGroup(
                id: "empty",
                coordinatorID: "missing",
                members: []
            )
        )

        #expect(row == nil)
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
