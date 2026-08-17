import Foundation

struct ChromiumNativeMessagingHostInstallState: Equatable {
    let hostPath: String
    let manifestPaths: [String]
}

enum ChromiumNativeMessagingHostInstallError: LocalizedError, Equatable {
    case missingExecutable(path: String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            return "Bundled Chromium native host is missing or not executable at \(path)"
        }
    }
}

struct ChromiumNativeMessagingHostInstaller {
    private struct Manifest: Encodable {
        let name: String
        let description: String
        let path: String
        let type: String
        let allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case path
            case type
            case allowedOrigins = "allowed_origins"
        }
    }

    private let fileManager: FileManager
    private let appBundleURL: URL

    init(
        appBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.appBundleURL = appBundleURL
        self.fileManager = fileManager
    }

    var nativeHostExecutableURL: URL {
        appBundleURL.appendingPathComponent("Contents/Helpers/keyway-chromium-native-host")
    }

    func install() throws -> ChromiumNativeMessagingHostInstallState {
        guard fileManager.isExecutableFile(atPath: nativeHostExecutableURL.path) else {
            throw ChromiumNativeMessagingHostInstallError.missingExecutable(path: nativeHostExecutableURL.path)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Manifest(
            name: ChromiumBrowserExtensionTransport.nativeMessagingHostName,
            description: "Keyway Chromium media bridge",
            path: nativeHostExecutableURL.path,
            type: "stdio",
            allowedOrigins: ["chrome-extension://\(ChromiumBrowserExtensionTransport.extensionID)/"]
        ))

        let manifestPaths = nativeHostDirectories.map {
            $0.appendingPathComponent("\(ChromiumBrowserExtensionTransport.nativeMessagingHostName).json")
        }

        for manifestPath in manifestPaths {
            try fileManager.createDirectory(
                at: manifestPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: manifestPath, options: .atomic)
        }

        return ChromiumNativeMessagingHostInstallState(
            hostPath: nativeHostExecutableURL.path,
            manifestPaths: manifestPaths.map(\.path)
        )
    }

    private var nativeHostDirectories: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return ChromiumBrowserDefinition.supported.map {
            home.appendingPathComponent($0.nativeMessagingHostDirectory)
        }
    }
}
