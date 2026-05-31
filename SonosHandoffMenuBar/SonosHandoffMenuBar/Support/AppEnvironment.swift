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
    let mediaRemoteController: MediaRemoteController
    let mediaAudioControlController: MediaAudioControlController
    let mediaTargetOverlayController: MediaTargetOverlayController
    let mediaTransportActionController: MediaTransportActionController

    @MainActor
    static func live() -> AppEnvironment {
        let configImportService = ConfigImportService()
        let configStore = ConfigStore()
        let tokenStore = KeychainTokenStore()
        let connectTokenStatusStore = ConnectTokenStatusStore()
        let authCoordinator = SpotifyAuthCoordinator(tokenStore: tokenStore, configStore: configStore)
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
        let mediaRemoteController = MediaRemoteController()
        let mediaAudioControlController = MediaAudioControlController(
            volumeService: spotifyConnectService,
            outputSelection: outputSelection,
            activePlaybackObserver: spotifyConnectService
        )
        let mediaTargetOverlayController = MediaTargetOverlayController(
            audioController: mediaAudioControlController
        )
        let mediaTransportActionController = MediaTransportActionController(
            mediaRemoteController: mediaRemoteController,
            overlayController: mediaTargetOverlayController
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
            mediaRemoteController: mediaRemoteController,
            mediaAudioControlController: mediaAudioControlController,
            mediaTargetOverlayController: mediaTargetOverlayController,
            mediaTransportActionController: mediaTransportActionController
        )
    }
}
