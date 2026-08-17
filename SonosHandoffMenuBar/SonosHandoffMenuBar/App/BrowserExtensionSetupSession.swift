import Combine
import Foundation

struct ChromiumBrowserSetupBrowser: Equatable {
    let definition: ChromiumBrowserDefinition
    let applicationURL: URL
    let connectedProfileCount: Int
}

struct ChromiumBrowserSetupSnapshot: Equatable {
    let browsers: [ChromiumBrowserSetupBrowser]

    init(
        installedApplicationURLsByBundleIdentifier: [String: URL],
        profileConnections: [ChromiumBrowserProfileConnection]
    ) {
        let connectedProfileCounts = profileConnections.reduce(into: [String: Int]()) { counts, connection in
            counts[connection.browserBundleIdentifier, default: 0] += 1
        }
        browsers = ChromiumBrowserDefinition.supported.compactMap { definition in
            guard let applicationURL = installedApplicationURLsByBundleIdentifier[definition.bundleIdentifier] else {
                return nil
            }
            return ChromiumBrowserSetupBrowser(
                definition: definition,
                applicationURL: applicationURL,
                connectedProfileCount: connectedProfileCounts[definition.bundleIdentifier, default: 0]
            )
        }
    }
}

struct ChromiumBrowserDeveloperModeSetup: Equatable {
    let browser: ChromiumBrowserSetupBrowser
    let extensionDirectoryURL: URL
}

@MainActor
final class BrowserExtensionSetupSession: ObservableObject {
    @Published private(set) var snapshot: ChromiumBrowserSetupSnapshot
    @Published private(set) var developerModeSetup: ChromiumBrowserDeveloperModeSetup?
    @Published private(set) var actionMessage: String?

    private let installationAdapter: ChromiumBrowserInstallationAdapter
    private let extensionController: ChromiumBrowserExtensionController
    private var profileConnectionsCancellable: AnyCancellable?

    init(
        installationAdapter: ChromiumBrowserInstallationAdapter = ChromiumBrowserInstallationAdapter(),
        extensionController: ChromiumBrowserExtensionController
    ) {
        self.installationAdapter = installationAdapter
        self.extensionController = extensionController
        snapshot = ChromiumBrowserSetupSnapshot(
            installedApplicationURLsByBundleIdentifier: installationAdapter.installedApplicationURLsByBundleIdentifier(),
            profileConnections: extensionController.profileConnections
        )
        profileConnectionsCancellable = extensionController.$profileConnections
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] profileConnections in
                MainActor.assumeIsolated {
                    self?.refresh(profileConnections: profileConnections)
                }
            }
    }

    func refreshInstalledBrowsers() {
        refresh(profileConnections: extensionController.profileConnections)
    }

    func startDeveloperModeSetup(for browser: ChromiumBrowserSetupBrowser) {
        let extensionDirectoryURL = installationAdapter.prepareDeveloperModeSetup(for: browser)
        developerModeSetup = ChromiumBrowserDeveloperModeSetup(
            browser: browser,
            extensionDirectoryURL: extensionDirectoryURL
        )
        actionMessage = nil
    }

    func copyExtensionPath() {
        installationAdapter.copyExtensionPath(developerModeSetup!.extensionDirectoryURL)
        actionMessage = "Path copied."
    }

    func revealExtension() {
        installationAdapter.revealExtension(developerModeSetup!.extensionDirectoryURL)
    }

    func reopenExtensionsPage() {
        installationAdapter.openExtensionsPage(for: developerModeSetup!.browser)
    }

    private func refresh(profileConnections: [ChromiumBrowserProfileConnection]) {
        let nextSnapshot = ChromiumBrowserSetupSnapshot(
            installedApplicationURLsByBundleIdentifier: installationAdapter.installedApplicationURLsByBundleIdentifier(),
            profileConnections: profileConnections
        )
        if snapshot != nextSnapshot {
            if let connectedBrowser = nextSnapshot.browsers.first(where: { browser in
                let previousCount = snapshot.browsers.first {
                    $0.definition.bundleIdentifier == browser.definition.bundleIdentifier
                }?.connectedProfileCount ?? 0
                return browser.connectedProfileCount > previousCount
            }) {
                actionMessage = "\(connectedBrowser.definition.displayName) connected. Ready."
                if developerModeSetup?.browser.definition.bundleIdentifier == connectedBrowser.definition.bundleIdentifier {
                    developerModeSetup = nil
                }
            }
            snapshot = nextSnapshot
        }
    }
}
