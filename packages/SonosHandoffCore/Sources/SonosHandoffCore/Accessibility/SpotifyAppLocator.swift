import AppKit
import Foundation

public struct SpotifyAppLocator {
    private let installedURLProvider: () -> URL?
    private let runningApplicationProvider: () -> NSRunningApplication?

    public init(
        installedURLProvider: @escaping () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
        },
        runningApplicationProvider: @escaping () -> NSRunningApplication? = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first
        }
    ) {
        self.installedURLProvider = installedURLProvider
        self.runningApplicationProvider = runningApplicationProvider
    }

    public func installedAppURL() -> URL? {
        installedURLProvider()
    }

    public func runningApplication() -> NSRunningApplication? {
        runningApplicationProvider()
    }
}
