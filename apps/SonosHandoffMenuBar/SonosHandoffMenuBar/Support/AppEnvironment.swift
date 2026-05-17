import SonosHandoffCore

struct AppEnvironment: @unchecked Sendable {
    let configStore: any ConfigStoring
    let tokenStore: any TokenStoring
    let connectTokenStatusStore: any ConnectTokenStatusChecking
    let authCoordinator: any SpotifyAuthCoordinating
    let handoffService: any HandoffPerforming
    let roomHandoffService: any RoomHandoffPerforming
    let speakerDiscovery: any SonosSpeakerDiscovering
    let groupingStateReader: any SonosGroupingStateReading
    let groupingEditor: any SonosGroupingEditing
    let volumeService: any SpeakerVolumeAdjusting
    let activePlaybackObserver: any SpotifyActivePlaybackObserving
    let doctorService: any DoctorPerforming
    let accessibilityAutomator: any AccessibilityAutomating
    let outputSelection: PlaybackOutputSelection
    let outputDirectory: PlaybackOutputDirectory
    let groupSuggestionStore: PlaybackGroupSuggestionStore
    let groupSuggestionNotifier: PlaybackGroupSuggestionNotifier

    @MainActor
    static func live() -> AppEnvironment {
        let configStore = ConfigStore()
        let tokenStore = KeychainTokenStore()
        let connectTokenStatusStore = ConnectTokenStatusStore()
        let authCoordinator = SpotifyAuthCoordinator(tokenStore: tokenStore, configStore: configStore)
        let accessibilityAutomator = SpotifyUIAutomator()
        let spotifyConnectService = SpotifyConnectHandoffService(configStore: configStore)
        let outputSelection = PlaybackOutputSelection()
        let groupSuggestionStore = PlaybackGroupSuggestionStore()
        let groupSuggestionNotifier = PlaybackGroupSuggestionNotifier()
        let outputDirectory = PlaybackOutputDirectory(
            groupingStateReader: spotifyConnectService,
            configStore: configStore
        )

        return AppEnvironment(
            configStore: configStore,
            tokenStore: tokenStore,
            connectTokenStatusStore: connectTokenStatusStore,
            authCoordinator: authCoordinator,
            handoffService: spotifyConnectService,
            roomHandoffService: spotifyConnectService,
            speakerDiscovery: spotifyConnectService,
            groupingStateReader: spotifyConnectService,
            groupingEditor: spotifyConnectService,
            volumeService: spotifyConnectService,
            activePlaybackObserver: spotifyConnectService,
            doctorService: DoctorService(
                configStore: configStore,
                connectTokenStatusStore: connectTokenStatusStore,
                accessibilityAutomator: accessibilityAutomator
            ),
            accessibilityAutomator: accessibilityAutomator,
            outputSelection: outputSelection,
            outputDirectory: outputDirectory,
            groupSuggestionStore: groupSuggestionStore,
            groupSuggestionNotifier: groupSuggestionNotifier
        )
    }
}
