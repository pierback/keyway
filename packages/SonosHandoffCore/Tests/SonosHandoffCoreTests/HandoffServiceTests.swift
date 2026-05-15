import Foundation
import Testing
@testable import SonosHandoffCore

struct HandoffServiceTests {
    @Test
    func returnsTargetNotConfiguredForUnknownAlias() async {
        let service = HandoffService(
            configStore: MockConfigStore(config: AppConfig()),
            spotifyController: MockSpotifyController(
                playback: PlaybackState(isPlaying: true, deviceID: "mac", deviceName: "Mac")
            ),
            accessibilityAutomator: MockAccessibilityAutomator()
        )

        let result = await service.transfer(to: "office")

        #expect(result == .failure(code: .targetNotConfigured, message: "No saved target found for alias 'office'."))
    }

    @Test
    func usesSpotifyDesktopAutomationForTransfer() async {
        let accessibilityAutomator = MockAccessibilityAutomator()
        let spotify = MockSpotifyController(playback: nil)
        let service = HandoffService(
            configStore: MockConfigStore(config: AppConfig(targets: [SavedTarget(alias: "office", spotifyDeviceName: "Office")])),
            spotifyController: spotify,
            accessibilityAutomator: accessibilityAutomator
        )

        let result = await service.transfer(to: "office")

        #expect(result == .success)
        #expect(accessibilityAutomator.transferredTargetNames == ["Office"])
        #expect(spotify.currentPlaybackCallCount == 0)
    }

    @Test
    func passesPreferredDisplayToSpotifyDesktopAutomation() async {
        let accessibilityAutomator = MockAccessibilityAutomator()
        let service = HandoffService(
            configStore: MockConfigStore(config: AppConfig(
                targets: [SavedTarget(alias: "office", spotifyDeviceName: "Office")],
                spotifyVirtualDisplayName: "Virtual 16:9"
            )),
            spotifyController: MockSpotifyController(playback: nil),
            accessibilityAutomator: accessibilityAutomator
        )

        let result = await service.transfer(to: "office")

        #expect(result == .success)
        #expect(accessibilityAutomator.transferredTargetNames == ["Office"])
        #expect(accessibilityAutomator.preferredDisplayNames == ["Virtual 16:9"])
    }

    @Test
    func doesNotRequireSpotifyAPIPlaybackState() async {
        let service = HandoffService(
            configStore: MockConfigStore(config: AppConfig(targets: [SavedTarget(alias: "office", spotifyDeviceName: "Office")])),
            spotifyController: MockSpotifyController(playback: nil),
            accessibilityAutomator: MockAccessibilityAutomator()
        )

        let result = await service.transfer(to: "office")

        #expect(result == .success)
    }

    @Test
    func returnsTransferCodeFromDesktopAutomation() async {
        let accessibilityAutomator = MockAccessibilityAutomator()
        accessibilityAutomator.transferError = .accessibilityNotGranted

        let service = HandoffService(
            configStore: MockConfigStore(config: AppConfig(targets: [SavedTarget(alias: "office", spotifyDeviceName: "Office")])),
            spotifyController: MockSpotifyController(
                playback: PlaybackState(isPlaying: true, deviceID: "mac", deviceName: "Mac")
            ),
            accessibilityAutomator: accessibilityAutomator
        )

        let result = await service.transfer(to: "office")

        #expect(result == .failure(code: .accessibilityNotGranted, message: "Transfer unavailable."))
    }

    @Test
    func returnsSuccessWhenDesktopAutomationCompletesWithoutAPIVerification() async {
        let accessibilityAutomator = MockAccessibilityAutomator()
        let service = HandoffService(
            configStore: MockConfigStore(config: AppConfig(targets: [SavedTarget(alias: "port", spotifyDeviceName: "Port")])),
            spotifyController: MockSpotifyController(playback: nil),
            accessibilityAutomator: accessibilityAutomator
        )

        let result = await service.transfer(to: "port")

        #expect(result == .success)
    }
}
