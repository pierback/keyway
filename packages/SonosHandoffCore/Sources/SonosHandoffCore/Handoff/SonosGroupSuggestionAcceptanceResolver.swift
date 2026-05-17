public enum SonosGroupSuggestionAcceptanceDecision: Equatable, Sendable {
    case accept(coordinatorRoomName: String)
    case reject(SonosGroupSuggestionAcceptanceRejection)
}

public enum SonosGroupSuggestionAcceptanceRejection: Equatable, Sendable {
    case noActiveSonosGroup
    case targetGroupChanged
    case speakerAlreadyGrouped
}

public struct SonosGroupSuggestionAcceptanceResolver: Sendable {
    public init() {}

    public func decision(
        for suggestion: SonosGroupSuggestion,
        selectedGroup: SonosSpeakerGroup?
    ) -> SonosGroupSuggestionAcceptanceDecision {
        guard let selectedGroup,
              let coordinator = selectedGroup.coordinator
        else {
            return .reject(.noActiveSonosGroup)
        }

        guard selectedGroup.contains(roomName: suggestion.coordinatorRoomName) else {
            return .reject(.targetGroupChanged)
        }

        guard !selectedGroup.members.contains(where: { $0.id == suggestion.speaker.id }) else {
            return .reject(.speakerAlreadyGrouped)
        }

        return .accept(coordinatorRoomName: coordinator.roomName)
    }
}
