import AppKit
import SonosHandoffCore

struct AppEnvironment: @unchecked Sendable {
    let configImportService: ConfigImportService
    let configImportReport: ConfigImportReport?
    let configStore: any ConfigStoring
    let tokenStore: any TokenStoring
    let connectTokenStatusStore: any ConnectTokenStatusChecking
    let authCoordinator: any SpotifyAuthCoordinating
    let roomHandoffService: any RoomHandoffPerforming
    let groupingStateReader: any SonosGroupingStateReading
    let groupingEditor: any SonosGroupingEditing
    let volumeService: any SpeakerVolumeAdjusting
    let activePlaybackObserver: any SpotifyActivePlaybackObserving
    let accessibilityAutomator: any AccessibilityAutomating
    let outputSelection: PlaybackOutputSelection
    let outputDirectory: PlaybackOutputDirectory
    let groupSuggestionStore: PlaybackGroupSuggestionStore
    let groupSuggestionNotifier: PlaybackGroupSuggestionNotifier
    let groupSuggestionPresenter: PlaybackGroupSuggestionPresenter
    let transferSuggestionStore: PlaybackTransferSuggestionStore
    let transferSuggestionNotifier: PlaybackTransferSuggestionNotifier
    let transferSuggestionPresenter: PlaybackTransferSuggestionPresenter
    let chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller
    let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    let mediaRemoteController: MediaRemoteController
    let mediaAudioControlController: MediaAudioControlController
    let mediaTargetOverlayController: MediaTargetOverlayController
    let mediaTransportActionController: MediaTransportActionController
    let mediaRoutingProbeController: MediaRoutingProbeController

    @MainActor
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
        let accessibilityAutomator = SpotifyUIAutomator()
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
        let chromiumNativeMessagingHostInstaller = ChromiumNativeMessagingHostInstaller()
        _ = try! chromiumNativeMessagingHostInstaller.install()
        let chromiumBrowserExtensionController = ChromiumBrowserExtensionController()
        let mediaRemoteController = MediaRemoteController(
            chromiumBrowserExtensionController: chromiumBrowserExtensionController
        )
        let mediaAudioControlController = MediaAudioControlController(
            volumeService: spotifyConnectService,
            outputSelection: outputSelection,
            activePlaybackObserver: spotifyConnectService,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController
        )
        let mediaTargetOverlayController = MediaTargetOverlayController(
            audioController: mediaAudioControlController
        )
        let mediaTransportActionController = MediaTransportActionController(
            mediaRemoteController: mediaRemoteController,
            overlayController: mediaTargetOverlayController,
            spotifyPlaybackController: spotifyConnectService,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController
        )
        let mediaRoutingProbeController = MediaRoutingProbeController(
            mediaRemoteController: mediaRemoteController,
            mediaTransportActionController: mediaTransportActionController
        )
        let outputDirectory = PlaybackOutputDirectory(
            groupingStateReader: spotifyConnectService
        )

        return AppEnvironment(
            configImportService: configImportService,
            configImportReport: nil,
            configStore: configStore,
            tokenStore: tokenStore,
            connectTokenStatusStore: connectTokenStatusStore,
            authCoordinator: authCoordinator,
            roomHandoffService: spotifyConnectService,
            groupingStateReader: spotifyConnectService,
            groupingEditor: spotifyConnectService,
            volumeService: spotifyConnectService,
            activePlaybackObserver: spotifyConnectService,
            accessibilityAutomator: accessibilityAutomator,
            outputSelection: outputSelection,
            outputDirectory: outputDirectory,
            groupSuggestionStore: groupSuggestionStore,
            groupSuggestionNotifier: groupSuggestionNotifier,
            groupSuggestionPresenter: groupSuggestionPresenter,
            transferSuggestionStore: transferSuggestionStore,
            transferSuggestionNotifier: transferSuggestionNotifier,
            transferSuggestionPresenter: transferSuggestionPresenter,
            chromiumNativeMessagingHostInstaller: chromiumNativeMessagingHostInstaller,
            chromiumBrowserExtensionController: chromiumBrowserExtensionController,
            mediaRemoteController: mediaRemoteController,
            mediaAudioControlController: mediaAudioControlController,
            mediaTargetOverlayController: mediaTargetOverlayController,
            mediaTransportActionController: mediaTransportActionController,
            mediaRoutingProbeController: mediaRoutingProbeController
        )
    }
}

@MainActor
final class MediaRoutingProbeController {
    private static let environmentFlag = "KEYWAY_MEDIA_ROUTING_PROBE"
    private static let notificationObject = "com.fpieringer.Keyway"

    private let mediaRemoteController: MediaRemoteController
    private let mediaTransportActionController: MediaTransportActionController
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
            let payload = notification.userInfo!["payload"] as! String
            Task { @MainActor [weak self] in
                self?.handle(payload)
            }
        }
    }

    private func handle(_ payload: String) {
        let request = try! decoder.decode(
            MediaRoutingProbeRequest.self,
            from: Data(payload.utf8)
        )

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
            let targetID = request.targetID!
            let command = request.command!
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
        let data = try! encoder.encode(response)
        let json = String(data: data, encoding: .utf8)!
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
