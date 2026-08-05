import Darwin
import Foundation
import KeywayChromiumBridgeIPC

let chromiumTargetIDPrefix = "chromium-tab:"
let hostBrowserIdentity = HostBrowserIdentity.current()
let connectionID = UUID().uuidString.lowercased()
let connectionGeneration = mach_continuous_time()
let hostConnectionState = HostConnectionState()

let bridge = KeywayChromiumBridgeClient { payload in
    guard let routedPayload = payloadByMatchingConnectionID(payload) else {
        return
    }
    writeNativeMessage(routedPayload)
}
bridge.start()

func postNativeMessage(_ payload: Data) {
    guard let envelope = try? JSONDecoder().decode(NativeMessageEnvelope.self, from: payload) else {
        fputs("Keyway Chromium native host: ignoring undecodable native message envelope.\n", stderr)
        return
    }
    guard envelope.type == "snapshot" || envelope.type == "hello" || envelope.type == "keepalive" || envelope.type == "commandResult" || envelope.type == "focusResult" else {
        fputs("Keyway Chromium native host: ignoring unknown native message type.\n", stderr)
        return
    }
    if envelope.type == "keepalive" {
        return
    }
    if envelope.type == "hello" {
        guard let postedPayload = payloadStringForHello(payload) else {
            return
        }
        bridge.publish(event: .snapshot, payload: postedPayload)
        return
    }
    let postedPayload = envelope.type == "snapshot"
        ? payloadByAddingHostBrowserIdentity(payload)
        : payloadStringForResult(payload)
    guard let postedPayload else {
        return
    }
    let event: KeywayChromiumBridgeEvent = envelope.type == "snapshot"
        ? .snapshot
        : envelope.type == "commandResult" ? .commandResult : .focusResult
    bridge.publish(event: event, payload: postedPayload)
}

while let payload = readNativeMessage() {
    postNativeMessage(payload)
}
bridge.stop()
