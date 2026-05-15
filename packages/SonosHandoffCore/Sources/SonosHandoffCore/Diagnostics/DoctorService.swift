import AppKit
import Foundation

public protocol DoctorPerforming: Sendable {
    func run() async throws -> DoctorReport
}

public struct DoctorService: DoctorPerforming, @unchecked Sendable {
    private let configStore: ConfigStoring
    private let connectTokenStatusStore: ConnectTokenStatusChecking
    private let accessibilityAutomator: AccessibilityAutomating
    private let appLocator: SpotifyAppLocator

    public init(
        configStore: ConfigStoring,
        connectTokenStatusStore: ConnectTokenStatusChecking = ConnectTokenStatusStore(),
        accessibilityAutomator: AccessibilityAutomating,
        appLocator: SpotifyAppLocator = SpotifyAppLocator()
    ) {
        self.configStore = configStore
        self.connectTokenStatusStore = connectTokenStatusStore
        self.accessibilityAutomator = accessibilityAutomator
        self.appLocator = appLocator
    }

    public func run() async throws -> DoctorReport {
        let config = try configStore.load()
        let connectTokenStatus = connectTokenStatusStore.status()
        let spotifyAppInstalled = appLocator.installedAppURL() != nil
        let spotifyAppRunning = appLocator.runningApplication() != nil
        let accessibilityGranted = accessibilityAutomator.checkAccessibilityPermission()
        let virtualDisplayConfigured = !(config.spotifyVirtualDisplayName?.isEmpty ?? true)
        let virtualDisplayAvailable = Self.virtualDisplayAvailable(named: config.spotifyVirtualDisplayName)

        return DoctorReport(
            spotifyAuthenticated: connectTokenStatus.isReadyForHandoff,
            spotifyDesktopTokenAvailable: connectTokenStatus.desktopTokenAvailable,
            spotifyWebAPITokenAvailable: connectTokenStatus.projectTokenAvailable,
            spotifyAppInstalled: spotifyAppInstalled,
            spotifyAppRunning: spotifyAppRunning,
            accessibilityGranted: accessibilityGranted,
            virtualDisplayConfigured: virtualDisplayConfigured,
            virtualDisplayAvailable: virtualDisplayAvailable,
            savedTargetsValid: !config.targets.isEmpty
        )
    }

    private static func virtualDisplayAvailable(named displayName: String?) -> Bool {
        guard let displayName, !displayName.isEmpty else {
            return true
        }

        return NSScreen.screens.contains {
            $0.localizedName.caseInsensitiveCompare(displayName) == .orderedSame
        }
    }
}
