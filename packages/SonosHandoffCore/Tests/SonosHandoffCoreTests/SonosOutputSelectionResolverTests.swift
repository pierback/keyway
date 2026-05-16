import Testing
@testable import SonosHandoffCore

struct SonosOutputSelectionResolverTests {
    private let resolver = SonosOutputSelectionResolver()

    @Test
    func preservesVisibleCurrentOutput() {
        let selected = resolver.selectedRoomName(
            currentRoomName: " port ",
            speakers: speakers("Kitchen", "Port")
        )

        #expect(selected == "Port")
    }

    @Test
    func returnsNilWhenCurrentOutputIsNotVisible() {
        let selected = resolver.selectedRoomName(
            currentRoomName: "Office",
            speakers: speakers("Kitchen", "Port")
        )

        #expect(selected == nil)
    }

    @Test
    func returnsNilWhenCurrentOutputIsMissing() {
        let selected = resolver.selectedRoomName(
            currentRoomName: nil,
            speakers: speakers("Kitchen", "Port")
        )

        #expect(selected == nil)
    }

    @Test
    func returnsNilWhenNoOutputsAreVisible() {
        let selected = resolver.selectedRoomName(
            currentRoomName: "Port",
            speakers: []
        )

        #expect(selected == nil)
    }

    private func speakers(_ roomNames: String...) -> [SonosSpeaker] {
        roomNames.map { roomName in
            SonosSpeaker(
                id: "RINCON_\(roomName.uppercased())",
                roomName: roomName,
                host: "\(roomName.lowercased()).local"
            )
        }
    }
}
