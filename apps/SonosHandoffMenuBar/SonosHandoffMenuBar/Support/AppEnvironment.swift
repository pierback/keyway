import SonosHandoffCore

struct AppEnvironment: @unchecked Sendable {
    let configStore: any ConfigStoring
    let tokenStore: any TokenStoring
    let connectTokenStatusStore: any ConnectTokenStatusChecking
    let authCoordinator: any SpotifyAuthCoordinating
    let handoffService: any HandoffPerforming
    let roomHandoffService: any RoomHandoffPerforming
    let speakerDiscovery: any SonosSpeakerDiscovering
    let volumeService: any SpeakerVolumeAdjusting
    let doctorService: any DoctorPerforming
    let accessibilityAutomator: any AccessibilityAutomating

    static func live() -> AppEnvironment {
        let configStore = ConfigStore()
        let tokenStore = KeychainTokenStore()
        let connectTokenStatusStore = ConnectTokenStatusStore()
        let authCoordinator = SpotifyAuthCoordinator(tokenStore: tokenStore, configStore: configStore)
        let accessibilityAutomator = SpotifyUIAutomator()
        let spotifyConnectService = SpotifyConnectHandoffService(configStore: configStore)

        return AppEnvironment(
            configStore: configStore,
            tokenStore: tokenStore,
            connectTokenStatusStore: connectTokenStatusStore,
            authCoordinator: authCoordinator,
            handoffService: spotifyConnectService,
            roomHandoffService: spotifyConnectService,
            speakerDiscovery: spotifyConnectService,
            volumeService: spotifyConnectService,
            doctorService: DoctorService(
                configStore: configStore,
                connectTokenStatusStore: connectTokenStatusStore,
                accessibilityAutomator: accessibilityAutomator
            ),
            accessibilityAutomator: accessibilityAutomator
        )
    }
}
