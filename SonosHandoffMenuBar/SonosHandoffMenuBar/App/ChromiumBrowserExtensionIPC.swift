import Foundation
import KeywayChromiumBridgeIPC

@MainActor
protocol ChromiumBrowserExtensionIPC: AnyObject {
    func start(
        onEvent: @escaping @MainActor @Sendable (KeywayChromiumBridgeEvent, String) -> Void,
        onConnectionClosed: @escaping @MainActor @Sendable (String?) -> Void
    ) throws
    func stop()
    func sendCommand(_ payload: String)
}

@MainActor
final class ChromiumBrowserExtensionIPCAdapter: ChromiumBrowserExtensionIPC {
    private var server: KeywayChromiumBridgeServer?

    func start(
        onEvent: @escaping @MainActor @Sendable (KeywayChromiumBridgeEvent, String) -> Void,
        onConnectionClosed: @escaping @MainActor @Sendable (String?) -> Void
    ) throws {
        precondition(server == nil, "Chromium browser extension IPC started twice")
        let server = KeywayChromiumBridgeServer(
            onEvent: { event, payload in
                DispatchQueue.main.async {
                    onEvent(event, payload)
                }
            },
            onConnectionClosed: { lastSnapshotPayload in
                DispatchQueue.main.async {
                    onConnectionClosed(lastSnapshotPayload)
                }
            }
        )
        try server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func sendCommand(_ payload: String) {
        server?.sendCommand(payload)
    }
}
