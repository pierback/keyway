import Foundation
import os
@preconcurrency import UserNotifications

struct HeadphoneTransferSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let outputID: UInt32
    let outputName: String
    let spotifyDeviceName: String
    let activeRoomName: String
    let detectedAt: Date

    init(
        output: MacAudioOutputDevice,
        spotifyDeviceName: String,
        activeRoomName: String,
        detectedAt: Date = Date()
    ) {
        self.id = "headphone-transfer-\(output.id)"
        self.outputID = output.id
        self.outputName = output.name
        self.spotifyDeviceName = spotifyDeviceName
        self.activeRoomName = activeRoomName
        self.detectedAt = detectedAt
    }

    var title: String {
        "Spotify is playing on \(activeRoomName). Switch it to \(outputName)?"
    }

    func matches(identifier: String) -> Bool {
        id == identifier
    }
}

@MainActor
final class HeadphoneTransferSuggestionStore {
    private(set) var suggestion: HeadphoneTransferSuggestion?
    private var suppressedOutputIDs: Set<UInt32> = []

    @discardableResult
    func present(_ suggestion: HeadphoneTransferSuggestion) -> Bool {
        guard !suppressedOutputIDs.contains(suggestion.outputID) else {
            return false
        }

        guard self.suggestion?.id != suggestion.id else {
            return false
        }

        self.suggestion = suggestion
        return true
    }

    @discardableResult
    func suppress(id: String) -> Set<String> {
        guard let suggestion, suggestion.matches(identifier: id) else {
            return []
        }

        suppressedOutputIDs.insert(suggestion.outputID)
        return clear(id: id)
    }

    @discardableResult
    func clear(id: String? = nil) -> Set<String> {
        guard let suggestion else {
            return []
        }

        if let id {
            guard suggestion.matches(identifier: id) else {
                return []
            }
        }

        self.suggestion = nil
        return [suggestion.id]
    }

    @discardableResult
    func clearUnavailable(currentHeadphoneOutputID: UInt32?) -> Set<String> {
        if let currentHeadphoneOutputID {
            suppressedOutputIDs = Set(suppressedOutputIDs.filter { $0 == currentHeadphoneOutputID })
        } else {
            suppressedOutputIDs.removeAll()
        }

        guard let suggestion else {
            return []
        }

        guard suggestion.outputID != currentHeadphoneOutputID else {
            return []
        }

        self.suggestion = nil
        return [suggestion.id]
    }
}

@MainActor
final class HeadphoneTransferSuggestionPresenter {
    private let store: HeadphoneTransferSuggestionStore
    private let notifier: HeadphoneTransferSuggestionNotifier

    init(
        store: HeadphoneTransferSuggestionStore,
        notifier: HeadphoneTransferSuggestionNotifier
    ) {
        self.store = store
        self.notifier = notifier
    }

    @discardableResult
    func presentIfNeeded(_ suggestion: HeadphoneTransferSuggestion) -> Bool {
        guard store.present(suggestion) else {
            return false
        }

        notifier.deliverSuggestion(suggestion)
        return true
    }

    func clear(id: String) {
        notifier.cancelSuggestions(ids: store.clear(id: id))
    }

    func suppress(id: String) {
        notifier.cancelSuggestions(ids: store.suppress(id: id))
    }

    func clearUnavailable(currentHeadphoneOutputID: UInt32?) {
        notifier.cancelSuggestions(ids: store.clearUnavailable(currentHeadphoneOutputID: currentHeadphoneOutputID))
    }

    func clearAll() {
        notifier.cancelSuggestions(ids: store.clear())
    }

    func deliverFailure(_ suggestion: HeadphoneTransferSuggestion, message: String) {
        notifier.deliverFailure(suggestion, message: message)
    }
}

enum HeadphoneTransferSuggestionNotification {
    static let categoryIdentifier = "sonos-handoff.headphone-transfer-suggestion"
    static let transferActionIdentifier = "sonos-handoff.headphone-transfer-suggestion.transfer"
    static let ignoreActionIdentifier = "sonos-handoff.headphone-transfer-suggestion.ignore"

    static var category: UNNotificationCategory {
        let transferAction = UNNotificationAction(
            identifier: transferActionIdentifier,
            title: "Switch",
            options: []
        )
        let ignoreAction = UNNotificationAction(
            identifier: ignoreActionIdentifier,
            title: "Ignore",
            options: []
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [transferAction, ignoreAction],
            intentIdentifiers: [],
            options: []
        )
    }
}

@MainActor
final class HeadphoneTransferSuggestionNotifier {
    private let notificationCenter: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Playback")

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func deliverSuggestion(_ suggestion: HeadphoneTransferSuggestion) {
        cancelSuggestion(id: suggestion.id)

        let content = UNMutableNotificationContent()
        content.title = "Headphones connected"
        content.body = suggestion.title
        content.categoryIdentifier = HeadphoneTransferSuggestionNotification.categoryIdentifier
        content.userInfo = [
            "kind": "headphoneTransferSuggestion",
            "suggestionID": suggestion.id,
        ]

        deliver(content, identifier: HeadphoneTransferSuggestionNotificationIdentifier.suggestionID(suggestion.id))
    }

    func deliverFailure(_ suggestion: HeadphoneTransferSuggestion, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Could not move playback"
        content.body = message

        deliver(content, identifier: HeadphoneTransferSuggestionNotificationIdentifier.failureID(suggestion.id))
    }

    func cancelSuggestion(id: String) {
        let identifiers = HeadphoneTransferSuggestionNotificationIdentifier.allIDs(id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelSuggestions(ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        let identifiers = HeadphoneTransferSuggestionNotificationIdentifier.allIDs(ids)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func deliver(_ content: UNNotificationContent, identifier: String) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        PlaybackSuggestionNotificationAuthorization.deliver(
            request: request,
            notificationCenter: notificationCenter,
            logger: logger,
            logCategory: "HeadphoneTransferSuggestionNotification"
        )
    }
}

enum HeadphoneTransferSuggestionNotificationIdentifier {
    private static let suggestionPrefix = "headphone-transfer-suggestion-"
    private static let failurePrefix = "headphone-transfer-suggestion-failure-"

    static func suggestionID(_ suggestionID: String) -> String {
        "\(suggestionPrefix)\(suggestionID)"
    }

    static func failureID(_ suggestionID: String) -> String {
        "\(failurePrefix)\(suggestionID)"
    }

    static func allIDs(_ id: String) -> [String] {
        [
            suggestionID(id),
            failureID(id),
        ]
    }

    static func allIDs(_ suggestionIDs: Set<String>) -> [String] {
        suggestionIDs.flatMap(allIDs)
    }
}
