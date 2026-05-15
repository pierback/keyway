import AppKit
import Foundation
@testable import SonosHandoffCore

// MARK: - Config

struct MockConfigStore: ConfigStoring {
    var config: AppConfig

    init(config: AppConfig = AppConfig()) {
        self.config = config
    }

    func load() throws -> AppConfig {
        config
    }

    func save(_ config: AppConfig) throws {}
}

// MARK: - Spotify API

final class MockSpotifyController: SpotifyControlling, @unchecked Sendable {
    private let playbackStates: [PlaybackState?]
    private var currentPlaybackIndex = 0
    var currentPlaybackCallCount = 0

    init(playback: PlaybackState?) {
        self.playbackStates = [playback]
    }

    init(playbackStates: [PlaybackState?]) {
        self.playbackStates = playbackStates
    }

    func currentPlayback() async throws -> PlaybackState? {
        currentPlaybackCallCount += 1
        guard !playbackStates.isEmpty else {
            return nil
        }

        let playback = playbackStates[min(currentPlaybackIndex, playbackStates.count - 1)]
        currentPlaybackIndex += 1
        return playback
    }
}

// MARK: - Tokens

struct MockTokenStore: TokenStoring {
    let token: String?

    func saveRefreshToken(_ token: String) throws {}

    func loadRefreshToken() throws -> String? {
        token
    }

    func deleteRefreshToken() throws {}
}

struct FailingSaveTokenStore: TokenStoring {
    func saveRefreshToken(_ token: String) throws {
        throw TokenStoreError.encodingFailed
    }

    func loadRefreshToken() throws -> String? {
        nil
    }

    func deleteRefreshToken() throws {}
}

struct MockConnectTokenStatusStore: ConnectTokenStatusChecking {
    let statusValue: ConnectTokenStatus

    init(desktopTokenAvailable: Bool, projectTokenAvailable: Bool) {
        self.statusValue = ConnectTokenStatus(
            desktopTokenAvailable: desktopTokenAvailable,
            projectTokenAvailable: projectTokenAvailable
        )
    }

    func status() -> ConnectTokenStatus {
        statusValue
    }

    func deleteProjectToken() throws {}
}

// MARK: - Accessibility

final class MockAccessibilityAutomator: AccessibilityAutomating, @unchecked Sendable {
    let permissionGranted: Bool
    var transferredTargetNames: [String] = []
    var preferredDisplayNames: [String?] = []
    var transferError: TransferErrorCode?

    init(permissionGranted: Bool = true) {
        self.permissionGranted = permissionGranted
    }

    func transferPlayback(toVisibleDeviceNamed name: String, preferredDisplayNamed displayName: String?) async throws {
        if let transferError {
            throw transferError
        }
        transferredTargetNames.append(name)
        preferredDisplayNames.append(displayName)
    }

    func checkAccessibilityPermission() -> Bool {
        permissionGranted
    }
}

struct MockSpotifyAppLocator: Sendable {
    let installed: Bool
    let running: Bool

    func asSpotifyAppLocator() -> SpotifyAppLocator {
        SpotifyAppLocator(
            installedURLProvider: { installed ? URL(fileURLWithPath: "/Applications/Spotify.app") : nil },
            runningApplicationProvider: {
                running ? NSRunningApplication.current : nil
            }
        )
    }
}
