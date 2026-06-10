import Foundation
import Testing
@testable import SonosHandoffCore

struct ConfigImportServiceTests {
    @Test
    func copiesLegacyFilesIntoKeywayDirectoryWithoutModifyingSource() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let keywayDirectory = root.appendingPathComponent("keyway", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let sourceURL = legacyDirectory.appendingPathComponent("config.json")
        let sourceData = Data(#"{"spotifyClientID":"legacy"}"#.utf8)
        try sourceData.write(to: sourceURL)

        let service = ConfigImportService(
            legacyApplicationSupportDirectory: legacyDirectory,
            applicationSupportDirectory: keywayDirectory,
            legacyTokenStore: MemoryTokenStore(refreshToken: nil),
            keywayTokenStore: MemoryTokenStore(refreshToken: nil)
        )

        let report = service.importLegacyState()

        #expect(report.fileResults.first { $0.file == .appConfig }?.status == .copied)
        #expect(try Data(contentsOf: sourceURL) == sourceData)
        #expect(try Data(contentsOf: keywayDirectory.appendingPathComponent("config.json")) == sourceData)
    }

    @Test
    func doesNotOverwriteDifferentExistingKeywayFile() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let keywayDirectory = root.appendingPathComponent("keyway", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keywayDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDirectory.appendingPathComponent("project-webapi-token.json"))
        let keywayURL = keywayDirectory.appendingPathComponent("project-webapi-token.json")
        let keywayData = Data("keyway".utf8)
        try keywayData.write(to: keywayURL)

        let service = ConfigImportService(
            legacyApplicationSupportDirectory: legacyDirectory,
            applicationSupportDirectory: keywayDirectory,
            legacyTokenStore: MemoryTokenStore(refreshToken: nil),
            keywayTokenStore: MemoryTokenStore(refreshToken: nil)
        )

        let report = service.importLegacyState()

        #expect(report.fileResults.first { $0.file == .projectWebAPIToken }?.status == .conflict)
        #expect(try Data(contentsOf: keywayURL) == keywayData)
    }

    @Test
    func importsTokenFilesWithSensitivePermissions() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let keywayDirectory = root.appendingPathComponent("keyway", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        for file in [ConfigImportFile.projectWebAPIToken, .spotifyDesktopConnectTokens] {
            let sourceURL = legacyDirectory.appendingPathComponent(file.fileName)
            try Data("token".utf8).write(to: sourceURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourceURL.path)
        }

        let service = ConfigImportService(
            legacyApplicationSupportDirectory: legacyDirectory,
            applicationSupportDirectory: keywayDirectory,
            legacyTokenStore: MemoryTokenStore(refreshToken: nil),
            keywayTokenStore: MemoryTokenStore(refreshToken: nil)
        )

        let report = service.importLegacyState()

        for file in [ConfigImportFile.projectWebAPIToken, .spotifyDesktopConnectTokens] {
            let destinationURL = keywayDirectory.appendingPathComponent(file.fileName)
            #expect(report.fileResults.first { $0.file == file }?.status == .copied)
            #expect(try Self.permissions(at: destinationURL) == 0o600)
        }
    }

    @Test
    func copiesLegacyKeychainTokenWhenKeywayTokenIsMissing() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let legacyTokenStore = MemoryTokenStore(refreshToken: "legacy-refresh-token")
        let keywayTokenStore = MemoryTokenStore(refreshToken: nil)

        let service = ConfigImportService(
            legacyApplicationSupportDirectory: root.appendingPathComponent("legacy", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("keyway", isDirectory: true),
            legacyTokenStore: legacyTokenStore,
            keywayTokenStore: keywayTokenStore
        )

        let report = service.importLegacyState()

        #expect(report.keychainStatus == .copied)
        #expect(try keywayTokenStore.loadRefreshToken() == "legacy-refresh-token")
        #expect(try legacyTokenStore.loadRefreshToken() == "legacy-refresh-token")
    }

    @Test
    func leavesExistingKeywayKeychainTokenUntouched() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let legacyTokenStore = MemoryTokenStore(refreshToken: "legacy-refresh-token")
        let keywayTokenStore = MemoryTokenStore(refreshToken: "keyway-refresh-token")

        let service = ConfigImportService(
            legacyApplicationSupportDirectory: root.appendingPathComponent("legacy", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("keyway", isDirectory: true),
            legacyTokenStore: legacyTokenStore,
            keywayTokenStore: keywayTokenStore
        )

        let report = service.importLegacyState()

        #expect(report.keychainStatus == .alreadyImported)
        #expect(try keywayTokenStore.loadRefreshToken() == "keyway-refresh-token")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyway-config-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func permissions(at url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int
    }
}

private final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshToken: String?

    init(refreshToken: String?) {
        self.refreshToken = refreshToken
    }

    func saveRefreshToken(_ token: String) throws {
        lock.lock()
        refreshToken = token
        lock.unlock()
    }

    func loadRefreshToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return refreshToken
    }

    func deleteRefreshToken() throws {
        lock.lock()
        refreshToken = nil
        lock.unlock()
    }
}
