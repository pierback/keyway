import Foundation

public struct DoctorReport: Equatable, Sendable {
    public let spotifyAuthenticated: Bool
    public let spotifyDesktopTokenAvailable: Bool
    public let spotifyWebAPITokenAvailable: Bool
    public let spotifyAppInstalled: Bool
    public let spotifyAppRunning: Bool
    public let accessibilityGranted: Bool
    public let virtualDisplayConfigured: Bool
    public let virtualDisplayAvailable: Bool
    public let savedTargetsValid: Bool

    public init(
        spotifyAuthenticated: Bool,
        spotifyDesktopTokenAvailable: Bool,
        spotifyWebAPITokenAvailable: Bool,
        spotifyAppInstalled: Bool,
        spotifyAppRunning: Bool,
        accessibilityGranted: Bool,
        virtualDisplayConfigured: Bool,
        virtualDisplayAvailable: Bool,
        savedTargetsValid: Bool
    ) {
        self.spotifyAuthenticated = spotifyAuthenticated
        self.spotifyDesktopTokenAvailable = spotifyDesktopTokenAvailable
        self.spotifyWebAPITokenAvailable = spotifyWebAPITokenAvailable
        self.spotifyAppInstalled = spotifyAppInstalled
        self.spotifyAppRunning = spotifyAppRunning
        self.accessibilityGranted = accessibilityGranted
        self.virtualDisplayConfigured = virtualDisplayConfigured
        self.virtualDisplayAvailable = virtualDisplayAvailable
        self.savedTargetsValid = savedTargetsValid
    }
}
