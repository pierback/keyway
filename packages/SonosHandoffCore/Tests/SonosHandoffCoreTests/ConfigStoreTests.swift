import Foundation
import Testing
@testable import SonosHandoffCore

struct ConfigStoreTests {
    @Test
    func loadReturnsDefaultWhenConfigIsMissing() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ConfigStore(configURL: temporaryDirectory.appendingPathComponent("config.json"))

        let config = try store.load()

        #expect(config == AppConfig())
    }

    @Test
    func saveCreatesParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configURL = root.appendingPathComponent("nested/config.json")
        let store = ConfigStore(configURL: configURL)
        let config = AppConfig(spotifyClientID: "client-id")

        try store.save(config)

        #expect(FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test
    func loadThrowsForMalformedConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configURL = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: configURL)

        let store = ConfigStore(configURL: configURL)

        #expect(throws: ConfigStoreError.self) {
            _ = try store.load()
        }
    }
}
