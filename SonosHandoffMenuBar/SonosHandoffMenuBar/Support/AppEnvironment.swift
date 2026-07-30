import AppKit
import os
import SonosHandoffCore

@MainActor
struct AppEnvironment {
    let configImportService: ConfigImportService
    let configStore: any ConfigStoring
    let tokenStore: any TokenStoring
    let connectTokenStatusStore: any ConnectTokenStatusChecking
    let authCoordinator: any SpotifyAuthCoordinating
    let volumeService: any SpeakerVolumeAdjusting
    let activePlaybackObserver: any SpotifyActivePlaybackObserving
    let outputSelection: PlaybackOutputSelection
    let outputDirectory: PlaybackOutputDirectory
    let playbackBackgroundSync: PlaybackBackgroundSync
    let playbackSyncController: PlaybackSyncController
    let chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller
    let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    let mediaRemoteController: MediaRemoteController
    let mediaSourceStore: MediaSourceStore
    let mediaAudioControlController: MediaAudioControlController
    let mediaTransportActionController: MediaTransportActionController
    let mediaRoutingProbeController: MediaRoutingProbeController
    let volumeHotkeys: VolumeHotkeyController

    static func live() -> AppEnvironment {
        let configImportService = ConfigImportService()
        let configStore = ConfigStore()
        let tokenStore = KeychainTokenStore()
        let connectTokenStatusStore = ConnectTokenStatusStore()
        let authCoordinator = SpotifyAuthCoordinator(
            tokenStore: tokenStore,
            configStore: configStore,
            browserOpener: { NSWorkspace.shared.open($0) }
        )
        let spotifyConnectService = SpotifyConnectHandoffService()
        let outputSelection = PlaybackOutputSelection()
        let groupSuggestionStore = PlaybackGroupSuggestionStore()
        let groupSuggestionNotifier = PlaybackGroupSuggestionNotifier()
        let groupSuggestionPresenter = PlaybackGroupSuggestionPresenter(
            store: groupSuggestionStore,
            notifier: groupSuggestionNotifier
        )
        let transferSuggestionStore = PlaybackTransferSuggestionStore()
        let transferSuggestionNotifier = PlaybackTransferSuggestionNotifier()
        let transferSuggestionPresenter = PlaybackTransferSuggestionPresenter(
            store: transferSuggestionStore,
            notifier: transferSuggestionNotifier
        )
        let headphoneTransferSuggestionStore = HeadphoneTransferSuggestionStore()
        let headphoneTransferSuggestionNotifier = HeadphoneTransferSuggestionNotifier()
        let headphoneTransferSuggestionPresenter = HeadphoneTransferSuggestionPresenter(
            store: headphoneTransferSuggestionStore,
            notifier: headphoneTransferSuggestionNotifier
        )
        let macAudioOutputMonitor = MacAudioOutputMonitor()
        let chromiumNativeMessagingHostInstaller = ChromiumNativeMessagingHostInstaller()
        let chromiumBrowserExtensionController = ChromiumBrowserExtensionController()
        let targetSelectionMemory = MediaTargetSelectionMemory()
        let mediaRemoteController = MediaRemoteController(
            chromiumBrowserExtensionController: chromiumBrowserExtensionController
        )
        let mediaSourceStore = MediaSourceStore(
            mediaRemoteController: mediaRemoteController,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController,
            targetsChanged: { targets, activeTargetID, rawTargetCount in
                ShortcutRuntimeStatus.shared.updateMediaTargets(
                    targets,
                    activeTargetID: activeTargetID,
                    rawTargetCount: rawTargetCount,
                    rawActiveTargetID: activeTargetID
                )
            }
        )
        let mediaAudioControlController = MediaAudioControlController(
            volumeService: spotifyConnectService,
            outputSelection: outputSelection,
            activePlaybackObserver: spotifyConnectService,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController,
            mediaSourceStore: mediaSourceStore
        )
        let mediaTargetOverlayController = MediaTargetOverlayController(
            audioController: mediaAudioControlController
        )
        let sourceFocusActionController = SourceFocusActionController(
            mediaRemoteController: mediaRemoteController,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController,
            targetSelectionMemory: targetSelectionMemory
        )
        let mediaTransportActionController = MediaTransportActionController(
            mediaRemoteController: mediaRemoteController,
            mediaSourceStore: mediaSourceStore,
            overlayController: mediaTargetOverlayController,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController,
            sourceFocusActionController: sourceFocusActionController,
            targetSelectionMemory: targetSelectionMemory
        )
        let mediaRoutingProbeController = MediaRoutingProbeController(
            mediaRemoteController: mediaRemoteController,
            mediaTransportActionController: mediaTransportActionController
        )
        let outputDirectory = PlaybackOutputDirectory(
            groupingStateReader: spotifyConnectService
        )
        let playbackBackgroundSync = PlaybackBackgroundSync(
            activePlaybackObserver: spotifyConnectService,
            roomHandoffService: spotifyConnectService,
            groupingEditor: spotifyConnectService,
            outputDirectory: outputDirectory,
            outputSelection: outputSelection,
            groupSuggestionStore: groupSuggestionStore,
            groupSuggestionPresenter: groupSuggestionPresenter,
            transferSuggestionStore: transferSuggestionStore,
            transferSuggestionPresenter: transferSuggestionPresenter,
            headphoneTransferSuggestionStore: headphoneTransferSuggestionStore,
            headphoneTransferSuggestionPresenter: headphoneTransferSuggestionPresenter,
            macAudioOutputMonitor: macAudioOutputMonitor
        )
        let playbackSyncController = PlaybackSyncController(
            outputDirectory: outputDirectory,
            outputSelection: outputSelection,
            activePlaybackObserver: spotifyConnectService,
            volumeService: spotifyConnectService,
            roomHandoffService: spotifyConnectService,
            groupingEditor: spotifyConnectService,
            groupSuggestionStore: groupSuggestionStore,
            groupSuggestionPresenter: groupSuggestionPresenter
        )
        let volumeHotkeys = VolumeHotkeyController(
            volumeService: spotifyConnectService,
            outputSelection: outputSelection,
            activePlaybackObserver: spotifyConnectService,
            mediaSourceStore: mediaSourceStore,
            mediaRemoteController: mediaRemoteController,
            mediaTransportActions: mediaTransportActionController
        )
        mediaTransportActionController.relaxRouteShield = { [weak volumeHotkeys] reason in
            volumeHotkeys?.suspendCommandCenterRouteShield(reason: reason)
        }

        return AppEnvironment(
            configImportService: configImportService,
            configStore: configStore,
            tokenStore: tokenStore,
            connectTokenStatusStore: connectTokenStatusStore,
            authCoordinator: authCoordinator,
            volumeService: spotifyConnectService,
            activePlaybackObserver: spotifyConnectService,
            outputSelection: outputSelection,
            outputDirectory: outputDirectory,
            playbackBackgroundSync: playbackBackgroundSync,
            playbackSyncController: playbackSyncController,
            chromiumNativeMessagingHostInstaller: chromiumNativeMessagingHostInstaller,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController,
            mediaRemoteController: mediaRemoteController,
            mediaSourceStore: mediaSourceStore,
            mediaAudioControlController: mediaAudioControlController,
            mediaTransportActionController: mediaTransportActionController,
            mediaRoutingProbeController: mediaRoutingProbeController,
            volumeHotkeys: volumeHotkeys
        )
    }
}

