import Combine
import Foundation
import os
import SonosHandoffCore
import UserNotifications

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

    var reference: SonosGroupSuggestionReference {
        SonosGroupSuggestionReference(
            speakerID: speaker.id,
            coordinatorRoomName: coordinatorRoomName
        )
    }

    func matches(identifier: String?) -> Bool {
        guard let identifier else {
            return true
        }

        return identifier == id || Self.speakerID(in: identifier) == speaker.id
    }

    private static func speakerID(in identifier: String) -> String {
        guard let separator = identifier.firstIndex(of: "|") else {
            return identifier
        }

        return String(identifier[..<separator])
    }
}

@MainActor
final class PlaybackGroupSuggestionStore: ObservableObject {
    @Published private(set) var suggestions: [PlaybackGroupSuggestion] = []

    func present(_ suggestion: PlaybackGroupSuggestion) {
        if let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
            suggestions[index] = suggestion
            return
        }

        suggestions.append(suggestion)
    }

    func refresh(_ candidates: [SonosGroupSuggestionCandidate]) {
        guard !candidates.isEmpty else {
            return
        }

        let refreshedBySpeakerID = Dictionary(
            uniqueKeysWithValues: candidates.map { candidate in
                (candidate.speaker.id, candidate)
            }
        )
        suggestions = suggestions.map { suggestion in
            guard let candidate = refreshedBySpeakerID[suggestion.speaker.id] else {
                return suggestion
            }

            return PlaybackGroupSuggestion(
                speaker: candidate.speaker,
                coordinatorRoomName: candidate.coordinatorRoomName,
                groupDisplayName: candidate.groupDisplayName,
                detectedAt: suggestion.detectedAt
            )
        }
    }

    func clear(id: String? = nil) {
        guard let id else {
            suggestions = []
            return
        }

        suggestions.removeAll { $0.id == id }
    }

    func clear(ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        suggestions.removeAll { ids.contains($0.id) }
    }
}

enum PlaybackGroupSuggestionNotification {
    static let categoryIdentifier = "sonos-handoff.group-suggestion"
    static let groupActionIdentifier = "sonos-handoff.group-suggestion.group"
}

@MainActor
final class PlaybackGroupSuggestionNotifier {
    private let notificationCenter: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func prepare() {
        let groupAction = UNNotificationAction(
            identifier: PlaybackGroupSuggestionNotification.groupActionIdentifier,
            title: "Group",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: PlaybackGroupSuggestionNotification.categoryIdentifier,
            actions: [groupAction],
            intentIdentifiers: [],
            options: []
        )
        notificationCenter.setNotificationCategories([category])
        notificationCenter.requestAuthorization(options: [.alert]) { [logger] granted, error in
            if let error {
                logger.error("SonosHandoffGroupSuggestionNotification authorization=failure error=\(error.localizedDescription, privacy: .public)")
                return
            }

            logger.info("SonosHandoffGroupSuggestionNotification authorization=\(granted, privacy: .public)")
        }
    }

    func deliverSuggestion(_ suggestion: PlaybackGroupSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Sonos speaker available"
        content.body = suggestion.title
        content.categoryIdentifier = PlaybackGroupSuggestionNotification.categoryIdentifier
        content.userInfo = [
            "kind": "groupSuggestion",
            "suggestionID": suggestion.id,
        ]

        deliver(content, identifier: "group-suggestion-\(suggestion.id)")
    }

    func deliverFailure(_ suggestion: PlaybackGroupSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Could not group speaker"
        content.body = "Could not add \(suggestion.speaker.roomName) to \(suggestion.groupDisplayName)."

        deliver(content, identifier: "group-suggestion-failure-\(suggestion.id)")
    }

    private func deliver(_ content: UNNotificationContent, identifier: String) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        notificationCenter.add(request) { [logger] error in
            if let error {
                logger.error("SonosHandoffGroupSuggestionNotification delivery=failure error=\(error.localizedDescription, privacy: .public)")
                return
            }

            logger.info("SonosHandoffGroupSuggestionNotification delivery=scheduled identifier=\(identifier, privacy: .public)")
        }
    }
}
