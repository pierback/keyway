import Foundation

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
        targets[index]["browserProcessIdentifier"] = hostBrowserIdentity.processIdentifier
        targets[index]["profileGuid"] = profileGuid
        targets[index]["browser"] = hostBrowserIdentity.displayName
    }
    root["profileGuid"] = profileGuid
    root["browserFamily"] = hostBrowserIdentity.family
    root["browserDisplayName"] = hostBrowserIdentity.displayName
    root["browserBundleIdentifier"] = hostBrowserIdentity.bundleIdentifier
    root["browserProcessIdentifier"] = hostBrowserIdentity.processIdentifier
    // Private routing token only; target identity is chromium-tab:<profileGuid>:<tabId>.
    root["connectionID"] = connectionID
    root["connectionGeneration"] = connectionGeneration
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
    if root["type"] as? String == "reloadExtension", root["connectionID"] == nil {
        return data
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
          var root = rootObject as? [String: Any],
          (root["targetID"] as? String) != nil
    else {
        fputs("Keyway Chromium native host: ignoring malformed result payload.\n", stderr)
        return nil
    }

    root["connectionID"] = connectionID
    root["connectionGeneration"] = connectionGeneration
    guard let enriched = try? JSONSerialization.data(withJSONObject: root),
          let payload = String(data: enriched, encoding: .utf8)
    else {
        fputs("Keyway Chromium native host: ignoring result payload rewrite failure.\n", stderr)
        return nil
    }
    return payload
}
