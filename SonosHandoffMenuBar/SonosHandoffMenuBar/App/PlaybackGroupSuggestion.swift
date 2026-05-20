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

    @discardableResult
    func clear(id: String? = nil) -> Set<String> {
        let removedIDs = Set(collection.suggestions.compactMap { suggestion in
            guard let id else {
                return suggestion.id
            }

            return suggestion.matches(identifier: id) ? suggestion.id : nil
        })
        collection.clear(id: id)
        suggestions = collection.suggestions

        return removedIDs
    }

    @discardableResult
    func clear(ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else {
            return []
        }

        let removedIDs = Set(collection.suggestions.compactMap { suggestion in
            ids.contains { suggestion.matches(identifier: $0) } ? suggestion.id : nil
        })
        collection.clear(ids: ids)
        suggestions = collection.suggestions

        return removedIDs
    }
}

@MainActor
final class PlaybackGroupSuggestionPresenter {
    private let store: PlaybackGroupSuggestionStore
    private let notifier: PlaybackGroupSuggestionNotifier

    init(
        store: PlaybackGroupSuggestionStore,
        notifier: PlaybackGroupSuggestionNotifier
    ) {
        self.store = store
        self.notifier = notifier
    }

    func apply(_ refresh: SonosGroupSuggestionRefresh) {
        notifier.cancelSuggestions(ids: store.clear(ids: refresh.staleSuggestionIDs))
        let refreshedSuggestions = store.refresh(refresh.refreshedSuggestions)
        for suggestion in refreshedSuggestions {
            notifier.deliverSuggestion(suggestion)
        }
    }

    @discardableResult
    func apply(
        _ update: SonosGroupSuggestionUpdate,
        detectedAt: Date = Date()
    ) -> PlaybackGroupSuggestion? {
        apply(SonosGroupSuggestionRefresh(
            staleSuggestionIDs: update.staleSuggestionIDs,
            refreshedSuggestions: update.refreshedSuggestions
        ))

        switch update.action {
        case .none, .keepCurrent:
            return nil
        case .clearCurrent:
            clearAll()
            return nil
        case .present(let candidate):
            let suggestion = PlaybackGroupSuggestion(candidate: candidate, detectedAt: detectedAt)
            store.present(suggestion)
            notifier.deliverSuggestion(suggestion)
            return suggestion
        }
    }

    func clear(id: String) {
        notifier.cancelSuggestions(ids: store.clear(id: id))
    }

    func deliverFailure(_ suggestion: PlaybackGroupSuggestion) {
        notifier.deliverFailure(suggestion)
    }

    func clearAll() {
        notifier.cancelSuggestions(ids: store.clear())
    }
}

enum PlaybackGroupSuggestionNotification {
    static let categoryIdentifier = "sonos-handoff.group-suggestion"
    static let groupActionIdentifier = "sonos-handoff.group-suggestion.group"
    static let ignoreActionIdentifier = "sonos-handoff.group-suggestion.ignore"

    static var category: UNNotificationCategory {
        let groupAction = UNNotificationAction(
            identifier: groupActionIdentifier,
            title: "Group",
            options: []
        )
        let ignoreAction = UNNotificationAction(
            identifier: ignoreActionIdentifier,
            title: "Ignore",
            options: []
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [groupAction, ignoreAction],
            intentIdentifiers: [],
            options: []
        )
    }
}

typealias PlaybackTransferSuggestion = SonosTransferSuggestion

@MainActor
final class PlaybackTransferSuggestionStore {
    private var collection = SonosTransferSuggestionCollection()

    var suggestions: [PlaybackTransferSuggestion] {
        collection.suggestions
    }

    func present(_ suggestion: PlaybackTransferSuggestion) {
        collection.present(suggestion)
    }

    func refresh(_ candidates: [SonosTransferSuggestionCandidate]) -> [PlaybackTransferSuggestion] {
        collection.refresh(candidates)
    }

