import Foundation

public struct SonosGroupSuggestion: Identifiable, Equatable, Sendable {
    public let speaker: SonosSpeaker
    public let coordinatorRoomName: String
    public let groupDisplayName: String
    public let detectedAt: Date

    public init(
        speaker: SonosSpeaker,
        coordinatorRoomName: String,
        groupDisplayName: String,
        detectedAt: Date
    ) {
        self.speaker = speaker
        self.coordinatorRoomName = coordinatorRoomName
        self.groupDisplayName = groupDisplayName
        self.detectedAt = detectedAt
    }

    public init(candidate: SonosGroupSuggestionCandidate, detectedAt: Date) {
        self.init(
            speaker: candidate.speaker,
            coordinatorRoomName: candidate.coordinatorRoomName,
            groupDisplayName: candidate.groupDisplayName,
            detectedAt: detectedAt
        )
    }

    public var id: String {
        "\(speaker.id)|\(coordinatorRoomName)"
    }

    public var title: String {
        "Add \(speaker.roomName) to \(groupDisplayName)?"
    }

    public var reference: SonosGroupSuggestionReference {
        SonosGroupSuggestionReference(
            speakerID: speaker.id,
            coordinatorRoomName: coordinatorRoomName
        )
    }

    public func matches(identifier: String) -> Bool {
        reference.matches(identifier: identifier)
    }

    public func refreshed(with candidate: SonosGroupSuggestionCandidate) -> SonosGroupSuggestion {
        SonosGroupSuggestion(candidate: candidate, detectedAt: detectedAt)
    }
}

public struct SonosGroupSuggestionCollection: Equatable, Sendable {
    public private(set) var suggestions: [SonosGroupSuggestion]

    public init(suggestions: [SonosGroupSuggestion] = []) {
        self.suggestions = suggestions
    }

    public mutating func present(_ suggestion: SonosGroupSuggestion) {
        if let index = suggestions.firstIndex(where: { $0.matches(identifier: suggestion.id) }) {
            suggestions[index] = suggestion
            return
        }

        suggestions.append(suggestion)
    }

    public mutating func refresh(_ candidates: [SonosGroupSuggestionCandidate]) -> [SonosGroupSuggestion] {
        guard !candidates.isEmpty else {
            return []
        }

        var refreshedBySpeakerID: [String: SonosGroupSuggestionCandidate] = [:]
        for candidate in candidates {
            refreshedBySpeakerID[candidate.speaker.id] = candidate
        }

        var changedSuggestions: [SonosGroupSuggestion] = []
        suggestions = suggestions.map { suggestion in
            guard let candidate = refreshedBySpeakerID[suggestion.speaker.id] else {
                return suggestion
            }

            let refreshedSuggestion = suggestion.refreshed(with: candidate)
            if refreshedSuggestion != suggestion {
                changedSuggestions.append(refreshedSuggestion)
            }
            return refreshedSuggestion
        }
        return changedSuggestions
    }

    public mutating func clear(id: String? = nil) {
        guard let id else {
            suggestions = []
            return
        }

        suggestions.removeAll { $0.matches(identifier: id) }
    }

    public mutating func clear(ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        suggestions.removeAll { suggestion in
            ids.contains { suggestion.matches(identifier: $0) }
        }
    }
}
