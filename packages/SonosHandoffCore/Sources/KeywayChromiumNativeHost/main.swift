import AppKit
import Darwin
import Foundation

let snapshotNotificationName = Notification.Name("com.fpieringer.keyway.chromium.snapshot")
let commandResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.commandResult")
let focusResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.focusResult")
let commandNotificationName = Notification.Name("com.fpieringer.keyway.chromium.command")
let hostName = "com.fpieringer.keyway.chromium"
let chromiumTargetIDPrefix = "chromium-tab:"
let writeLock = NSLock()
let hostBrowserIdentity = HostBrowserIdentity.current()
let connectionID = UUID().uuidString.lowercased()
let hostConnectionState = HostConnectionState()

struct NativeMessageEnvelope: Decodable {
    let type: String
}

struct NativeHelloMessage: Decodable {
    let profileGuid: String
    let epoch: Int
    let resumed: Bool
    let snapshot: [NativeHelloSnapshotTarget]?

    private enum CodingKeys: String, CodingKey {
        case profileGuid
        case epoch
        case resumed
        case snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileGuid = try container.decode(String.self, forKey: .profileGuid)
        epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        resumed = try container.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
        snapshot = try container.decodeIfPresent([NativeHelloSnapshotTarget].self, forKey: .snapshot)
    }
}

struct NativeHelloSnapshotTarget: Decodable {
    let tabId: Int
}

final class HostConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var profileGuid: String?

    func record(profileGuid: String) {
        lock.lock()
        self.profileGuid = profileGuid
        lock.unlock()
    }

    func currentProfileGuid() -> String? {
        lock.lock()
        let value = profileGuid
        lock.unlock()
        return value
    }
}

struct HostBrowserIdentity {
    let family: String
    let displayName: String
    let bundleIdentifier: String

    static func current() -> HostBrowserIdentity {
        let parentPID = getppid()
        guard let app = NSRunningApplication(processIdentifier: pid_t(parentPID)) else {
            exitWithFailure("could not resolve parent browser process \(parentPID).")
        }
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? ""
        guard let family = browserFamily(bundleIdentifier: bundleIdentifier, displayName: appName) else {
            exitWithFailure("parent is not a supported browser: \(bundleIdentifier) \(appName)")
        }

        return HostBrowserIdentity(
            family: family,
            displayName: appName.isEmpty ? displayName(family: family) : appName,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func exitWithFailure(_ message: String) -> Never {
        fputs("Keyway Chromium native host: \(message)\n", stderr)
        exit(EXIT_FAILURE)
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

func recordHelloProfileGuid(_ payload: Data) -> NativeHelloMessage? {
    guard let hello = try? JSONDecoder().decode(NativeHelloMessage.self, from: payload) else {
        fputs("Keyway Chromium native host: ignoring malformed hello payload.\n", stderr)
        return nil
    }
    hostConnectionState.record(profileGuid: hello.profileGuid)
    return hello
}

func payloadByAddingHostBrowserIdentity(
    root: [String: Any],
    targets: [[String: Any]],
    profileGuid: String
) -> String? {
    var root = root
    var targets = targets
    for index in targets.indices {
        guard let tabID = targets[index]["tabId"] as? Int else {
            fputs("Keyway Chromium native host: ignoring snapshot target without tabId.\n", stderr)
            return nil
        }
        targets[index]["id"] = "\(chromiumTargetIDPrefix)\(profileGuid):\(tabID)"
        targets[index]["browserFamily"] = hostBrowserIdentity.family
        targets[index]["browserDisplayName"] = hostBrowserIdentity.displayName
        targets[index]["browserBundleIdentifier"] = hostBrowserIdentity.bundleIdentifier
        targets[index]["profileGuid"] = profileGuid
        targets[index]["browser"] = hostBrowserIdentity.displayName
    }
    root["profileGuid"] = profileGuid
    root["browserFamily"] = hostBrowserIdentity.family
    root["browserDisplayName"] = hostBrowserIdentity.displayName
    root["browserBundleIdentifier"] = hostBrowserIdentity.bundleIdentifier
    // Private routing token only; target identity is chromium-tab:<profileGuid>:<tabId>.
    root["connectionID"] = connectionID
    root["targets"] = targets

    guard let enriched = try? JSONSerialization.data(withJSONObject: root),
          let payload = String(data: enriched, encoding: .utf8)
    else {
        fputs("Keyway Chromium native host: ignoring snapshot payload rewrite failure.\n", stderr)
        return nil
    }
    return payload
}

func payloadByAddingHostBrowserIdentity(_ payload: Data) -> String? {
    guard let rootObject = try? JSONSerialization.jsonObject(with: payload),
          let root = rootObject as? [String: Any],
          let targets = root["targets"] as? [[String: Any]]
    else {
        fputs("Keyway Chromium native host: ignoring malformed snapshot payload.\n", stderr)
        return nil
    }
    guard let profileGuid = hostConnectionState.currentProfileGuid() else {
        fputs("Keyway Chromium native host: ignoring snapshot before hello.\n", stderr)
        return nil
    }

    return payloadByAddingHostBrowserIdentity(root: root, targets: targets, profileGuid: profileGuid)
}

func payloadStringForHello(_ payload: Data) -> String? {
    guard let hello = recordHelloProfileGuid(payload) else {
        return nil
    }
    guard let rootObject = try? JSONSerialization.jsonObject(with: payload),
          var root = rootObject as? [String: Any]
    else {
        fputs("Keyway Chromium native host: ignoring malformed hello payload.\n", stderr)
        return nil
    }
    root["type"] = "snapshot"
    root["epoch"] = hello.epoch
    root["resumed"] = hello.resumed
    root["targets"] = root["snapshot"] as? [[String: Any]] ?? []
    root.removeValue(forKey: "snapshot")
    return payloadByAddingHostBrowserIdentity(
        root: root,
        targets: root["targets"] as? [[String: Any]] ?? [],
        profileGuid: hello.profileGuid
    )
}

func payloadByMatchingConnectionID(_ payload: String) -> Data? {
    guard let data = payload.data(using: .utf8),
          let rootObject = try? JSONSerialization.jsonObject(with: data),
          var root = rootObject as? [String: Any]
    else {
        fputs("Keyway Chromium native host: ignoring malformed command payload.\n", stderr)
        return nil
    }
    guard let payloadConnectionID = root["connectionID"] as? String else {
        return nil
    }
    guard payloadConnectionID == connectionID else {
        return nil
    }
    root.removeValue(forKey: "connectionID")

    guard let routed = try? JSONSerialization.data(withJSONObject: root) else {
        fputs("Keyway Chromium native host: ignoring command payload rewrite failure.\n", stderr)
        return nil
    }
    return routed
}

func payloadStringForResult(_ payload: Data) -> String? {
    guard let rootObject = try? JSONSerialization.jsonObject(with: payload),
          let root = rootObject as? [String: Any],
          (root["targetID"] as? String) != nil
    else {
        fputs("Keyway Chromium native host: ignoring malformed result payload.\n", stderr)
        return nil
    }

    guard let payload = String(data: payload, encoding: .utf8)
    else {
        fputs("Keyway Chromium native host: ignoring non-UTF-8 result payload.\n", stderr)
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