    @discardableResult
    func clear(id: String? = nil) -> Set<String> {
        let removedIDs = Set(collection.suggestions.compactMap { suggestion in
            guard let id else {
                return suggestion.id
            }

            return suggestion.matches(identifier: id) ? suggestion.id : nil
        })
        collection.clear(id: id)

        return removedIDs
    }

    @discardableResult
    func clear(ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else {
            return []
        }

        let removedIDs = Set(collection.suggestions.compactMap { suggestion in
            ids.contains { suggestion.matches(identifier: $0) } ? suggestion.id : nil
        })
        collection.clear(ids: ids)

        return removedIDs
    }
}

@MainActor
final class PlaybackTransferSuggestionPresenter {
    private let store: PlaybackTransferSuggestionStore
    private let notifier: PlaybackTransferSuggestionNotifier

    init(
        store: PlaybackTransferSuggestionStore,
        notifier: PlaybackTransferSuggestionNotifier
    ) {
        self.store = store
        self.notifier = notifier
    }

    func apply(_ refresh: SonosTransferSuggestionRefresh) {
        notifier.cancelSuggestions(ids: store.clear(ids: refresh.staleSuggestionIDs))
        let refreshedSuggestions = store.refresh(refresh.refreshedSuggestions)
        for suggestion in refreshedSuggestions {
            notifier.deliverSuggestion(suggestion)
        }
    }

    @discardableResult
    func apply(
        _ update: SonosTransferSuggestionUpdate,
        detectedAt: Date = Date()
    ) -> PlaybackTransferSuggestion? {
        apply(SonosTransferSuggestionRefresh(
            staleSuggestionIDs: update.staleSuggestionIDs,
            refreshedSuggestions: update.refreshedSuggestions
        ))

        switch update.action {
        case .none, .keepCurrent:
            return nil
        case .clearCurrent:
            clearAll()
            return nil
        case .present(let candidate):
            let suggestion = PlaybackTransferSuggestion(candidate: candidate, detectedAt: detectedAt)
            store.present(suggestion)
            notifier.deliverSuggestion(suggestion)
            return suggestion
        }
    }

    func clear(id: String) {
        notifier.cancelSuggestions(ids: store.clear(id: id))
    }

    func deliverFailure(_ suggestion: PlaybackTransferSuggestion, message: String) {
        notifier.deliverFailure(suggestion, message: message)
    }

    func clearAll() {
        notifier.cancelSuggestions(ids: store.clear())
    }
}

enum PlaybackTransferSuggestionNotification {
    static let categoryIdentifier = "sonos-handoff.transfer-suggestion"
    static let transferActionIdentifier = "sonos-handoff.transfer-suggestion.transfer"
    static let ignoreActionIdentifier = "sonos-handoff.transfer-suggestion.ignore"

