import Testing
@testable import SonosHandoffCore

struct SonosOutputGroupOrderingResolverTests {
    private let resolver = SonosOutputGroupOrderingResolver()

    @Test
    func putsActiveGroupBeforeOtherOutputs() {
        let ordered = resolver.orderedGroups(
            [
                standalone("Office"),
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standalone("Bath"),
            ],
            currentRoomName: "Port"
        )

        #expect(ordered.map(\.displayName) == ["Kitchen + Port", "Bath", "Office"])
    }

    @Test
    func matchesSpotifyCountSuffixForActiveGroup() {
        let ordered = resolver.orderedGroups(
            [
                standalone("Office"),
                group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Bath"]),
            ],
            currentRoomName: "Kitchen + 2"
        )

        #expect(ordered.map(\.displayName) == ["Kitchen + 2", "Office"])
    }

    @Test
    func sortsOutputsByDisplayNameWhenNoActiveGroupMatches() {
        let ordered = resolver.orderedGroups(
            [
                standalone("Office"),
                group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
                standalone("Bath"),
            ],
            currentRoomName: nil
        )

        #expect(ordered.map(\.displayName) == ["Bath", "Kitchen + Port", "Office"])
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
