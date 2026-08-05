import Foundation

public final class KeywayChromiumBridgeClient: @unchecked Sendable {
    private let endpointURL: URL
    private let peerValidator: ChromiumBridgePeerValidator
    private let onCommand: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.fpieringer.Keyway.chromium-bridge-client")
    private var running = false
    private var connection: ChromiumBridgeSocketConnection?
    private var pendingEvents: [(KeywayChromiumBridgeEvent, String)] = []
    private var retryWorkItem: DispatchWorkItem?

    public convenience init(
        endpointURL: URL = KeywayChromiumBridgeEndpoint.url,
        onCommand: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            endpointURL: endpointURL,
            peerValidator: .keywayApp,
            onCommand: onCommand
        )
    }

    init(
        endpointURL: URL,
        peerValidator: ChromiumBridgePeerValidator,
        onCommand: @escaping @Sendable (String) -> Void
    ) {
        self.endpointURL = endpointURL
        self.peerValidator = peerValidator
        self.onCommand = onCommand
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    public func stop() {
        queue.sync { [self] in
            running = false
            retryWorkItem?.cancel()
            retryWorkItem = nil
            connection?.invalidate()
            connection = nil
            pendingEvents = []
        }
    }

    public func publish(event: KeywayChromiumBridgeEvent, payload: String) {
        queue.async { [self] in
            guard running else { return }
            guard let connection else {
                enqueue(event: event, payload: payload)
                return
            }
            guard connection.send(.event(event, payload: payload)) else {
                enqueue(event: event, payload: payload)
                connectionFailed(connection)
                return
            }
        }
    }

    private func connect() {
        guard running, connection == nil else { return }
        let connection: ChromiumBridgeSocketConnection
        do {
            connection = try ChromiumBridgeSocket.connect(to: endpointURL)
            try peerValidator.validate(peerIdentity: connection.peerIdentity)
        } catch {
            scheduleRetry()
            return
        }

        self.connection = connection
        DispatchQueue.global(qos: .userInitiated).async { [self, connection] in
            receiveCommands(from: connection)
        }
        flushPendingEvents(over: connection)
    }

    private func receiveCommands(from connection: ChromiumBridgeSocketConnection) {
        while let envelope = connection.receive() {
            guard envelope.kind == .command, envelope.event == nil else {
                break
            }
            onCommand(envelope.payload)
        }
        queue.async { [self, connection] in
            connectionFailed(connection)
        }
    }

    private func flushPendingEvents(over connection: ChromiumBridgeSocketConnection) {
        let events = pendingEvents
        pendingEvents = []
        for (index, pendingEvent) in events.enumerated() {
            guard connection.send(.event(pendingEvent.0, payload: pendingEvent.1)) else {
                for unsentEvent in events[index...] {
                    enqueue(event: unsentEvent.0, payload: unsentEvent.1)
                }
                connectionFailed(connection)
                return
            }
        }
    }

    private func enqueue(event: KeywayChromiumBridgeEvent, payload: String) {
        if pendingEvents.count == 64 {
            pendingEvents.removeFirst()
        }
        pendingEvents.append((event, payload))
    }

    private func connectionFailed(_ failedConnection: ChromiumBridgeSocketConnection) {
        guard connection === failedConnection else { return }
        connection = nil
        failedConnection.invalidate()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard running, retryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            retryWorkItem = nil
            connect()
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 1, execute: workItem)
    }
}
