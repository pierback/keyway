import Darwin
import Foundation
import XCTest
@testable import KeywayChromiumBridgeIPC

final class KeywayChromiumBridgeIPCTests: XCTestCase {
    func testAuthenticatedRoundTripAndPrivateEndpointPermissions() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let endpointURL = temporaryDirectory.appendingPathComponent("bridge.endpoint")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let eventReceived = expectation(description: "server received event")
        let commandReceived = expectation(description: "client received command")
        let eventCapture = LockedCapture<(KeywayChromiumBridgeEvent, String)>()
        let commandCapture = LockedCapture<String>()
        let validator = ChromiumBridgePeerValidator { peerIdentity in
            XCTAssertEqual(peerIdentity.processIdentifier, getpid())
            XCTAssertEqual(peerIdentity.auditToken.count, MemoryLayout<audit_token_t>.size)
        }

        let server = KeywayChromiumBridgeServer(
            endpointURL: endpointURL,
            peerValidator: validator,
            onEvent: { event, payload in
                eventCapture.set((event, payload))
                eventReceived.fulfill()
            }
        )
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: endpointURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))

        let client = KeywayChromiumBridgeClient(
            endpointURL: endpointURL,
            peerValidator: validator,
            onCommand: { payload in
                commandCapture.set(payload)
                commandReceived.fulfill()
            }
        )
        client.start()
        defer { client.stop() }

        client.publish(event: .snapshot, payload: #"{"type":"snapshot"}"#)
        wait(for: [eventReceived], timeout: 2)
        server.sendCommand(#"{"type":"command"}"#)
        wait(for: [commandReceived], timeout: 2)

        XCTAssertEqual(eventCapture.value?.0, .snapshot)
        XCTAssertEqual(eventCapture.value?.1, #"{"type":"snapshot"}"#)
        XCTAssertEqual(commandCapture.value, #"{"type":"command"}"#)
    }

    func testServerRejectsPeerWhenAuthenticationFails() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let endpointURL = temporaryDirectory.appendingPathComponent("bridge.sock")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let validationAttempted = expectation(description: "server validated peer")
        let eventReceived = expectation(description: "rejected client could not publish")
        eventReceived.isInverted = true
        let rejectingValidator = ChromiumBridgePeerValidator { _ in
            validationAttempted.fulfill()
            throw TestAuthenticationError.rejected
        }
        let acceptingValidator = ChromiumBridgePeerValidator { _ in }

        let server = KeywayChromiumBridgeServer(
            endpointURL: endpointURL,
            peerValidator: rejectingValidator,
            onEvent: { _, _ in eventReceived.fulfill() }
        )
        try server.start()
        defer { server.stop() }

        let client = KeywayChromiumBridgeClient(
            endpointURL: endpointURL,
            peerValidator: acceptingValidator,
            onCommand: { _ in }
        )
        client.start()
        defer { client.stop() }
        client.publish(event: .snapshot, payload: #"{"type":"snapshot"}"#)

        wait(for: [validationAttempted], timeout: 2)
        wait(for: [eventReceived], timeout: 0.2)
    }

    func testStartingServerTwiceDoesNotReplaceLiveEndpoint() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let endpointURL = temporaryDirectory.appendingPathComponent("bridge.sock")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let eventReceived = expectation(description: "original server remained available")
        let validator = ChromiumBridgePeerValidator { _ in }
        let server = KeywayChromiumBridgeServer(
            endpointURL: endpointURL,
            peerValidator: validator,
            onEvent: { _, _ in eventReceived.fulfill() }
        )
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try server.start()) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(EALREADY))
        }

        let client = KeywayChromiumBridgeClient(
            endpointURL: endpointURL,
            peerValidator: validator,
            onCommand: { _ in }
        )
        client.start()
        defer { client.stop() }
        client.publish(event: .snapshot, payload: #"{"type":"snapshot"}"#)
        wait(for: [eventReceived], timeout: 2)
    }
}

private enum TestAuthenticationError: Error {
    case rejected
}

private final class LockedCapture<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
