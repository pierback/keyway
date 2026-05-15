import Foundation

public protocol HandoffPerforming: Sendable {
    func transfer(to alias: String) async -> TransferResult
}

public final class HandoffService: HandoffPerforming, @unchecked Sendable {
    private let configStore: ConfigStoring
    private let accessibilityAutomator: AccessibilityAutomating
    private let targetResolver: TargetResolver

    public init(
        configStore: ConfigStoring,
        spotifyController: SpotifyControlling,
        accessibilityAutomator: AccessibilityAutomating,
        targetResolver: TargetResolver = TargetResolver()
    ) {
        self.configStore = configStore
        self.accessibilityAutomator = accessibilityAutomator
        self.targetResolver = targetResolver
    }

    public func transfer(to alias: String) async -> TransferResult {
        let config: AppConfig

        do {
            config = try configStore.load()
        } catch {
            return .failure(code: .unsupported, message: "Unable to load saved targets: \(error.localizedDescription)")
        }

        guard let target = targetResolver.resolve(alias: alias, in: config) else {
            return .failure(code: .targetNotConfigured, message: "No saved target found for alias '\(alias)'.")
        }

        do {
            // Spotify Web API device discovery and playback verification are intentionally
            // not used here; they can trigger keychain/network waits and can omit Sonos.
            try await accessibilityAutomator.transferPlayback(
                toVisibleDeviceNamed: target.spotifyDeviceName,
                preferredDisplayNamed: config.spotifyVirtualDisplayName
            )
            return .success
        } catch let code as TransferErrorCode {
            return .failure(code: code, message: Self.message(for: code, targetName: target.spotifyDeviceName))
        } catch {
            return .failure(code: .unsupported, message: error.localizedDescription)
        }
    }

    private static func message(for code: TransferErrorCode, targetName: String) -> String {
        switch code {
        case .noActivePlayback:
            return "Spotify has no active playback session."
        case .targetNotConfigured:
            return "Target '\(targetName)' is not configured."
        case .targetNotVisible:
            return "Target '\(targetName)' is not visible."
        case .authRequired:
            return "Spotify authentication is required."
        case .transferVerificationFailed:
            return "Transfer could not be verified."
        case .spotifyAppNotInstalled, .spotifyAppNotRunning,
             .accessibilityNotGranted, .unsupported:
            return "Transfer unavailable."
        }
    }
}
