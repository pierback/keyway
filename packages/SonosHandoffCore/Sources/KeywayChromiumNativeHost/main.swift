import AppKit
import Darwin
import Foundation

let snapshotNotificationName = Notification.Name("com.fpieringer.keyway.chromium.snapshot")
let commandResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.commandResult")
let focusResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.focusResult")
let commandNotificationName = Notification.Name("com.fpieringer.keyway.chromium.command")
let hostName = "com.fpieringer.keyway.chromium"
let chromiumTargetIDPrefix = "chromium-tab:"
let hostBrowserIdentity = HostBrowserIdentity.current()
let connectionID = UUID().uuidString.lowercased()
let connectionGeneration = mach_continuous_time()
let hostConnectionState = HostConnectionState()

let commandObserver = DistributedNotificationCenter.default().addObserver(
    forName: commandNotificationName,
    object: hostName,
    queue: .main
) { notification in
    guard let payload = notification.userInfo?["payload"] as? String else {
        fputs("Keyway Chromium native host: ignoring command notification without payload.\n", stderr)
        return
    }
    guard let routedPayload = payloadByMatchingConnectionID(payload) else {
        return
    }
    writeNativeMessage(routedPayload)
}

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
        DistributedNotificationCenter.default().postNotificationName(
            snapshotNotificationName,
            object: hostName,
            userInfo: ["payload": postedPayload],
            deliverImmediately: true
        )
        return
    }
    let postedPayload = envelope.type == "snapshot"
        ? payloadByAddingHostBrowserIdentity(payload)
        : payloadStringForResult(payload)
    guard let postedPayload else {
        return
    }
    DistributedNotificationCenter.default().postNotificationName(
        envelope.type == "snapshot" ? snapshotNotificationName : envelope.type == "commandResult" ? commandResultNotificationName : focusResultNotificationName,
        object: hostName,
        userInfo: ["payload": postedPayload],
        deliverImmediately: true
    )
}

DispatchQueue.global(qos: .userInitiated).async {
    while let payload = readNativeMessage() {
        postNativeMessage(payload)
    }
    exit(0)
}

RunLoop.main.run()
DistributedNotificationCenter.default().removeObserver(commandObserver)
