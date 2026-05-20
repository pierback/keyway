import ApplicationServices
import Foundation
import SonosHandoffCore

enum ShortcutMediaFallbackState: String {
    case unknown
    case starting
    case enabled
    case eventTapCreateFailed = "event_tap_create_failed"
}

struct ShortcutRuntimeSnapshot {
    let accessibilityGranted: Bool
    let mediaFallback: ShortcutMediaFallbackState
    let plainHotkeysRegistered: Bool
    let fnHotkeysRegistered: Bool
    let lastFailureReason: String?
    let appPath: String
    let step: Int

    var title: String {
        if mediaFallback == .enabled {
            return "Shortcuts Ready"
        }

        if plainHotkeysRegistered {
            return "fn Shortcuts Blocked"
        }

        return "Shortcuts Need Attention"
    }

    var message: String {
        if mediaFallback == .enabled {
            return "Shift+fn+F10/F11/F12 enabled; step \(step)%"
        }

        if mediaFallback == .eventTapCreateFailed {
            return "Enable Accessibility for Shift+fn+F10/F11/F12; Shift+F10/F11/F12 works"
        }

        if plainHotkeysRegistered {
            return "Shift+F10/F11/F12 works; fn path not ready"
        }

        return "Shortcut registration has not completed"
    }
}

@MainActor
final class ShortcutRuntimeStatus {
    static let shared = ShortcutRuntimeStatus()
    static let persistenceURL = ConfigPaths.applicationSupportDirectory
        .appendingPathComponent("shortcut-runtime-status.json", isDirectory: false)

    private var accessibilityGranted = AXIsProcessTrusted()
    private var mediaFallback: ShortcutMediaFallbackState = .unknown
    private var plainHotkeysRegistered = false
    private var fnHotkeysRegistered = false
    private var lastFailureReason: String?

    private init() {}

    func update(
        accessibilityGranted: Bool? = nil,
        mediaFallback: ShortcutMediaFallbackState? = nil,
        plainHotkeysRegistered: Bool? = nil,
        fnHotkeysRegistered: Bool? = nil,
        lastFailureReason: String? = nil,
        clearFailureReason: Bool = false
    ) {
        if let accessibilityGranted {
            self.accessibilityGranted = accessibilityGranted
        }
        if let mediaFallback {
            self.mediaFallback = mediaFallback
        }
        if let plainHotkeysRegistered {
            self.plainHotkeysRegistered = plainHotkeysRegistered
        }
        if let fnHotkeysRegistered {
            self.fnHotkeysRegistered = fnHotkeysRegistered
        }
        if let lastFailureReason {
            self.lastFailureReason = lastFailureReason
        } else if clearFailureReason {
            self.lastFailureReason = nil
        }
        persistSnapshot()
    }

    func snapshot() -> ShortcutRuntimeSnapshot {
        ShortcutRuntimeSnapshot(
            accessibilityGranted: accessibilityGranted,
            mediaFallback: mediaFallback,
            plainHotkeysRegistered: plainHotkeysRegistered,
            fnHotkeysRegistered: fnHotkeysRegistered,
            lastFailureReason: lastFailureReason,
            appPath: Bundle.main.bundlePath,
            step: SpeakerVolumeControlDefaults.step
        )
    }

    private func persistSnapshot() {
        let snapshot = snapshot()
        var payload: [String: Any] = [
            "accessibilityGranted": snapshot.accessibilityGranted,
            "mediaFallback": snapshot.mediaFallback.rawValue,
            "plainHotkeysRegistered": snapshot.plainHotkeysRegistered,
            "fnHotkeysRegistered": snapshot.fnHotkeysRegistered,
            "appPath": snapshot.appPath,
            "step": snapshot.step,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let lastFailureReason = snapshot.lastFailureReason {
            payload["lastFailureReason"] = lastFailureReason
        }

        do {
            try FileManager.default.createDirectory(
                at: ConfigPaths.applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.persistenceURL, options: .atomic)
        } catch {}
    }
}

extension Notification.Name {
    static let sonosHandoffRefreshHotkeys = Notification.Name("com.fpieringer.Keyway.refreshHotkeys")
    static let sonosHandoffAcceptGroupSuggestion = Notification.Name("com.fpieringer.Keyway.acceptGroupSuggestion")
    static let sonosHandoffIgnoreGroupSuggestion = Notification.Name("com.fpieringer.Keyway.ignoreGroupSuggestion")
    static let sonosHandoffAcceptTransferSuggestion = Notification.Name("com.fpieringer.Keyway.acceptTransferSuggestion")
    static let sonosHandoffIgnoreTransferSuggestion = Notification.Name("com.fpieringer.Keyway.ignoreTransferSuggestion")
    static let sonosHandoffRefreshOutputs = Notification.Name("com.fpieringer.Keyway.refreshOutputs")
    static let sonosHandoffApplyCachedOutputs = Notification.Name("com.fpieringer.Keyway.applyCachedOutputs")
}
