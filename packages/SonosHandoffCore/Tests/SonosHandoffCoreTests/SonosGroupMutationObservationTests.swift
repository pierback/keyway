import Testing
@testable import SonosHandoffCore

struct SonosGroupMutationObservationTests {
    @Test
    func groupContainsRequiresEveryExpectedMember() {
        let state = SonosGroupState(groups: [
            group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"]),
            standalone("Bath"),
        ])

        #expect(SonosGroupMutationObservation.groupContains(
            in: state,
            coordinatorRoomName: "Kitchen",
            memberRoomNames: ["Port", "Office"]
        ))
        #expect(!SonosGroupMutationObservation.groupContains(
            in: state,
            coordinatorRoomName: "Kitchen",
            memberRoomNames: ["Bath"]
        ))
    }

    @Test
    func speakerIsStandaloneRequiresSingleMemberGroup() {
        let state = SonosGroupState(groups: [
            group(coordinator: "Kitchen", members: ["Kitchen", "Port"]),
            standalone("Office"),
        ])

        #expect(SonosGroupMutationObservation.speakerIsStandalone(in: state, roomName: "Office"))
        #expect(!SonosGroupMutationObservation.speakerIsStandalone(in: state, roomName: "Port"))
    }

    @Test
    func coordinatorWasRemovedRequiresReplacementCoordinatorWithoutOldCoordinator() {
        let port = speaker("Port")
        let migrated = SonosGroupState(groups: [
            group(coordinator: "Port", members: ["Port", "Office"]),
            standalone("Kitchen"),
        ])
        let stillGrouped = SonosGroupState(groups: [
            group(coordinator: "Port", members: ["Port", "Kitchen", "Office"]),
        ])

        #expect(SonosGroupMutationObservation.coordinatorWasRemoved(
            in: migrated,
            oldCoordinatorRoomName: "Kitchen",
            replacement: port
        ))
        #expect(!SonosGroupMutationObservation.coordinatorWasRemoved(
            in: stillGrouped,
            oldCoordinatorRoomName: "Kitchen",
            replacement: port
        ))
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
