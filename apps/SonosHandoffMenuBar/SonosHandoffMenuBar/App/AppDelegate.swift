import AppKit
import os
import UserNotifications

import SonosHandoffCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Hotkeys")
    private var volumeHotkeys: VolumeHotkeyController?

    func configure(environment: AppEnvironment) {
        volumeHotkeys = VolumeHotkeyController(
            volumeService: environment.volumeService,
            outputSelection: environment.outputSelection,
            configStore: environment.configStore
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            forName: .sonosHandoffRefreshHotkeys,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.volumeHotkeys?.refreshMediaFallback(promptIfMissing: false)
            }
        }
        guard let volumeHotkeys else {
            logger.error("SonosHandoffHotkeys state=not_started reason=missing_app_environment")
            return
        }

        volumeHotkeys.start()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer {
            completionHandler()
        }

        guard response.notification.request.content.categoryIdentifier == PlaybackGroupSuggestionNotification.categoryIdentifier else {
            return
        }

        guard let suggestionID = response.notification.request.content.userInfo["suggestionID"] as? String else {
            logger.error("SonosHandoffGroupSuggestionNotification action=ignored reason=missing_suggestion_id")
            return
        }
        let actionIdentifier = response.actionIdentifier

        Task { @MainActor in
            switch actionIdentifier {
            case PlaybackGroupSuggestionNotification.groupActionIdentifier, UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffAcceptGroupSuggestion, object: suggestionID)
            case PlaybackGroupSuggestionNotification.ignoreActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffIgnoreGroupSuggestion, object: suggestionID)
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
