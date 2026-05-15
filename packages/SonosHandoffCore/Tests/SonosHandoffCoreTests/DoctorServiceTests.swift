import Testing
@testable import SonosHandoffCore

struct DoctorServiceTests {
    @Test
    func doctorAggregatesDesktopSignals() async throws {
        let service = DoctorService(
            configStore: MockConfigStore(config: AppConfig(
                targets: [SavedTarget(alias: "office", spotifyDeviceName: "Office")],
                spotifyVirtualDisplayName: "Virtual 16:9"
            )),
            connectTokenStatusStore: MockConnectTokenStatusStore(
                desktopTokenAvailable: true,
                projectTokenAvailable: true
            ),
            accessibilityAutomator: MockAccessibilityAutomator(permissionGranted: true),
            appLocator: MockSpotifyAppLocator(installed: true, running: true).asSpotifyAppLocator()
        )

        let report = try await service.run()

        #expect(report.spotifyAuthenticated == true)
        #expect(report.spotifyDesktopTokenAvailable == true)
        #expect(report.spotifyWebAPITokenAvailable == true)
        #expect(report.spotifyAppInstalled == true)
        #expect(report.spotifyAppRunning == true)
        #expect(report.accessibilityGranted == true)
        #expect(report.virtualDisplayConfigured == true)
        #expect(report.savedTargetsValid == true)
    }

    @Test
    func doctorReportsMissingDesktopRequirements() async throws {
        let service = DoctorService(
            configStore: MockConfigStore(config: AppConfig()),
            connectTokenStatusStore: MockConnectTokenStatusStore(
                desktopTokenAvailable: false,
                projectTokenAvailable: false
            ),
            accessibilityAutomator: MockAccessibilityAutomator(permissionGranted: false),
            appLocator: MockSpotifyAppLocator(installed: false, running: false).asSpotifyAppLocator()
        )

        let report = try await service.run()

        #expect(report.spotifyAuthenticated == false)
        #expect(report.spotifyDesktopTokenAvailable == false)
        #expect(report.spotifyWebAPITokenAvailable == false)
        #expect(report.spotifyAppInstalled == false)
        #expect(report.spotifyAppRunning == false)
        #expect(report.accessibilityGranted == false)
        #expect(report.virtualDisplayConfigured == false)
        #expect(report.virtualDisplayAvailable == true)
        #expect(report.savedTargetsValid == false)
    }
}
