import AppKit

struct ChromiumBrowserDefinition: Equatable {
    let displayName: String
    let bundleIdentifier: String
    let nativeMessagingHostDirectory: String

    static let supported = [
        ChromiumBrowserDefinition(
            displayName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            nativeMessagingHostDirectory: "Library/Application Support/Arc/User Data/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            nativeMessagingHostDirectory: "Library/Application Support/Google/Chrome/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Google Chrome Canary",
            bundleIdentifier: "com.google.Chrome.canary",
            nativeMessagingHostDirectory: "Library/Application Support/Google/Chrome Canary/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Chromium",
            bundleIdentifier: "org.chromium.Chromium",
            nativeMessagingHostDirectory: "Library/Application Support/Chromium/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Brave",
            bundleIdentifier: "com.brave.Browser",
            nativeMessagingHostDirectory: "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Brave Beta",
            bundleIdentifier: "com.brave.Browser.beta",
            nativeMessagingHostDirectory: "Library/Application Support/BraveSoftware/Brave-Browser-Beta/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Brave Dev",
            bundleIdentifier: "com.brave.Browser.dev",
            nativeMessagingHostDirectory: "Library/Application Support/BraveSoftware/Brave-Browser-Dev/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Brave Nightly",
            bundleIdentifier: "com.brave.Browser.nightly",
            nativeMessagingHostDirectory: "Library/Application Support/BraveSoftware/Brave-Browser-Nightly/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Microsoft Edge",
            bundleIdentifier: "com.microsoft.edgemac",
            nativeMessagingHostDirectory: "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Microsoft Edge Beta",
            bundleIdentifier: "com.microsoft.edgemac.Beta",
            nativeMessagingHostDirectory: "Library/Application Support/Microsoft Edge Beta/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Microsoft Edge Dev",
            bundleIdentifier: "com.microsoft.edgemac.Dev",
            nativeMessagingHostDirectory: "Library/Application Support/Microsoft Edge Dev/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Microsoft Edge Canary",
            bundleIdentifier: "com.microsoft.edgemac.Canary",
            nativeMessagingHostDirectory: "Library/Application Support/Microsoft Edge Canary/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Vivaldi",
            bundleIdentifier: "com.vivaldi.Vivaldi",
            nativeMessagingHostDirectory: "Library/Application Support/Vivaldi/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Opera",
            bundleIdentifier: "com.operasoftware.Opera",
            nativeMessagingHostDirectory: "Library/Application Support/com.operasoftware.Opera/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Opera GX",
            bundleIdentifier: "com.operasoftware.OperaGX",
            nativeMessagingHostDirectory: "Library/Application Support/com.operasoftware.OperaGX/NativeMessagingHosts"
        ),
        ChromiumBrowserDefinition(
            displayName: "Helium",
            bundleIdentifier: "net.imput.helium",
            nativeMessagingHostDirectory: "Library/Application Support/net.imput.helium/NativeMessagingHosts"
        ),
    ]
}

@MainActor
struct ChromiumBrowserInstallationAdapter {
    static let extensionsPageURL = URL(string: "chrome://extensions")!

    private let fileManager: FileManager
    private let bundledExtensionURL: URL?
    private let managedExtensionURL: URL

    init(
        fileManager: FileManager = .default,
        bundledExtensionURL: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("ChromiumExtension", isDirectory: true),
        managedExtensionURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Keyway", isDirectory: true)
            .appendingPathComponent("ChromiumExtension", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.bundledExtensionURL = bundledExtensionURL
        self.managedExtensionURL = managedExtensionURL
    }

    func installedApplicationURLsByBundleIdentifier() -> [String: URL] {
        ChromiumBrowserDefinition.supported.reduce(into: [String: URL]()) { applications, definition in
            if let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: definition.bundleIdentifier
            ) {
                applications[definition.bundleIdentifier] = applicationURL
            }
        }
    }

    func prepareDeveloperModeSetup(for browser: ChromiumBrowserSetupBrowser) throws -> URL {
        let extensionURL = try prepareUnpackedExtension()
        copyExtensionPath(extensionURL)
        openExtensionsPage(for: browser)
        return extensionURL
    }

    func prepareUnpackedExtension() throws -> URL {
        guard let bundledExtensionURL else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: "ChromiumExtension/manifest.json"]
            )
        }
        let bundledManifestURL = bundledExtensionURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: bundledManifestURL.path) else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: bundledManifestURL.path]
            )
        }

        let parentURL = managedExtensionURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let stagingURL = parentURL.appendingPathComponent(
            ".ChromiumExtension-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.copyItem(at: bundledExtensionURL, to: stagingURL)
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        if fileManager.fileExists(atPath: managedExtensionURL.path) {
            _ = try fileManager.replaceItemAt(managedExtensionURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: managedExtensionURL)
        }
        return managedExtensionURL
    }

    func copyExtensionPath(_ extensionURL: URL) {
        NSPasteboard.general.clearContents()
        precondition(
            NSPasteboard.general.setString(extensionURL.path, forType: .string),
            "Failed to copy the Chromium extension path"
        )
    }

    func revealExtension(_ extensionURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([extensionURL])
    }

    func openExtensionsPage(for browser: ChromiumBrowserSetupBrowser) {
        NSWorkspace.shared.open(
            [Self.extensionsPageURL],
            withApplicationAt: browser.applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
