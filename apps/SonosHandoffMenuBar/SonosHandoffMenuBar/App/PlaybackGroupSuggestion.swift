import Combine
import Foundation
import os
import SonosHandoffCore
@preconcurrency import UserNotifications

typealias PlaybackGroupSuggestion = SonosGroupSuggestion

@MainActor
final class PlaybackGroupSuggestionStore: ObservableObject {
    @Published private(set) var suggestions: [PlaybackGroupSuggestion] = []

    func present(_ suggestion: PlaybackGroupSuggestion) {
        if let index = suggestions.firstIndex(where: { $0.matches(identifier: suggestion.id) }) {
            suggestions[index] = suggestion
            return
        }

        suggestions.append(suggestion)
    }

    func refresh(_ candidates: [SonosGroupSuggestionCandidate]) -> [PlaybackGroupSuggestion] {
        guard !candidates.isEmpty else {
            return []
        }

        var refreshedBySpeakerID: [String: SonosGroupSuggestionCandidate] = [:]
        for candidate in candidates {
            refreshedBySpeakerID[candidate.speaker.id] = candidate
        }
        var changedSuggestions: [PlaybackGroupSuggestion] = []
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

    func clear(id: String? = nil) {
        guard let id else {
            suggestions = []
            return
        }

        suggestions.removeAll { $0.matches(identifier: id) }
    }

    func clear(ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        suggestions.removeAll { suggestion in
            ids.contains { suggestion.matches(identifier: $0) }
        }
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
        cancelSuggestion(id: suggestion.id)

        let content = UNMutableNotificationContent()
        content.title = "Sonos speaker available"
        content.body = suggestion.title
        content.categoryIdentifier = PlaybackGroupSuggestionNotification.categoryIdentifier
        content.userInfo = [
            "kind": "groupSuggestion",
            "suggestionID": suggestion.id,
        ]

        deliver(content, identifier: SonosGroupSuggestionNotificationIdentifier.suggestionID(suggestion.id))
    }

    func deliverFailure(_ suggestion: PlaybackGroupSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Could not group speaker"
        content.body = "Could not add \(suggestion.speaker.roomName) to \(suggestion.groupDisplayName)."

        deliver(content, identifier: SonosGroupSuggestionNotificationIdentifier.failureID(suggestion.id))
    }

    func cancelSuggestion(id: String) {
        let identifier = SonosGroupSuggestionNotificationIdentifier.suggestionID(id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func cancelSuggestions(ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        let identifiers = ids.map(SonosGroupSuggestionNotificationIdentifier.suggestionID)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelAllSuggestions() {
        removeAllMatchingNotifications(delivered: false)
        removeAllMatchingNotifications(delivered: true)
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

    private func removeAllMatchingNotifications(delivered: Bool) {
        if delivered {
            notificationCenter.getDeliveredNotifications { [notificationCenter] notifications in
                let identifiers = notifications
                    .map(\.request.identifier)
                    .filter(SonosGroupSuggestionNotificationIdentifier.isSuggestionID)
                guard !identifiers.isEmpty else {
                    return
                }
                notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        } else {
            notificationCenter.getPendingNotificationRequests { [notificationCenter] requests in
                let identifiers = requests
                    .map(\.identifier)
                    .filter(SonosGroupSuggestionNotificationIdentifier.isSuggestionID)
                guard !identifiers.isEmpty else {
                    return
                }
                notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }
    }

}
