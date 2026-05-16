import Combine
import Foundation
import SonosHandoffCore

struct PlaybackGroupSuggestion: Identifiable, Equatable, Sendable {
    let speaker: SonosSpeaker
    let coordinatorRoomName: String
    let groupDisplayName: String
    let detectedAt: Date

    var id: String {
        "\(speaker.id)|\(coordinatorRoomName)"
    }

    var title: String {
        "Add \(speaker.roomName) to \(groupDisplayName)?"
    }
}

@MainActor
final class PlaybackGroupSuggestionStore: ObservableObject {
    @Published private(set) var suggestion: PlaybackGroupSuggestion?

    func present(_ suggestion: PlaybackGroupSuggestion) {
        self.suggestion = suggestion
    }

    func clear(id: String? = nil) {
        guard id == nil || suggestion?.id == id else {
            return
        }
        suggestion = nil
    }
}
