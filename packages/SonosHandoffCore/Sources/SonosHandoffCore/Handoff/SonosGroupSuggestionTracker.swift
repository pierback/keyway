public struct SonosGroupSuggestionReference: Equatable, Sendable {
    public let speakerID: String
    public let coordinatorRoomName: String

    public init(speakerID: String, coordinatorRoomName: String) {
        self.speakerID = speakerID
        self.coordinatorRoomName = coordinatorRoomName
    }

    public var id: String {
        "\(speakerID)|\(coordinatorRoomName)"
    }

    public func matches(identifier: String?) -> Bool {
        guard let identifier else {
            return true
        }

        return identifier == id || Self.speakerID(in: identifier) == speakerID
    }

    private static func speakerID(in identifier: String) -> String {
        guard let separator = identifier.firstIndex(of: "|") else {
            return identifier
        }

        return String(identifier[..<separator])
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
    public let staleSuggestionIDs: Set<String>
    public let refreshedSuggestions: [SonosGroupSuggestionCandidate]

    public init(
        action: SonosGroupSuggestionAction,
        seenSpeakerIDs: Set<String>,
        staleSuggestionIDs: Set<String> = [],
        refreshedSuggestions: [SonosGroupSuggestionCandidate] = []
    ) {
        self.action = action
        self.seenSpeakerIDs = seenSpeakerIDs
        self.staleSuggestionIDs = staleSuggestionIDs
        self.refreshedSuggestions = refreshedSuggestions
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
        currentSuggestions: [SonosGroupSuggestionReference]
    ) -> SonosGroupSuggestionUpdate {
        let currentSpeakerIDs = Set(state.speakers.map(\.id))
        let allCurrentSuggestionIDs = Set(currentSuggestions.map(\.id))

        guard spotifyPlaying,
              let selectedRoomName
        else {
            return SonosGroupSuggestionUpdate(
                action: currentSuggestions.isEmpty ? .none : .clearCurrent,
                seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                    previousSpeakerIDs: previousSpeakerIDs,
                    currentSpeakerIDs: currentSpeakerIDs,
                    suggestedSpeakerID: nil
                ),
                staleSuggestionIDs: allCurrentSuggestionIDs
            )
        }

        let validSuggestions = currentSuggestions.filter { suggestion in
            resolver.suggestionStillValid(
                speakerID: suggestion.speakerID,
                coordinatorRoomName: suggestion.coordinatorRoomName,
                in: state,
                selectedRoomName: selectedRoomName
            )
        }
        let staleSuggestionIDs = allCurrentSuggestionIDs.subtracting(validSuggestions.map(\.id))
        let validSuggestionSpeakerIDs = Set(validSuggestions.map(\.speakerID))
        let refreshedSuggestions = validSuggestions.compactMap { suggestion in
            resolver.refreshedSuggestion(
                speakerID: suggestion.speakerID,
                in: state,
                selectedRoomName: selectedRoomName
            )
        }

        if let candidate = resolver.suggestion(
            in: state,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: previousSpeakerIDs,
            excludingSpeakerIDs: validSuggestionSpeakerIDs
        ) {
            return SonosGroupSuggestionUpdate(
                action: .present(candidate),
                seenSpeakerIDs: seenSpeakerIDs(
                    previousSpeakerIDs: previousSpeakerIDs,
                    currentSpeakerIDs: currentSpeakerIDs,
                    validSuggestionSpeakerIDs: validSuggestionSpeakerIDs,
                    suggestedSpeakerID: candidate.speaker.id
                ),
                staleSuggestionIDs: staleSuggestionIDs,
                refreshedSuggestions: refreshedSuggestions
            )
        }

        if !validSuggestions.isEmpty {
            return SonosGroupSuggestionUpdate(
                action: .keepCurrent,
                seenSpeakerIDs: seenSpeakerIDs(
                    previousSpeakerIDs: previousSpeakerIDs,
                    currentSpeakerIDs: currentSpeakerIDs,
                    validSuggestionSpeakerIDs: validSuggestionSpeakerIDs,
                    suggestedSpeakerID: nil
                ),
                staleSuggestionIDs: staleSuggestionIDs,
                refreshedSuggestions: refreshedSuggestions
            )
        }

        return SonosGroupSuggestionUpdate(
            action: currentSuggestions.isEmpty ? .none : .clearCurrent,
            seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                previousSpeakerIDs: previousSpeakerIDs,
                currentSpeakerIDs: currentSpeakerIDs,
                suggestedSpeakerID: nil
            ),
            staleSuggestionIDs: staleSuggestionIDs
        )
    }

    private func seenSpeakerIDs(
        previousSpeakerIDs: Set<String>?,
        currentSpeakerIDs: Set<String>,
        validSuggestionSpeakerIDs: Set<String>,
        suggestedSpeakerID: String?
    ) -> Set<String> {
        var seenSpeakerIDs = previousSpeakerIDs ?? []
        seenSpeakerIDs.formUnion(validSuggestionSpeakerIDs)
        if let suggestedSpeakerID {
            seenSpeakerIDs.insert(suggestedSpeakerID)
        }
        return seenSpeakerIDs.intersection(currentSpeakerIDs)
    }
}
