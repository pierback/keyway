public enum ChromiumBrowserSetupPolicy {
    public static let dataUseDisclosure = "Local only: Keyway reads media info, page titles/URLs, and playback state for browser controls. It does not send this data off your Mac."

    public static func setupActionTitle(hasConnectedProfile: Bool) -> String {
        hasConnectedProfile
            ? "Add Profile"
            : "Connect"
    }
}