@MainActor
final class MediaRoutingProbeController {
    private static let environmentFlag = "KEYWAY_MEDIA_ROUTING_PROBE"
    private static let notificationObject = "com.fpieringer.Keyway"

    private let mediaRemoteController: MediaRemoteController
    private let mediaTransportActionController: MediaTransportActionController
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "MediaRoutingProbe")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var observer: NSObjectProtocol?

    init(
        mediaRemoteController: MediaRemoteController,
        mediaTransportActionController: MediaTransportActionController
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.mediaTransportActionController = mediaTransportActionController
    }

    func start() {
        guard ProcessInfo.processInfo.environment[Self.environmentFlag] == "1",
              observer == nil
        else {
            return
        }

        observer = DistributedNotificationCenter.default().addObserver(
            forName: .keywayMediaRoutingProbeRequest,
            object: Self.notificationObject,
            queue: .main
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? String else {
                self?.logger.error("Ignoring media routing probe request without string payload")
                return
            }
            Task { @MainActor [weak self] in
                self?.handle(payload)
            }
        }
    }

    func stop() {
        guard let observer else {
            return
        }
        DistributedNotificationCenter.default().removeObserver(observer)
        self.observer = nil
    }

    private func handle(_ payload: String) {
        let request: MediaRoutingProbeRequest
        do {
            request = try decoder.decode(
                MediaRoutingProbeRequest.self,
                from: Data(payload.utf8)
            )
        } catch {
            logger.error("Ignoring media routing probe decode failure error=\(error.localizedDescription, privacy: .public)")
            return
        }

        switch request.action {
        case .snapshot:
            publish(
                MediaRoutingProbeResponse(
                    requestID: request.requestID,
                    action: request.action,
                    ok: true,
                    message: "snapshot",
                    targetID: nil,
                    command: nil,
                    targets: mediaRemoteController.targets
                )
            )
        case .route:
            guard let targetID = request.targetID else {
                publish(
                    MediaRoutingProbeResponse(
                        requestID: request.requestID,
                        action: request.action,
                        ok: false,
                        message: "missing_target_id",
                        targetID: nil,
                        command: request.command,
                        targets: mediaRemoteController.targets
                    )
                )
                return
            }
            guard let command = request.command else {
                publish(
                    MediaRoutingProbeResponse(
                        requestID: request.requestID,
                        action: request.action,
                        ok: false,
                        message: "missing_command",
                        targetID: targetID,
                        command: nil,
                        targets: mediaRemoteController.targets
                    )
                )
                return
            }
            guard let target = mediaRemoteController.targets.first(where: { $0.id == targetID }) else {
                publish(
                    MediaRoutingProbeResponse(
                        requestID: request.requestID,
                        action: request.action,
                        ok: false,
                        message: "target_unavailable",
                        targetID: targetID,
                        command: command,
                        targets: mediaRemoteController.targets
                    )
                )
                return
            }

            mediaTransportActionController.route(command: command, to: target)
            publish(
                MediaRoutingProbeResponse(
                    requestID: request.requestID,
                    action: request.action,
                    ok: true,
                    message: "accepted",
                    targetID: targetID,
                    command: command,
                    targets: nil
                )
            )
        }
    }

    private func publish(_ response: MediaRoutingProbeResponse) {
        let data: Data
        do {
            data = try encoder.encode(response)
        } catch {
            logger.error("Dropping media routing probe response encode failure requestID=\(response.requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard let json = String(data: data, encoding: .utf8) else {
            logger.error("Dropping media routing probe response with non-UTF-8 JSON requestID=\(response.requestID, privacy: .public)")
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            .keywayMediaRoutingProbeResponse,
            object: Self.notificationObject,
            userInfo: ["payload": json],
            deliverImmediately: true
        )
    }
}

private enum MediaRoutingProbeAction: String, Codable {
    case snapshot
    case route
}

private struct MediaRoutingProbeRequest: Codable {
    let requestID: String
    let action: MediaRoutingProbeAction
    let targetID: String?
    let command: MediaRemoteTransportCommand?
}

private struct MediaRoutingProbeResponse: Codable {
    let requestID: String
    let action: MediaRoutingProbeAction
    let ok: Bool
    let message: String
    let targetID: String?
    let command: MediaRemoteTransportCommand?
    let targets: [MediaRemoteTarget]?
}
