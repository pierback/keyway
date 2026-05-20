import Foundation

public enum ConfigImportFile: String, CaseIterable, Sendable {
    case appConfig = "config.json"
    case projectWebAPIToken = "project-webapi-token.json"
    case spotifyDesktopConnectTokens = "spotify-desktop-connect-tokens.json"

    public var fileName: String {
        rawValue
    }
}

public enum ConfigImportFileStatus: Equatable, Sendable {
    case copied
    case missingLegacyFile
    case alreadyImported
    case conflict
    case failed(String)
}

public struct ConfigImportFileResult: Equatable, Sendable {
    public let file: ConfigImportFile
    public let sourceURL: URL
    public let destinationURL: URL
    public let status: ConfigImportFileStatus

    public init(
        file: ConfigImportFile,
        sourceURL: URL,
        destinationURL: URL,
        status: ConfigImportFileStatus
    ) {
        self.file = file
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.status = status
    }
}

public enum ConfigImportKeychainStatus: Equatable, Sendable {
    case copied
    case missingLegacyToken
    case alreadyImported
    case failed(String)
}

public struct ConfigImportReport: Equatable, Sendable {
    public let legacyApplicationSupportDirectory: URL
    public let applicationSupportDirectory: URL
    public let fileResults: [ConfigImportFileResult]
    public let keychainStatus: ConfigImportKeychainStatus

    public init(
        legacyApplicationSupportDirectory: URL,
        applicationSupportDirectory: URL,
        fileResults: [ConfigImportFileResult],
        keychainStatus: ConfigImportKeychainStatus
    ) {
        self.legacyApplicationSupportDirectory = legacyApplicationSupportDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.fileResults = fileResults
        self.keychainStatus = keychainStatus
    }

    public var copiedCount: Int {
        fileResults.filter { $0.status == .copied }.count
            + (keychainStatus == .copied ? 1 : 0)
    }

    public var hasFailures: Bool {
        fileResults.contains { result in
            if case .failed = result.status {
                return true
            }
            return false
        } || {
            if case .failed = keychainStatus {
                return true
            }
            return false
        }()
    }

    public var hasConflicts: Bool {
        fileResults.contains { $0.status == .conflict }
    }
}

public struct ConfigImportService: @unchecked Sendable {
    private let fileManager: FileManager
    private let legacyApplicationSupportDirectory: URL
    private let applicationSupportDirectory: URL
    private let legacyTokenStore: any TokenStoring
    private let keywayTokenStore: any TokenStoring

    public init(
        fileManager: FileManager = .default,
        legacyApplicationSupportDirectory: URL = ConfigPaths.legacyApplicationSupportDirectory,
        applicationSupportDirectory: URL = ConfigPaths.applicationSupportDirectory,
        legacyTokenStore: any TokenStoring = KeychainTokenStore(service: AppIdentity.legacySpotifyKeychainService),
        keywayTokenStore: any TokenStoring = KeychainTokenStore()
    ) {
        self.fileManager = fileManager
        self.legacyApplicationSupportDirectory = legacyApplicationSupportDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.legacyTokenStore = legacyTokenStore
        self.keywayTokenStore = keywayTokenStore
    }

    public func importLegacyState() -> ConfigImportReport {
        ConfigImportReport(
            legacyApplicationSupportDirectory: legacyApplicationSupportDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            fileResults: ConfigImportFile.allCases.map(importFile),
            keychainStatus: importKeychainRefreshToken()
        )
    }

    private func importFile(_ file: ConfigImportFile) -> ConfigImportFileResult {
        let sourceURL = legacyApplicationSupportDirectory.appendingPathComponent(file.fileName, isDirectory: false)
        let destinationURL = applicationSupportDirectory.appendingPathComponent(file.fileName, isDirectory: false)

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return ConfigImportFileResult(
                file: file,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                status: .missingLegacyFile
            )
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                let sourceData = try Data(contentsOf: sourceURL)
                let destinationData = try Data(contentsOf: destinationURL)
                return ConfigImportFileResult(
                    file: file,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    status: sourceData == destinationData ? .alreadyImported : .conflict
                )
            }

            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return ConfigImportFileResult(
                file: file,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                status: .copied
            )
        } catch {
            return ConfigImportFileResult(
                file: file,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                status: .failed(error.localizedDescription)
            )
        }
    }

    private func importKeychainRefreshToken() -> ConfigImportKeychainStatus {
        do {
            if try keywayTokenStore.loadRefreshToken() != nil {
                return .alreadyImported
            }

            guard let legacyRefreshToken = try legacyTokenStore.loadRefreshToken() else {
                return .missingLegacyToken
            }

            try keywayTokenStore.saveRefreshToken(legacyRefreshToken)
            return .copied
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
