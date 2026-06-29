import AppKit
import Darwin
import Foundation

let snapshotNotificationName = Notification.Name("com.fpieringer.keyway.chromium.snapshot")
let commandResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.commandResult")
let focusResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.focusResult")
let commandNotificationName = Notification.Name("com.fpieringer.keyway.chromium.command")
let hostName = "com.fpieringer.keyway.chromium"
let chromiumTargetIDPrefix = "chromium-extension:"
let writeLock = NSLock()
let hostBrowserIdentity = HostBrowserIdentity.current()

struct NativeMessageEnvelope: Decodable {
    let type: String
}

struct HostBrowserIdentity {
    let family: String
    let displayName: String
    let bundleIdentifier: String
    let instanceID: String

    var publicTargetIDPrefix: String {
        "\(chromiumTargetIDPrefix)\(family):\(instanceID):"
    }

    static func current() -> HostBrowserIdentity {
        let parentPID = getppid()
        guard let app = NSRunningApplication(processIdentifier: pid_t(parentPID)) else {
            preconditionFailure("Chromium native host could not resolve parent browser process \(parentPID).")
        }
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? ""
        guard let family = browserFamily(bundleIdentifier: bundleIdentifier, displayName: appName) else {
            preconditionFailure("Chromium native host parent is not a supported browser: \(bundleIdentifier) \(appName)")
        }

        return HostBrowserIdentity(
            family: family,
            displayName: appName.isEmpty ? displayName(family: family) : appName,
            bundleIdentifier: bundleIdentifier,
            instanceID: UUID().uuidString.lowercased()
        )
    }

    private static func browserFamily(bundleIdentifier: String, displayName: String) -> String? {
        let identities = [bundleIdentifier, displayName].map { $0.lowercased() }
        if identities.contains(where: { $0.contains("helium") }) {
            return "helium"
        }
        if identities.contains(where: { $0.contains("thebrowser") || $0.contains("arc") }) {
            return "arc"
        }
        if identities.contains(where: { $0.contains("brave") }) {
            return "brave"
        }
        if identities.contains(where: { $0.contains("edgemac") || $0.contains("microsoft edge") }) {
            return "edge"
        }
        if identities.contains(where: { $0.contains("opera") }) {
            return "opera"
        }
        if identities.contains(where: { $0.contains("vivaldi") }) {
            return "vivaldi"
        }
        if identities.contains(where: { $0.contains("chromium") }) {
            return "chromium"
        }
        if identities.contains(where: { $0.contains("chrome") || $0.contains("google") }) {
            return "chrome"
        }
        return nil
    }

    private static func displayName(family: String) -> String {
        switch family {
        case "arc":
            return "Arc"
        case "brave":
            return "Brave"
        case "edge":
            return "Microsoft Edge"
        case "helium":
            return "Helium"
        case "opera":
            return "Opera"
        case "vivaldi":
            return "Vivaldi"
        case "chrome":
            return "Chrome"
        default:
            return "Chromium"
        }
    }

    func publicTargetID(rawTargetID: String) -> String {
        guard rawTargetID.hasPrefix(chromiumTargetIDPrefix),
              !rawTargetID.hasPrefix(publicTargetIDPrefix)
        else {
            return rawTargetID
        }
        return "\(publicTargetIDPrefix)\(rawTargetID)"
    }

    func rawTargetID(publicTargetID: String) -> String? {
        guard publicTargetID.hasPrefix(chromiumTargetIDPrefix) else {
            return publicTargetID
        }
        guard publicTargetID.hasPrefix(publicTargetIDPrefix) else {
            return nil
        }
        return String(publicTargetID.dropFirst(publicTargetIDPrefix.count))
    }
}

func readExact(_ byteCount: Int) -> Data? {
    var data = Data()
    while data.count < byteCount {
        let chunk = FileHandle.standardInput.readData(ofLength: byteCount - data.count)
        if chunk.isEmpty {
            return nil
        }
        data.append(chunk)
    }
    return data
}

func readNativeMessage() -> Data? {
    guard let lengthData = readExact(4) else {
        return nil
    }
    let bytes = [UInt8](lengthData)
    let length = UInt32(bytes[0])
        | UInt32(bytes[1]) << 8
        | UInt32(bytes[2]) << 16
        | UInt32(bytes[3]) << 24
    return readExact(Int(length))
}

