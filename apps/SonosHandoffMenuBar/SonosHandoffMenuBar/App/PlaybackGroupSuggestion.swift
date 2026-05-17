import Combine
import Foundation
import os
import SonosHandoffCore
@preconcurrency import UserNotifications

typealias PlaybackGroupSuggestion = SonosGroupSuggestion

@MainActor
final class PlaybackGroupSuggestionStore: ObservableObject {
    @Published private(set) var suggestions: [PlaybackGroupSuggestion] = []
    private var collection = SonosGroupSuggestionCollection()

    func present(_ suggestion: PlaybackGroupSuggestion) {
        collection.present(suggestion)
        suggestions = collection.suggestions
    }

    func refresh(_ candidates: [SonosGroupSuggestionCandidate]) -> [PlaybackGroupSuggestion] {
        let changedSuggestions = collection.refresh(candidates)
        suggestions = collection.suggestions
        return changedSuggestions
    }

    func clear(id: String? = nil) {
        collection.clear(id: id)
        suggestions = collection.suggestions
    }

    func clear(ids: Set<String>) {
        collection.clear(ids: ids)
        suggestions = collection.suggestions
    }
}

enum PlaybackGroupSuggestionNotification {
    static let categoryIdentifier = "sonos-handoff.group-suggestion"
    static let groupActionIdentifier = "sonos-handoff.group-suggestion.group"
    static let ignoreActionIdentifier = "sonos-handoff.group-suggestion.ignore"
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
        let ignoreAction = UNNotificationAction(
            identifier: PlaybackGroupSuggestionNotification.ignoreActionIdentifier,
            title: "Ignore",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: PlaybackGroupSuggestionNotification.categoryIdentifier,
            actions: [groupAction, ignoreAction],
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
        let identifiers = SonosGroupSuggestionNotificationIdentifier.allIDs(id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelSuggestions(ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        let identifiers = SonosGroupSuggestionNotificationIdentifier.allIDs(ids)
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
                    .filter(SonosGroupSuggestionNotificationIdentifier.isManagedID)
                guard !identifiers.isEmpty else {
                    return
                }
                notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        } else {
            notificationCenter.getPendingNotificationRequests { [notificationCenter] requests in
                let identifiers = requests
                    .map(\.identifier)
                    .filter(SonosGroupSuggestionNotificationIdentifier.isManagedID)
                guard !identifiers.isEmpty else {
                    return
                }
                notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }
    }

}
