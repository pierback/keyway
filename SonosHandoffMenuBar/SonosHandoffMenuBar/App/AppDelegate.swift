import AppKit
import os
import UserNotifications

import SonosHandoffCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private var volumeHotkeys: VolumeHotkeyController?
    private var statusItemController: KeywayStatusItemController?

    func configure(environment: AppEnvironment) {
        let volumeHotkeys = VolumeHotkeyController(
            volumeService: environment.volumeService,
            outputSelection: environment.outputSelection,
            activePlaybackObserver: environment.activePlaybackObserver,
            mediaTransportActions: environment.mediaTransportActionController
        )
        environment.mediaTransportActionController.relaxRouteShield = { [weak volumeHotkeys] reason in
            volumeHotkeys?.suspendCommandCenterRouteShieldForSelectedDispatch(reason: reason)
        }
        self.volumeHotkeys = volumeHotkeys
        statusItemController = KeywayStatusItemController(environment: environment)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        statusItemController?.start()
        NotificationCenter.default.addObserver(
            forName: .sonosHandoffRefreshHotkeys,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.volumeHotkeys?.refreshMediaFallback(promptIfMissing: true)
            }
        }
        guard let volumeHotkeys else {
            logger.error("SonosHandoffHotkeys state=not_started reason=missing_app_environment")
            return
        }

        volumeHotkeys.start()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            let closingWindow = notification.object as? NSWindow
            DispatchQueue.main.async {
                let hasVisibleSettings = NSApp.windows.contains { window in
                    window !== closingWindow && window.isVisible && window.title.contains("Settings")
                }
                if !hasVisibleSettings {
                    _ = NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        guard categoryIdentifier == PlaybackGroupSuggestionNotification.categoryIdentifier
                || categoryIdentifier == PlaybackTransferSuggestionNotification.categoryIdentifier
                || categoryIdentifier == HeadphoneTransferSuggestionNotification.categoryIdentifier
        else {
            completionHandler()
            return
        }

        guard let suggestionID = response.notification.request.content.userInfo["suggestionID"] as? String else {
            logger.error("SonosHandoffPlaybackNotification action=ignored reason=missing_suggestion_id category=\(categoryIdentifier, privacy: .public)")
            completionHandler()
            return
        }
        let actionIdentifier = response.actionIdentifier

        switch categoryIdentifier {
        case PlaybackGroupSuggestionNotification.categoryIdentifier:
            switch actionIdentifier {
            case PlaybackGroupSuggestionNotification.groupActionIdentifier, UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffAcceptGroupSuggestion, object: suggestionID)
            case PlaybackGroupSuggestionNotification.ignoreActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffIgnoreGroupSuggestion, object: suggestionID)
            default:
                break
            }
        case PlaybackTransferSuggestionNotification.categoryIdentifier:
            switch actionIdentifier {
            case PlaybackTransferSuggestionNotification.transferActionIdentifier, UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffAcceptTransferSuggestion, object: suggestionID)
            case PlaybackTransferSuggestionNotification.ignoreActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffIgnoreTransferSuggestion, object: suggestionID)
            default:
                break
            }
        case HeadphoneTransferSuggestionNotification.categoryIdentifier:
            switch actionIdentifier {
            case HeadphoneTransferSuggestionNotification.transferActionIdentifier, UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffAcceptHeadphoneTransferSuggestion, object: suggestionID)
            case HeadphoneTransferSuggestionNotification.ignoreActionIdentifier:
                NotificationCenter.default.post(name: .sonosHandoffIgnoreHeadphoneTransferSuggestion, object: suggestionID)
            default:
                break
            }
        default:
            break
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
