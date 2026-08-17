public enum ChromiumBrowserSetupPolicy {
    public static let dataUseDisclosure = "After you add the extension, Keyway reads media metadata, page titles and URLs, and playback state only to display and control browser media in the local Keyway app. Keyway does not send this data off your Mac. Choose an Install button below only if you agree to this local data use."

    public static func consentActionTitle(
        browserDisplayName: String,
        hasConnectedProfile: Bool
    ) -> String {
        hasConnectedProfile
            ? "Install in another \(browserDisplayName) profile"
            : "Install in \(browserDisplayName)"
    }
}
