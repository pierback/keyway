import Testing
@testable import SonosHandoffCore

struct SonosOutputSelectionResolverTests {
    private let resolver = SonosOutputSelectionResolver()

    @Test
    func preservesVisibleCurrentOutput() {
        let selected = resolver.selectedRoomName(
            currentRoomName: " port ",
            groups: standaloneGroups("Kitchen", "Port")
        )

        #expect(selected == "Port")
    }

    @Test
    func selectsGroupCoordinatorWhenCurrentOutputMatchesGroupDisplayName() {
        let selected = resolver.selectedRoomName(
            currentRoomName: "Kitchen + Port",
            groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standaloneGroup("Office"),
            ]
        )

        #expect(selected == "Kitchen")
    }

    @Test
    func selectsGroupCoordinatorWhenSpotifyUsesCountSuffix() {
        let selected = resolver.selectedRoomName(
            currentRoomName: "Kitchen + 1",
            groups: [
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
            ]
        )

        #expect(selected == "Kitchen")
    }

    @Test
    func returnsNilWhenCurrentOutputIsNotVisible() {
        let selected = resolver.selectedRoomName(
            currentRoomName: "Office",
            groups: standaloneGroups("Kitchen", "Port")
        )

        #expect(selected == nil)
    }

    @Test
    func returnsNilWhenCurrentOutputIsMissing() {
        let selected = resolver.selectedRoomName(
            currentRoomName: nil,
            groups: standaloneGroups("Kitchen", "Port")
        )

        #expect(selected == nil)
    }

    @Test
    func returnsNilWhenNoOutputsAreVisible() {
        let selected = resolver.selectedRoomName(
            currentRoomName: "Port",
            groups: []
        )

        #expect(selected == nil)
    }

    private func standaloneGroups(_ roomNames: String...) -> [SonosSpeakerGroup] {
        roomNames.map { standaloneGroup($0) }
    }

    private func standaloneGroup(_ roomName: String) -> SonosSpeakerGroup {
        let speaker = speaker(roomName)
        return SonosSpeakerGroup(
            id: speaker.id,
            coordinatorID: speaker.id,
            members: [speaker]
        )
    }

    private func group(coordinator: String, members roomNames: [String]) -> SonosSpeakerGroup {
        let speakers = roomNames.map(speaker)
        return SonosSpeakerGroup(
            id: "RINCON_\(coordinator.uppercased()):group",
            coordinatorID: "RINCON_\(coordinator.uppercased())",
            members: speakers
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
