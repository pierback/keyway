import Foundation
import Testing
@testable import SonosHandoffCore

struct ConnectTokenStatusStoreTests {
    @Test
    func statusRejectsStaleProjectTokenWithoutClientID() throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try Data(#"{"access_token":"access-token","refresh_token":"refresh-token","client_id":null}"#.utf8)
            .write(to: directory.appendingPathComponent("project-webapi-token.json"))

        let status = ConnectTokenStatusStore(applicationSupportDirectory: directory).status()

        #expect(status.projectTokenAvailable == false)
    }

    @Test
    func statusAcceptsCompleteProjectToken() throws {
        let directory = try temporaryApplicationSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try Data(#"{"access_token":"access-token","refresh_token":"refresh-token","client_id":"client-id"}"#.utf8)
            .write(to: directory.appendingPathComponent("project-webapi-token.json"))

        let status = ConnectTokenStatusStore(applicationSupportDirectory: directory).status()

        #expect(status.projectTokenAvailable == true)
    }

    private func temporaryApplicationSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonos-handoff-token-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