    static var category: UNNotificationCategory {
        let transferAction = UNNotificationAction(
            identifier: transferActionIdentifier,
            title: "Move",
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

enum PlaybackSuggestionNotificationRegistrar {
    static func prepare(
        notificationCenter: UNUserNotificationCenter,
        logger _: os.Logger
    ) {
        notificationCenter.setNotificationCategories([
            PlaybackGroupSuggestionNotification.category,
            PlaybackTransferSuggestionNotification.category,
        ])
    }
}

enum PlaybackSuggestionNotificationAuthorization {
    static func requestFromSettings(
        notificationCenter: UNUserNotificationCenter,
        logger: os.Logger,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        request(notificationCenter: notificationCenter, logger: logger, completion: completion)
    }

    static func deliver(
        request: UNNotificationRequest,
        notificationCenter: UNUserNotificationCenter,
        logger: os.Logger,
        logCategory: String
    ) {
        notificationCenter.getNotificationSettings { [notificationCenter, logger] settings in
            guard canDeliver(settings) else {
                logger.info("SonosHandoff\(logCategory) delivery=blocked reason=\(blockedReason(settings), privacy: .public)")
                return
            }

            add(
                request: request,
                notificationCenter: notificationCenter,
                logger: logger,
                logCategory: logCategory
            )
        }
    }

    private static func request(
        notificationCenter: UNUserNotificationCenter,
        logger: os.Logger,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        notificationCenter.requestAuthorization(options: [.alert]) { [logger] granted, error in
            if let error {
                logger.error("SonosHandoffPlaybackNotification authorization=failure error=\(error.localizedDescription, privacy: .public)")
                completion(false)
                return
            }

            logger.info("SonosHandoffPlaybackNotification authorization=\(granted, privacy: .public)")
            completion(granted)
        }
    }

    private static func add(
        request: UNNotificationRequest,
        notificationCenter: UNUserNotificationCenter,
        logger: os.Logger,
        logCategory: String
    ) {
        notificationCenter.add(request) { [logger] error in
            if let error {
                logger.error("SonosHandoff\(logCategory) delivery=failure error=\(error.localizedDescription, privacy: .public)")
                return
            }

            logger.info("SonosHandoff\(logCategory) delivery=scheduled identifier=\(request.identifier, privacy: .public)")
        }
    }

    private static func canDeliver(_ settings: UNNotificationSettings) -> Bool {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return settings.alertSetting != .disabled && settings.alertStyle != .none
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func blockedReason(_ settings: UNNotificationSettings) -> String {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            if settings.alertSetting == .disabled {
                return "notifications_alerts_disabled"
            }
            return settings.alertStyle == .none ? "notifications_alert_style_none" : "notifications_unavailable"
        case .notDetermined:
            return "notifications_not_configured"
        case .denied:
            return "notifications_denied"
        @unknown default:
            return "notifications_unknown_authorization"
        }
    }
}

@MainActor
final class PlaybackGroupSuggestionNotifier {
    private let notificationCenter: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func prepare() {
        PlaybackSuggestionNotificationRegistrar.prepare(
            notificationCenter: notificationCenter,
            logger: logger
        )
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
            logCategory: "GroupSuggestionNotification"
        )
    }
}

@MainActor
final class PlaybackTransferSuggestionNotifier {
    private let notificationCenter: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Playback")

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func deliverSuggestion(_ suggestion: PlaybackTransferSuggestion) {
        cancelSuggestion(id: suggestion.id)

        let content = UNMutableNotificationContent()
        content.title = "Sonos speaker available"
        content.body = suggestion.title
        content.categoryIdentifier = PlaybackTransferSuggestionNotification.categoryIdentifier
        content.userInfo = [
            "kind": "transferSuggestion",
            "suggestionID": suggestion.id,
        ]

        deliver(content, identifier: PlaybackTransferSuggestionNotificationIdentifier.suggestionID(suggestion.id))
    }

    func deliverFailure(_ suggestion: PlaybackTransferSuggestion, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Could not move playback"
        content.body = message

        deliver(content, identifier: PlaybackTransferSuggestionNotificationIdentifier.failureID(suggestion.id))
    }

    func cancelSuggestion(id: String) {
        let identifiers = PlaybackTransferSuggestionNotificationIdentifier.allIDs(id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelSuggestions(ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        let identifiers = PlaybackTransferSuggestionNotificationIdentifier.allIDs(ids)
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
            logCategory: "TransferSuggestionNotification"
        )
    }
}

enum PlaybackTransferSuggestionNotificationIdentifier {
    private static let suggestionPrefix = "transfer-suggestion-"
    private static let failurePrefix = "transfer-suggestion-failure-"

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
        suggestionIDs
            .flatMap(allIDs)
    }

    static func isSuggestionID(_ identifier: String) -> Bool {
        identifier.hasPrefix(suggestionPrefix) && !identifier.hasPrefix(failurePrefix)
    }

    static func isManagedID(_ identifier: String) -> Bool {
        isSuggestionID(identifier) || identifier.hasPrefix(failurePrefix)
    }
}
