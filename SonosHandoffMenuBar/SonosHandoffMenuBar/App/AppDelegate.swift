import AppKit
import os
import UserNotifications

import SonosHandoffCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Hotkeys")
    private var runtime: AppRuntime?
    private var statusItemController: KeywayStatusItemController?
    private var permissionOnboardingController: PermissionOnboardingWindowController?
    private var refreshHotkeysObserver: NSObjectProtocol?

    func configure(
        runtime: AppRuntime,
        playback: PlaybackSyncController,
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        mediaSourceStore: MediaSourceStore,
        mediaAudioControlController: MediaAudioControlController,
        mediaTransportActionController: MediaTransportActionController
    ) {
        self.runtime = runtime
        statusItemController = KeywayStatusItemController(
            playback: playback,
            mediaRemoteController: mediaRemoteController,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController,
            mediaSourceStore: mediaSourceStore,
            mediaAudioControlController: mediaAudioControlController,
            mediaTransportActionController: mediaTransportActionController,
            isRuntimeStarted: { [weak runtime] in
                runtime?.isStarted == true
            },
            isSonosEnabled: { [weak runtime] in
                runtime?.isSonosEnabled == true
            },
            presentPermissionOnboarding: { [weak self] in
                _ = self?.permissionOnboardingController?.present()
            }
        )
        permissionOnboardingController = PermissionOnboardingWindowController(
            refreshMediaPermissions: { [weak runtime] in
                runtime?.refreshMediaPermissions()
            },
            startLocalNetworkFeatures: { [weak self] in
                self?.runtime?.enableSonos()
            }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        statusItemController?.start()
        refreshHotkeysObserver = NotificationCenter.default.addObserver(
            forName: .sonosHandoffRefreshHotkeys,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runtime?.refreshMediaPermissions()
            }
        }
        guard let runtime else {
            logger.error("KeywayRuntime state=not_started reason=missing_app_environment")
            return
        }

        runtime.start()
        if UserDefaults.standard.bool(
            forKey: PermissionOnboardingWindowController.localNetworkRequestedKey
        ) {
            runtime.enableSonos()
        }
        _ = permissionOnboardingController!.presentIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let refreshHotkeysObserver {
            NotificationCenter.default.removeObserver(refreshHotkeysObserver)
        }
        refreshHotkeysObserver = nil
        statusItemController?.stop()
        runtime?.stop()
        UNUserNotificationCenter.current().delegate = nil
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
