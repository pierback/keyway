import ApplicationServices
import Foundation
import SonosHandoffCore

enum ShortcutMediaFallbackState: String {
    case unknown
    case starting
    case enabled
    case permissionDenied = "permission_denied"
    case eventTapCreateFailed = "event_tap_create_failed"
}

struct ShortcutRuntimeSnapshot {
    let accessibilityGranted: Bool
    let listenEventGranted: Bool
    let mediaFallback: ShortcutMediaFallbackState
    let eventTapRunning: Bool
    let activeEventTap: String?
    let commandCenterRouteRunning: Bool
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

        if commandCenterRouteRunning {
            return "Command Center route is not a hardware interception path"
        }

        if mediaFallback == .permissionDenied {
            if !accessibilityGranted, !listenEventGranted {
                return "Enable Accessibility and Input Monitoring for media keys; Shift+F10/F11/F12 works"
            }
            if !accessibilityGranted {
                return "Enable Accessibility for media keys; Shift+F10/F11/F12 works"
            }
            if !listenEventGranted {
                return "Enable Input Monitoring for media keys; Shift+F10/F11/F12 works"
            }
            return "Media-key permission state changed; refresh shortcuts"
        }

        if mediaFallback == .eventTapCreateFailed {
            return "Enable Accessibility and Input Monitoring for media keys; Shift+F10/F11/F12 works"
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
    private static let timestampFormatter = ISO8601DateFormatter()

    private var accessibilityGranted = AXIsProcessTrusted()
    private var listenEventGranted = CGPreflightListenEventAccess()
    private var mediaFallback: ShortcutMediaFallbackState = .unknown
    private var eventTapRunning = false
    private var activeEventTap: String?
    private var commandCenterRouteRunning = false
    private var plainHotkeysRegistered = false
    private var fnHotkeysRegistered = false
    private var lastFailureReason: String?
    private var mediaTargets: [[String: Any]] = []
    private var mediaTargetSignature = ""
    private var mediaTargetCount = 0
    private var rawMediaTargetCount = 0
    private var activeMediaTargetID: String?
    private var rawActiveMediaTargetID: String?
    private var mediaTargetsUpdatedAt: String?
    private var mediaTransportTrace: [[String: Any]] = []
    private var mediaTransportTraceSequence = 0
    private var tracePersistenceScheduled = false

    private init() {}

    func update(
        accessibilityGranted: Bool? = nil,
        listenEventGranted: Bool? = nil,
        mediaFallback: ShortcutMediaFallbackState? = nil,
        eventTapRunning: Bool? = nil,
        activeEventTap: String? = nil,
        clearActiveEventTap: Bool = false,
        commandCenterRouteRunning: Bool? = nil,
        plainHotkeysRegistered: Bool? = nil,
        fnHotkeysRegistered: Bool? = nil,
        lastFailureReason: String? = nil,
        clearFailureReason: Bool = false
    ) {
        if let accessibilityGranted {
            self.accessibilityGranted = accessibilityGranted
        }
        if let listenEventGranted {
            self.listenEventGranted = listenEventGranted
        }
        if let mediaFallback {
            self.mediaFallback = mediaFallback
        }
        if let eventTapRunning {
            self.eventTapRunning = eventTapRunning
        }
        if let activeEventTap {
            self.activeEventTap = activeEventTap
        } else if clearActiveEventTap {
            self.activeEventTap = nil
        }
        if let commandCenterRouteRunning {
            self.commandCenterRouteRunning = commandCenterRouteRunning
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

    func updateMediaTargets(
        _ targets: [MediaRemoteTarget],
        activeTargetID: String?,
        rawTargetCount: Int,
        rawActiveTargetID: String? = nil
    ) {
        let rows = targets.map { target in
            [
                "id": target.id,
                "app": target.appName,
                "bundleIdentifier": target.bundleIdentifier,
                "parentBundleIdentifier": target.parentBundleIdentifier,
                "pid": target.pid,
                "playing": target.isCurrentlyPlaying,
                "playbackRate": target.playbackRate,
                "title": target.title,
                "artist": target.artist,
                "freshness": target.playbackFreshness,
            ] as [String: Any]
        }
        let signature = rows
            .map { row in
                [
                    row["id"] as? String ?? "",
                    row["playbackRate"] as? String ?? "",
                    row["title"] as? String ?? "",
                    row["artist"] as? String ?? "",
                ].joined(separator: "|")
            }
            .joined(separator: "\n")
        guard signature != mediaTargetSignature
            || activeTargetID != activeMediaTargetID
            || rawTargetCount != rawMediaTargetCount
            || rawActiveTargetID != rawActiveMediaTargetID
        else {
            return
        }

        mediaTargets = rows
        mediaTargetSignature = signature
        mediaTargetCount = targets.count
        rawMediaTargetCount = rawTargetCount
        activeMediaTargetID = activeTargetID
        rawActiveMediaTargetID = rawActiveTargetID
        mediaTargetsUpdatedAt = Self.timestampFormatter.string(from: Date())
        persistSnapshot()
    }

    func snapshot() -> ShortcutRuntimeSnapshot {
        ShortcutRuntimeSnapshot(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: mediaFallback,
            eventTapRunning: eventTapRunning,
            activeEventTap: activeEventTap,
            commandCenterRouteRunning: commandCenterRouteRunning,
            plainHotkeysRegistered: plainHotkeysRegistered,
            fnHotkeysRegistered: fnHotkeysRegistered,
            lastFailureReason: lastFailureReason,
            appPath: Bundle.main.bundlePath,
            step: SpeakerVolumeControlDefaults.step
        )
    }

    func recordMediaTransportEvent(
        _ event: String,
        fields: [String: Any] = [:]
    ) {
        var payload = fields
        mediaTransportTraceSequence &+= 1
        payload["event"] = event
        payload["sequence"] = mediaTransportTraceSequence
        payload["monotonicMilliseconds"] = Int((ProcessInfo.processInfo.systemUptime * 1000).rounded())
        payload["at"] = Self.timestampFormatter.string(from: Date())
        mediaTransportTrace.append(payload)
        if mediaTransportTrace.count > 240 {
            mediaTransportTrace.removeFirst(mediaTransportTrace.count - 240)
        }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8)!
        DistributedNotificationCenter.default().postNotificationName(
            .keywayMediaTransportTrace,
            object: "com.fpieringer.Keyway",
            userInfo: ["payload": json],
            deliverImmediately: true
        )
        scheduleTracePersistence()
    }

    private func scheduleTracePersistence() {
        guard !tracePersistenceScheduled else {
            return
        }

        tracePersistenceScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.tracePersistenceScheduled = false
            self.persistSnapshot()
        }
    }

    private func persistSnapshot() {
        let snapshot = snapshot()
        var payload: [String: Any] = [
            "accessibilityGranted": snapshot.accessibilityGranted,
            "listenEventGranted": snapshot.listenEventGranted,
            "mediaFallback": snapshot.mediaFallback.rawValue,
            "eventTapRunning": snapshot.eventTapRunning,
            "commandCenterRouteRunning": snapshot.commandCenterRouteRunning,
            "plainHotkeysRegistered": snapshot.plainHotkeysRegistered,
            "fnHotkeysRegistered": snapshot.fnHotkeysRegistered,
            "appPath": snapshot.appPath,
            "mediaTransportTraceSequence": mediaTransportTraceSequence,
            "step": snapshot.step,
            "updatedAt": Self.timestampFormatter.string(from: Date()),
        ]
        if let lastFailureReason = snapshot.lastFailureReason {
            payload["lastFailureReason"] = lastFailureReason
        }
        if let activeEventTap = snapshot.activeEventTap {
            payload["activeEventTap"] = activeEventTap
        }
        payload["mediaTargetCount"] = mediaTargetCount
        payload["rawMediaTargetCount"] = rawMediaTargetCount
        payload["mediaTargets"] = mediaTargets
        if let activeMediaTargetID {
            payload["activeMediaTargetID"] = activeMediaTargetID
        }
        if let rawActiveMediaTargetID {
            payload["rawActiveMediaTargetID"] = rawActiveMediaTargetID
        }
        if let mediaTargetsUpdatedAt {
            payload["mediaTargetsUpdatedAt"] = mediaTargetsUpdatedAt
        }
        if !mediaTransportTrace.isEmpty {
            payload["mediaTransportTrace"] = mediaTransportTrace
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
    static let sonosHandoffAcceptHeadphoneTransferSuggestion = Notification.Name("com.fpieringer.Keyway.acceptHeadphoneTransferSuggestion")
    static let sonosHandoffIgnoreHeadphoneTransferSuggestion = Notification.Name("com.fpieringer.Keyway.ignoreHeadphoneTransferSuggestion")
    static let sonosHandoffRefreshOutputs = Notification.Name("com.fpieringer.Keyway.refreshOutputs")
    static let sonosHandoffApplyCachedOutputs = Notification.Name("com.fpieringer.Keyway.applyCachedOutputs")
    static let keywayMediaTransportTrace = Notification.Name("com.fpieringer.Keyway.mediaTransportTrace")
    static let keywayMediaRoutingProbeRequest = Notification.Name("com.fpieringer.Keyway.mediaRoutingProbe.request")
    static let keywayMediaRoutingProbeResponse = Notification.Name("com.fpieringer.Keyway.mediaRoutingProbe.response")
}
