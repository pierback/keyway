import Foundation

public struct SonosTransferSuggestionCandidate: Equatable, Sendable {
    public let speaker: SonosSpeaker
    public let outputDisplayName: String
    public let sourceDeviceName: String

    public init(speaker: SonosSpeaker, outputDisplayName: String, sourceDeviceName: String) {
        self.speaker = speaker
        self.outputDisplayName = outputDisplayName
        self.sourceDeviceName = sourceDeviceName
    }
}

public struct SonosTransferSuggestionReference: Equatable, Sendable {
    public let speakerID: String

    public init(speakerID: String) {
        self.speakerID = speakerID
    }

    public var id: String {
        speakerID
    }

    public func matches(identifier: String) -> Bool {
        identifier == speakerID
    }
}

public struct SonosTransferSuggestion: Identifiable, Equatable, Sendable {
    public let speaker: SonosSpeaker
    public let outputDisplayName: String
    public let sourceDeviceName: String
    public let detectedAt: Date

    public init(
        speaker: SonosSpeaker,
        outputDisplayName: String,
        sourceDeviceName: String,
        detectedAt: Date
    ) {
        self.speaker = speaker
        self.outputDisplayName = outputDisplayName
        self.sourceDeviceName = sourceDeviceName
        self.detectedAt = detectedAt
    }

    public init(candidate: SonosTransferSuggestionCandidate, detectedAt: Date) {
        self.init(
            speaker: candidate.speaker,
            outputDisplayName: candidate.outputDisplayName,
            sourceDeviceName: candidate.sourceDeviceName,
            detectedAt: detectedAt
        )
    }

    public var id: String {
        speaker.id
    }

    public var title: String {
        "Move Spotify playback to \(outputDisplayName)?"
    }

    public var reference: SonosTransferSuggestionReference {
        SonosTransferSuggestionReference(speakerID: speaker.id)
    }

    public func matches(identifier: String) -> Bool {
        reference.matches(identifier: identifier)
    }

    public func refreshed(with candidate: SonosTransferSuggestionCandidate) -> SonosTransferSuggestion {
        SonosTransferSuggestion(candidate: candidate, detectedAt: detectedAt)
    }
}

public struct SonosTransferSuggestionCollection: Equatable, Sendable {
    public private(set) var suggestions: [SonosTransferSuggestion]

    public init(suggestions: [SonosTransferSuggestion] = []) {
        self.suggestions = suggestions
    }

    public mutating func present(_ suggestion: SonosTransferSuggestion) {
        if let index = suggestions.firstIndex(where: { $0.matches(identifier: suggestion.id) }) {
            suggestions[index] = suggestion
            return
        }

        suggestions.append(suggestion)
    }

