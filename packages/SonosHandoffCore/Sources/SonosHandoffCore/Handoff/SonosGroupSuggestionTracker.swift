public struct SonosGroupSuggestionReference: Equatable, Sendable {
    public let speakerID: String
    public let coordinatorRoomName: String

    public init(speakerID: String, coordinatorRoomName: String) {
        self.speakerID = speakerID
        self.coordinatorRoomName = coordinatorRoomName
    }
}

public enum SonosGroupSuggestionAction: Equatable, Sendable {
    case none
    case keepCurrent
    case clearCurrent
    case present(SonosGroupSuggestionCandidate)
}

public struct SonosGroupSuggestionUpdate: Equatable, Sendable {
    public let action: SonosGroupSuggestionAction
    public let seenSpeakerIDs: Set<String>

    public init(action: SonosGroupSuggestionAction, seenSpeakerIDs: Set<String>) {
        self.action = action
        self.seenSpeakerIDs = seenSpeakerIDs
    }
}

public struct SonosGroupSuggestionTracker: Sendable {
    private let resolver = SonosGroupSuggestionResolver()

    public init() {}

    public func update(
        in state: SonosGroupState,
        selectedRoomName: String?,
        spotifyPlaying: Bool,
        previousSpeakerIDs: Set<String>?,
        currentSuggestion: SonosGroupSuggestionReference?
    ) -> SonosGroupSuggestionUpdate {
        let currentSpeakerIDs = Set(state.speakers.map(\.id))

        guard spotifyPlaying,
              let selectedRoomName
        else {
            return SonosGroupSuggestionUpdate(
                action: currentSuggestion == nil ? .none : .clearCurrent,
                seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                    previousSpeakerIDs: previousSpeakerIDs,
                    currentSpeakerIDs: currentSpeakerIDs,
                    suggestedSpeakerID: nil
                )
            )
        }

        if let currentSuggestion,
           resolver.suggestionStillValid(
               speakerID: currentSuggestion.speakerID,
               coordinatorRoomName: currentSuggestion.coordinatorRoomName,
               in: state,
               selectedRoomName: selectedRoomName
           ) {
            return SonosGroupSuggestionUpdate(
                action: .keepCurrent,
                seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                    previousSpeakerIDs: previousSpeakerIDs,
                    currentSpeakerIDs: currentSpeakerIDs,
                    suggestedSpeakerID: currentSuggestion.speakerID
                )
            )
        }

        if let candidate = resolver.suggestion(
            in: state,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: previousSpeakerIDs
        ) {
            return SonosGroupSuggestionUpdate(
                action: .present(candidate),
                seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                    previousSpeakerIDs: previousSpeakerIDs,
                    currentSpeakerIDs: currentSpeakerIDs,
                    suggestedSpeakerID: candidate.speaker.id
                )
            )
        }

        return SonosGroupSuggestionUpdate(
            action: currentSuggestion == nil ? .none : .clearCurrent,
            seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                previousSpeakerIDs: previousSpeakerIDs,
                currentSpeakerIDs: currentSpeakerIDs,
                suggestedSpeakerID: nil
            )
        )
    }
}
