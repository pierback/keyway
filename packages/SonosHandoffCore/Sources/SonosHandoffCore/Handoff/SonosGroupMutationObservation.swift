public enum SonosGroupMutationObservation {
    public static func groupContains(
        in state: SonosGroupState,
        coordinatorRoomName: String,
        memberRoomNames: [String]
    ) -> Bool {
        guard let group = state.groups.first(where: { $0.contains(roomName: coordinatorRoomName) }) else {
            return false
        }

        return memberRoomNames.allSatisfy { group.contains(roomName: $0) }
    }

    public static func speakerIsStandalone(
        in state: SonosGroupState,
        roomName: String
    ) -> Bool {
        state.groups.contains { group in
            group.members.count == 1 && group.contains(roomName: roomName)
        }
    }

    public static func coordinatorWasRemoved(
        in state: SonosGroupState,
        oldCoordinatorRoomName: String,
        replacement: SonosSpeaker
    ) -> Bool {
        guard let replacementGroup = state.groups.first(where: { $0.contains(roomName: replacement.roomName) }) else {
            return false
        }

        return replacementGroup.coordinator?.id == replacement.id
            && !replacementGroup.contains(roomName: oldCoordinatorRoomName)
    }
}
