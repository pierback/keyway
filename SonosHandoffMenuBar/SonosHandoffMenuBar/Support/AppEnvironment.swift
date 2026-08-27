import AppKit
import Darwin
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
        let mediaRemoteController = MediaRemoteController()
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
        let playbackOperationGate = PlaybackOperationGate()
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
            macAudioOutputMonitor: macAudioOutputMonitor,
            operationGate: playbackOperationGate
        )
        let playbackSyncController = PlaybackSyncController(
            outputDirectory: outputDirectory,
            outputSelection: outputSelection,
            activePlaybackObserver: spotifyConnectService,
            volumeService: spotifyConnectService,
            roomHandoffService: spotifyConnectService,
            groupingEditor: spotifyConnectService,
            groupSuggestionStore: groupSuggestionStore,
            groupSuggestionPresenter: groupSuggestionPresenter,
            operationGate: playbackOperationGate
        )
        let volumeHotkeys = VolumeHotkeyController(
            volumeService: spotifyConnectService,
            outputSelection: outputSelection,
            activePlaybackObserver: spotifyConnectService,
            mediaRemoteController: mediaRemoteController,
            mediaSourceStore: mediaSourceStore,
            mediaTransportActions: mediaTransportActionController
        )

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
    private static let environmentDirectory = "KEYWAY_MEDIA_ROUTING_PROBE_DIRECTORY"
    private static let requestPrefix = "request-"
    private static let responsePrefix = "response-"
    private static let maximumRequestBytes = 64 * 1024

    private let mediaRemoteController: MediaRemoteController
    private let mediaTransportActionController: MediaTransportActionController
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "MediaRoutingProbe")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var probeDirectoryURL: URL?
    private var pollTimer: Timer?

    init(
        mediaRemoteController: MediaRemoteController,
        mediaTransportActionController: MediaTransportActionController
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.mediaTransportActionController = mediaTransportActionController
    }

    func start() {
        guard pollTimer == nil,
              let directoryPath = ProcessInfo.processInfo.environment[Self.environmentDirectory],
              !directoryPath.isEmpty
        else {
            return
        }

        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard validateProbeDirectory(directoryURL) else {
            logger.error("Media routing probe directory must be an owner-only directory")
            return
        }

        probeDirectoryURL = directoryURL
        drainRequests()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drainRequests()
            }
        }
        pollTimer?.tolerance = 0.005
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        probeDirectoryURL = nil
    }

    private func validateProbeDirectory(_ directoryURL: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directoryURL.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == geteuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0
        else {
            return false
        }
        return true
    }

    private func drainRequests() {
        guard let probeDirectoryURL,
              let requestURLs = try? FileManager.default.contentsOfDirectory(
                  at: probeDirectoryURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else {
            return
        }

        for requestURL in requestURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileName = requestURL.lastPathComponent
            guard fileName.hasPrefix(Self.requestPrefix), fileName.hasSuffix(".json") else {
                continue
            }
            let requestIDStart = fileName.index(fileName.startIndex, offsetBy: Self.requestPrefix.count)
            let requestIDEnd = fileName.index(fileName.endIndex, offsetBy: -5)
            let requestID = String(fileName[requestIDStart..<requestIDEnd])
            guard let requestUUID = UUID(uuidString: requestID),
                  requestUUID.uuidString == requestID.uppercased()
            else {
                discardRequest(at: requestURL, reason: "invalid request filename")
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: requestURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == geteuid(),
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0,
                  let fileSize = attributes[.size] as? NSNumber,
                  fileSize.intValue <= Self.maximumRequestBytes,
                  let data = try? Data(contentsOf: requestURL)
            else {
                discardRequest(at: requestURL, reason: "unsafe request file")
                continue
            }

            do {
                try FileManager.default.removeItem(at: requestURL)
            } catch {
                logger.error("Ignoring media routing probe request that could not be claimed file=\(fileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                continue
            }
            handle(data, requestUUID: requestUUID)
        }
    }

    private func discardRequest(at requestURL: URL, reason: String) {
        do {
            try FileManager.default.removeItem(at: requestURL)
        } catch {
            logger.error("Could not discard media routing probe request file=\(requestURL.lastPathComponent, privacy: .public) reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ data: Data, requestUUID: UUID) {
        let request: MediaRoutingProbeRequest
        do {
            request = try decoder.decode(MediaRoutingProbeRequest.self, from: data)
        } catch {
            logger.error("Ignoring media routing probe decode failure error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard request.requestID.uppercased() == requestUUID.uuidString else {
            logger.error("Ignoring media routing probe request whose payload ID does not match its filename")
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
        guard let probeDirectoryURL,
              let requestUUID = UUID(uuidString: response.requestID)
        else {
            logger.error("Dropping media routing probe response with invalid request ID=\(response.requestID, privacy: .public)")
            return
        }

        let responseURL = probeDirectoryURL
            .appendingPathComponent("\(Self.responsePrefix)\(requestUUID.uuidString).json", isDirectory: false)
        let temporaryURL = probeDirectoryURL
            .appendingPathComponent(".response-\(UUID().uuidString).tmp", isDirectory: false)
        do {
            let data = try encoder.encode(response)
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            try FileManager.default.moveItem(at: temporaryURL, to: responseURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            logger.error("Dropping media routing probe response requestID=\(response.requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
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
