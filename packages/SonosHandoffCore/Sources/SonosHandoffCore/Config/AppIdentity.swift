import Foundation

public enum AppIdentity {
    public static let productName = "Keyway"
    public static let bundleIdentifier = "com.fpieringer.Keyway"
    public static let applicationSupportDirectoryName = "keyway"
    public static let legacyApplicationSupportDirectoryName = "sonos-handoff"
    public static let spotifyKeychainService = "keyway.spotify"
    public static let legacySpotifyKeychainService = "sonos-handoff.spotify"
    public static let spotifyRefreshTokenAccount = "refresh-token"
    public static let loggerSubsystem = bundleIdentifier
}