    public mutating func refresh(_ candidates: [SonosTransferSuggestionCandidate]) -> [SonosTransferSuggestion] {
        guard !candidates.isEmpty else {
            return []
        }

        var refreshedBySpeakerID: [String: SonosTransferSuggestionCandidate] = [:]
        for candidate in candidates {
            refreshedBySpeakerID[candidate.speaker.id] = candidate
        }

        var changedSuggestions: [SonosTransferSuggestion] = []
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

public enum SonosTransferSuggestionAction: Equatable, Sendable {
    case none
    case keepCurrent
    case clearCurrent
    case present(SonosTransferSuggestionCandidate)
}

public struct SonosTransferSuggestionUpdate: Equatable, Sendable {
    public let action: SonosTransferSuggestionAction
    public let seenSpeakerIDs: Set<String>
    public let staleSuggestionIDs: Set<String>
    public let refreshedSuggestions: [SonosTransferSuggestionCandidate]

    public init(
        action: SonosTransferSuggestionAction,
        seenSpeakerIDs: Set<String>,
        staleSuggestionIDs: Set<String> = [],
        refreshedSuggestions: [SonosTransferSuggestionCandidate] = []
    ) {
        self.action = action
        self.seenSpeakerIDs = seenSpeakerIDs
        self.staleSuggestionIDs = staleSuggestionIDs
        self.refreshedSuggestions = refreshedSuggestions
    }
}

public struct SonosTransferSuggestionRefresh: Equatable, Sendable {
    public let staleSuggestionIDs: Set<String>
    public let refreshedSuggestions: [SonosTransferSuggestionCandidate]

    public init(
        staleSuggestionIDs: Set<String>,
        refreshedSuggestions: [SonosTransferSuggestionCandidate]
    ) {
        self.staleSuggestionIDs = staleSuggestionIDs
        self.refreshedSuggestions = refreshedSuggestions
    }
}

public struct SonosTransferSuggestionTracker: Sendable {
    private let resolver = SonosTransferSuggestionResolver()

    public init() {}

    public func update(
        in state: SonosGroupState,
        activeDeviceName: String?,
        selectedRoomName: String?,
        spotifyPlaying: Bool,
        previousSpeakerIDs: Set<String>?,
        currentSuggestions: [SonosTransferSuggestionReference]
    ) -> SonosTransferSuggestionUpdate {
        let currentSpeakerIDs = Set(state.speakers.map(\.id))
        let allCurrentSuggestionIDs = Set(currentSuggestions.map(\.id))

        guard spotifyPlaying, selectedRoomName == nil else {
            return SonosTransferSuggestionUpdate(
                action: currentSuggestions.isEmpty ? .none : .clearCurrent,
                seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                    previousSpeakerIDs: previousSpeakerIDs,
                    currentSpeakerIDs: currentSpeakerIDs,
                    suggestedSpeakerID: nil
                ),
                staleSuggestionIDs: allCurrentSuggestionIDs
            )
        }

        let refresh = refresh(
            in: state,
            activeDeviceName: activeDeviceName,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            currentSuggestions: currentSuggestions
        )
        let validSuggestions = currentSuggestions.filter { suggestion in
            !refresh.staleSuggestionIDs.contains(suggestion.id)
        }
        let staleSuggestionIDs = refresh.staleSuggestionIDs
        let validSuggestionSpeakerIDs = Set(validSuggestions.map(\.speakerID))
        let refreshedSuggestions = refresh.refreshedSuggestions

        guard let previousSpeakerIDs else {
            if !validSuggestions.isEmpty {
                return SonosTransferSuggestionUpdate(
                    action: .keepCurrent,
                    seenSpeakerIDs: currentSpeakerIDs,
                    staleSuggestionIDs: staleSuggestionIDs,
                    refreshedSuggestions: refreshedSuggestions
                )
            }

            return SonosTransferSuggestionUpdate(
                action: currentSuggestions.isEmpty ? .none : .clearCurrent,
                seenSpeakerIDs: currentSpeakerIDs,
                staleSuggestionIDs: staleSuggestionIDs,
                refreshedSuggestions: refreshedSuggestions
            )
        }

        if let candidate = resolver.suggestion(
            in: state,
            activeDeviceName: activeDeviceName,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying,
            previousSpeakerIDs: previousSpeakerIDs,
            excludingSpeakerIDs: validSuggestionSpeakerIDs
        ) {
            return SonosTransferSuggestionUpdate(
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
            return SonosTransferSuggestionUpdate(
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

        return SonosTransferSuggestionUpdate(
            action: currentSuggestions.isEmpty ? .none : .clearCurrent,
            seenSpeakerIDs: resolver.seenSpeakerIDsAfterSuggestion(
                previousSpeakerIDs: previousSpeakerIDs,
                currentSpeakerIDs: currentSpeakerIDs,
                suggestedSpeakerID: nil
            ),
            staleSuggestionIDs: staleSuggestionIDs
        )
    }

    public func refresh(
        in state: SonosGroupState,
        activeDeviceName: String?,
        selectedRoomName: String?,
        spotifyPlaying: Bool,
        currentSuggestions: [SonosTransferSuggestionReference]
    ) -> SonosTransferSuggestionRefresh {
        let allCurrentSuggestionIDs = Set(currentSuggestions.map(\.id))
        let validSuggestions = currentSuggestions.filter { suggestion in
            resolver.suggestionStillValid(
                speakerID: suggestion.speakerID,
                in: state,
                activeDeviceName: activeDeviceName,
                selectedRoomName: selectedRoomName,
                spotifyPlaying: spotifyPlaying
            )
        }
        let staleSuggestionIDs = allCurrentSuggestionIDs.subtracting(validSuggestions.map(\.id))
        let refreshedSuggestions = validSuggestions.compactMap { suggestion in
            resolver.refreshedSuggestion(
                speakerID: suggestion.speakerID,
                in: state,
                activeDeviceName: activeDeviceName,
                selectedRoomName: selectedRoomName,
                spotifyPlaying: spotifyPlaying
            )
        }

        return SonosTransferSuggestionRefresh(
            staleSuggestionIDs: staleSuggestionIDs,
            refreshedSuggestions: refreshedSuggestions
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

public struct SonosTransferSuggestionResolver: Sendable {
    public init() {}

    public func suggestion(
        in state: SonosGroupState,
        activeDeviceName: String?,
        selectedRoomName: String?,
        spotifyPlaying: Bool,
        previousSpeakerIDs: Set<String>?,
        excludingSpeakerIDs: Set<String> = []
    ) -> SonosTransferSuggestionCandidate? {
        guard spotifyPlaying,
              selectedRoomName == nil,
              let sourceDeviceName = SonosRoomName.normalized(activeDeviceName)
        else {
            return nil
        }

        let eligibleSpeakerIDs = eligibleSpeakerIDs(
            in: state,
            previousSpeakerIDs: previousSpeakerIDs
        ).subtracting(excludingSpeakerIDs)
        guard !eligibleSpeakerIDs.isEmpty else {
            return nil
        }

        return outputCandidates(in: state)
            .filter { eligibleSpeakerIDs.contains($0.speaker.id) }
            .sorted {
                $0.outputDisplayName.localizedCaseInsensitiveCompare($1.outputDisplayName) == .orderedAscending
            }
            .first
            .map {
                SonosTransferSuggestionCandidate(
                    speaker: $0.speaker,
                    outputDisplayName: $0.outputDisplayName,
                    sourceDeviceName: sourceDeviceName
                )
            }
    }

    public func suggestionStillValid(
        speakerID: String,
        in state: SonosGroupState,
        activeDeviceName: String?,
        selectedRoomName: String?,
        spotifyPlaying: Bool
    ) -> Bool {
        refreshedSuggestion(
            speakerID: speakerID,
            in: state,
            activeDeviceName: activeDeviceName,
            selectedRoomName: selectedRoomName,
            spotifyPlaying: spotifyPlaying
        ) != nil
    }

    public func refreshedSuggestion(
        speakerID: String,
        in state: SonosGroupState,
        activeDeviceName: String?,
        selectedRoomName: String?,
        spotifyPlaying: Bool
    ) -> SonosTransferSuggestionCandidate? {
        guard spotifyPlaying,
              selectedRoomName == nil,
              let sourceDeviceName = SonosRoomName.normalized(activeDeviceName),
              let output = outputCandidates(in: state).first(where: { $0.speaker.id == speakerID })
        else {
            return nil
        }

        return SonosTransferSuggestionCandidate(
            speaker: output.speaker,
            outputDisplayName: output.outputDisplayName,
            sourceDeviceName: sourceDeviceName
        )
    }

    public func seenSpeakerIDsAfterSuggestion(
        previousSpeakerIDs: Set<String>?,
        currentSpeakerIDs: Set<String>,
        suggestedSpeakerID: String?
    ) -> Set<String> {
        guard let suggestedSpeakerID else {
            return currentSpeakerIDs
        }

        var seenSpeakerIDs = previousSpeakerIDs ?? []
        seenSpeakerIDs.insert(suggestedSpeakerID)
        return seenSpeakerIDs.intersection(currentSpeakerIDs)
    }

    private func eligibleSpeakerIDs(
        in state: SonosGroupState,
        previousSpeakerIDs: Set<String>?
    ) -> Set<String> {
        let outputSpeakerIDs = Set(outputCandidates(in: state).map(\.speaker.id))
        guard let previousSpeakerIDs else {
            return outputSpeakerIDs
        }

        return outputSpeakerIDs.intersection(Set(state.speakers.map(\.id)).subtracting(previousSpeakerIDs))
    }

    private func outputCandidates(in state: SonosGroupState) -> [SonosTransferOutputCandidate] {
        state.groups.compactMap { group in
            guard let coordinator = group.coordinator else {
                return nil
            }

            return SonosTransferOutputCandidate(
                speaker: coordinator,
                outputDisplayName: group.displayName
            )
        }
    }
}

private struct SonosTransferOutputCandidate: Equatable, Sendable {
    let speaker: SonosSpeaker
    let outputDisplayName: String
}
