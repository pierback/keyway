import Foundation
import Testing
@testable import SonosHandoffCore

struct ProjectWebAPITokenStoreTests {
    @Test
    func saveLoadAndDeleteProjectToken() throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = ProjectWebAPITokenStore(applicationSupportDirectory: directory)
        try store.save(ProjectWebAPIToken(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: 123
        ))

        #expect(try store.load() == ProjectWebAPIToken(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            clientID: "client-id",
            expiresAt: 123
        ))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.tokenURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(store.hasCompleteToken())

        try store.delete()

        #expect(try store.load() == nil)
        #expect(!store.hasCompleteToken())
    }

    @Test
    func rejectsTokenWithoutClientID() throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"access_token":"access-token","refresh_token":"refresh-token","client_id":null}"#.utf8)
            .write(to: directory.appendingPathComponent("project-webapi-token.json"))

        let store = ProjectWebAPITokenStore(applicationSupportDirectory: directory)

        #expect(!store.hasCompleteToken())
    }

    private func temporaryApplicationSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-project-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