func writeNativeMessage(_ payload: Data) {
    var length = UInt32(payload.count).littleEndian
    let lengthData = Data(bytes: &length, count: 4)
    writeLock.lock()
    FileHandle.standardOutput.write(lengthData)
    FileHandle.standardOutput.write(payload)
    writeLock.unlock()
}

func payloadByAddingHostBrowserIdentity(_ payload: Data) -> String? {
    guard let rootObject = try? JSONSerialization.jsonObject(with: payload),
          var root = rootObject as? [String: Any],
          var targets = root["targets"] as? [[String: Any]]
    else {
        fputs("Keyway Chromium native host: ignoring malformed snapshot payload.\n", stderr)
        return nil
    }

    for index in targets.indices {
        guard let rawTargetID = targets[index]["id"] as? String else {
            fputs("Keyway Chromium native host: ignoring snapshot target without id.\n", stderr)
            return nil
        }
        targets[index]["id"] = hostBrowserIdentity.publicTargetID(rawTargetID: rawTargetID)
        targets[index]["browserFamily"] = hostBrowserIdentity.family
        targets[index]["browserDisplayName"] = hostBrowserIdentity.displayName
        targets[index]["browserBundleIdentifier"] = hostBrowserIdentity.bundleIdentifier
        targets[index]["browserInstanceID"] = hostBrowserIdentity.instanceID
        targets[index]["browser"] = hostBrowserIdentity.displayName
    }
    root["browserInstanceID"] = hostBrowserIdentity.instanceID
    root["targets"] = targets

    guard let enriched = try? JSONSerialization.data(withJSONObject: root),
          let payload = String(data: enriched, encoding: .utf8)
    else {
        fputs("Keyway Chromium native host: ignoring snapshot payload rewrite failure.\n", stderr)
        return nil
    }
    return payload
}

func payloadByRestoringRawTargetIdentity(_ payload: String) -> Data? {
    guard let data = payload.data(using: .utf8),
          let rootObject = try? JSONSerialization.jsonObject(with: data),
          var root = rootObject as? [String: Any],
          let publicTargetID = root["targetID"] as? String
    else {
        fputs("Keyway Chromium native host: ignoring malformed command payload.\n", stderr)
        return nil
    }
    guard let rawTargetID = hostBrowserIdentity.rawTargetID(publicTargetID: publicTargetID) else {
        return nil
    }
    root["targetID"] = rawTargetID

    guard let routed = try? JSONSerialization.data(withJSONObject: root) else {
        fputs("Keyway Chromium native host: ignoring command payload rewrite failure.\n", stderr)
        return nil
    }
    return routed
}

func payloadByRestoringPublicTargetIdentity(_ payload: Data) -> String? {
    guard let rootObject = try? JSONSerialization.jsonObject(with: payload),
          var root = rootObject as? [String: Any],
          let rawTargetID = root["targetID"] as? String
    else {
        fputs("Keyway Chromium native host: ignoring malformed result payload.\n", stderr)
        return nil
    }
    root["targetID"] = hostBrowserIdentity.publicTargetID(rawTargetID: rawTargetID)

    guard let routed = try? JSONSerialization.data(withJSONObject: root),
          let payload = String(data: routed, encoding: .utf8)
    else {
        fputs("Keyway Chromium native host: ignoring result payload rewrite failure.\n", stderr)
        return nil
    }
    return payload
}

let commandObserver = DistributedNotificationCenter.default().addObserver(
    forName: commandNotificationName,
    object: hostName,
    queue: .main
) { notification in
    guard let payload = notification.userInfo?["payload"] as? String else {
        fputs("Keyway Chromium native host: ignoring command notification without payload.\n", stderr)
        return
    }
    guard let routedPayload = payloadByRestoringRawTargetIdentity(payload) else {
        return
    }
    writeNativeMessage(routedPayload)
}

func postNativeMessage(_ payload: Data) {
    guard let envelope = try? JSONDecoder().decode(NativeMessageEnvelope.self, from: payload) else {
        fputs("Keyway Chromium native host: ignoring undecodable native message envelope.\n", stderr)
        return
    }
    guard envelope.type == "snapshot" || envelope.type == "hello" || envelope.type == "commandResult" || envelope.type == "focusResult" else {
        fputs("Keyway Chromium native host: ignoring unknown native message type.\n", stderr)
        return
    }
    guard envelope.type == "snapshot" || envelope.type == "commandResult" || envelope.type == "focusResult" else {
        return
    }
    let postedPayload = envelope.type == "snapshot"
        ? payloadByAddingHostBrowserIdentity(payload)
        : payloadByRestoringPublicTargetIdentity(payload)
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
