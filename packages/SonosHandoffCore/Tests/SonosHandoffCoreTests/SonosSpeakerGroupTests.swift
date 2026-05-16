import Testing
@testable import SonosHandoffCore

struct SonosSpeakerGroupTests {
    @Test
    func containsMatchesMemberRoomNames() {
        let group = speakerGroup(coordinator: "Kitchen", members: ["Kitchen", "Port"])

        #expect(group.contains(roomName: " port "))
    }

    @Test
    func containsMatchesSpotifyPairGroupName() {
        let group = speakerGroup(coordinator: "Kitchen", members: ["Kitchen", "Port"])

        #expect(group.contains(roomName: "Kitchen + Port"))
    }

    @Test
    func containsMatchesSpotifyCountGroupName() {
        let group = speakerGroup(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"])

        #expect(group.contains(roomName: "Kitchen + 2"))
    }

    @Test
    func containsRejectsDifferentGroupPrefix() {
        let group = speakerGroup(coordinator: "Kitchen", members: ["Kitchen", "Port"])

        #expect(!group.contains(roomName: "Office + 1"))
    }

    private func speakerGroup(coordinator: String, members roomNames: [String]) -> SonosSpeakerGroup {
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
