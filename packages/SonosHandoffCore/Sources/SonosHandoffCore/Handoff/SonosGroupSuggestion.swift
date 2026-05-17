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
