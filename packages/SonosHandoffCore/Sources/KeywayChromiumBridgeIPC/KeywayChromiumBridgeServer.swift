import Darwin
import Foundation

public final class KeywayChromiumBridgeServer: @unchecked Sendable {
    private let endpointURL: URL
    private let peerValidator: ChromiumBridgePeerValidator
    private let onEvent: @Sendable (KeywayChromiumBridgeEvent, String) -> Void
    private let acceptQueue = DispatchQueue(label: "com.fpieringer.Keyway.chromium-bridge-server.accept")
    private let lock = NSLock()
    private var isStarting = false
    private var listener: Int32?
    private var clients: [ObjectIdentifier: ChromiumBridgeSocketConnection] = [:]

    public convenience init(
        endpointURL: URL = KeywayChromiumBridgeEndpoint.url,
        onEvent: @escaping @Sendable (KeywayChromiumBridgeEvent, String) -> Void
    ) {
        self.init(
            endpointURL: endpointURL,
            peerValidator: .nativeHost,
            onEvent: onEvent
        )
    }

    init(
        endpointURL: URL,
        peerValidator: ChromiumBridgePeerValidator,
        onEvent: @escaping @Sendable (KeywayChromiumBridgeEvent, String) -> Void
    ) {
        self.endpointURL = endpointURL
        self.peerValidator = peerValidator
        self.onEvent = onEvent
    }

    public func start() throws {
        lock.lock()
        guard self.listener == nil, !isStarting else {
            lock.unlock()
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EALREADY),
                userInfo: [NSLocalizedDescriptionKey: "Keyway Chromium bridge server is already started"]
            )
        }
        isStarting = true
        lock.unlock()

        let listener: Int32
        do {
            listener = try ChromiumBridgeSocket.makeListener(at: endpointURL)
        } catch {
            lock.lock()
            isStarting = false
            lock.unlock()
            throw error
        }

        lock.lock()
        isStarting = false
        self.listener = listener
        lock.unlock()

        acceptQueue.async { [self] in
            acceptConnections(listener: listener)
        }
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        let connections = Array(clients.values)
        clients = [:]
        lock.unlock()

        connections.forEach { $0.invalidate() }
        if let listener {
            Darwin.shutdown(listener, SHUT_RDWR)
        }
        try? FileManager.default.removeItem(at: endpointURL)
    }

    public func sendCommand(_ payload: String) {
        lock.lock()
        let connections = Array(clients.values)
        lock.unlock()

        for connection in connections where !connection.send(.command(payload)) {
            remove(connection)
        }
    }

    private func acceptConnections(listener: Int32) {
        defer { Darwin.close(listener) }
        while isCurrentListener(listener) {
            let connection: ChromiumBridgeSocketConnection
            do {
                connection = try ChromiumBridgeSocket.accept(listener: listener)
            } catch {
                continue
            }

            do {
                try peerValidator.validate(peerIdentity: connection.peerIdentity)
            } catch {
                connection.invalidate()
                continue
            }

            lock.lock()
            guard self.listener == listener else {
                lock.unlock()
                connection.invalidate()
                continue
            }
            clients[ObjectIdentifier(connection)] = connection
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).async { [self, connection] in
                receiveEvents(from: connection)
            }
        }
    }

    private func receiveEvents(from connection: ChromiumBridgeSocketConnection) {
        while let envelope = connection.receive() {
            guard envelope.kind == .event, let event = envelope.event else {
                break
            }
            onEvent(event, envelope.payload)
        }
        remove(connection)
    }

    private func isCurrentListener(_ listener: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.listener == listener
    }

    private func remove(_ connection: ChromiumBridgeSocketConnection) {
        connection.invalidate()
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }
}
