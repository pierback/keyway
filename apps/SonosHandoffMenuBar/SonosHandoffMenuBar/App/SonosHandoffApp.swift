import SwiftUI

@main
struct SonosHandoffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment: AppEnvironment

    init() {
        let environment = AppEnvironment.live()
        self.environment = environment
        SonosVolumeMonitor.shared.start(
            configStore: environment.configStore,
            volumeService: environment.volumeService
        )
    }

    var body: some Scene {
        MenuBarExtra("Sonos", systemImage: "hifispeaker") {
            MenuBarController(environment: environment)
        }
        .menuBarExtraStyle(.window)

        Window(SettingsFeature.menuTitle, id: MenuBarController.settingsWindowID) {
            SettingsFeature(
                configStore: environment.configStore,
                tokenStore: environment.tokenStore,
                connectTokenStatusStore: environment.connectTokenStatusStore,
                authCoordinator: environment.authCoordinator,
                accessibilityAutomator: environment.accessibilityAutomator
            )
                .frame(width: 560, height: 420)
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentSize)
    }
}
