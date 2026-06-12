import AppKit
import Foundation
import os

@MainActor
final class MediaTargetSelectionMemory {
    private(set) var recentTargetID: String?

    func remember(_ target: MediaRemoteTarget) {
        recentTargetID = target.id
    }
}

enum SourceFocusFailureReason: String, Codable {
    case missingApplication = "missing_application"
    case applicationActivationRejected = "application_activation_rejected"
    case chromiumExtensionDisconnected = "chromium_extension_disconnected"
    case chromiumExtensionTimedOut = "chromium_extension_timed_out"
    case browserActivationFailed = "browser_activation_failed"
    case browserTargetUnavailable = "browser_target_unavailable"
}

struct SourceFocusResult: Codable, Equatable {
    let type: String
    let requestID: String?
    let targetID: String
    let ok: Bool
    let message: String
    let backend: String?
    let failureReason: SourceFocusFailureReason?

    init(
        type: String = "focusResult",
        requestID: String?,
        targetID: String,
        ok: Bool,
        message: String,
        backend: String?,
        failureReason: SourceFocusFailureReason? = nil
    ) {
        self.type = type
        self.requestID = requestID
        self.targetID = targetID
        self.ok = ok
        self.message = message
        self.backend = backend
        self.failureReason = failureReason
    }
}

enum SourceFocusDestination: Equatable {
    case chromiumExtension(targetID: String)
    case application(pid: Int?, bundleIdentifiers: [String])

    init(target: MediaRemoteTarget) {
        if ChromiumBrowserExtensionTransport.isTarget(target) {
            self = .chromiumExtension(targetID: target.id)
            return
        }

        let bundleIdentifiers = [target.bundleIdentifier, target.parentBundleIdentifier]
            .filter { !$0.isEmpty }
        self = .application(
            pid: target.pid > 0 ? target.pid : nil,
            bundleIdentifiers: bundleIdentifiers
        )
    }
}

@MainActor
final class SourceFocusActionController {
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "SourceFocus")
    private let mediaRemoteController: MediaRemoteController
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let targetSelectionMemory: MediaTargetSelectionMemory
    private let traceRecorder = SourceFocusTraceRecorder()
    private let nativeAppActivator = SourceFocusNativeAppActivator()

    init(
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        targetSelectionMemory: MediaTargetSelectionMemory
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.targetSelectionMemory = targetSelectionMemory
    }

    func focus(target: MediaRemoteTarget) {
        targetSelectionMemory.remember(target)
        logger.info("SourceFocus requested target=\(target.appName, privacy: .public) targetID=\(target.id, privacy: .public)")
        traceRecorder.record("source_focus_requested", target: target)

        if chromiumBrowserExtensionController.focus(target: target, onResult: { [weak self] result in
            self?.finish(result, target: target)
        }) == true {
            return
        }

        finish(nativeAppActivator.focus(target: target), target: target)
    }

    private func finish(_ result: SourceFocusResult, target: MediaRemoteTarget) {
        let event = result.ok ? "source_focus_succeeded" : "source_focus_failed"
        traceRecorder.record(event, target: target, result: result)

        guard !result.ok else {
            return
        }

        mediaRemoteController.refreshSnapshot()
        StatusHUD.shared.finish(
            title: "Could Not Focus \(target.appName)",
            message: result.message,
            dismissAfter: 2.4
        )
    }
}

private struct SourceFocusNativeAppActivator {
    func focus(target: MediaRemoteTarget) -> SourceFocusResult {
        if target.pid > 0,
           let app = NSRunningApplication(processIdentifier: pid_t(target.pid)) {
            return activate(app, target: target)
        }

        for bundleID in [target.bundleIdentifier, target.parentBundleIdentifier] where !bundleID.isEmpty {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return activate(app, target: target)
            }
        }

        return SourceFocusResult(
            requestID: nil,
            targetID: target.id,
            ok: false,
            message: "\(target.appName) is no longer running.",
            backend: "native_app_activation",
            failureReason: .missingApplication
        )
    }

    private func activate(_ app: NSRunningApplication, target: MediaRemoteTarget) -> SourceFocusResult {
        let activated = app.activate(options: [])
        return SourceFocusResult(
            requestID: nil,
            targetID: target.id,
            ok: activated,
            message: activated ? "focused" : "\(target.appName) rejected activation.",
            backend: "native_app_activation",
            failureReason: activated ? nil : .applicationActivationRejected
        )
    }
}

@MainActor
private final class SourceFocusTraceRecorder {
    private let runtimeStatus: ShortcutRuntimeStatus

    init(runtimeStatus: ShortcutRuntimeStatus = .shared) {
        self.runtimeStatus = runtimeStatus
    }

    func record(
        _ event: String,
        target: MediaRemoteTarget,
        result: SourceFocusResult? = nil
    ) {
        var fields: [String: Any] = [
            "target": target.appName,
            "targetID": target.id,
            "targetPlaying": target.isCurrentlyPlaying,
            "sourceFocus": true,
        ]
        if let result {
            fields["ok"] = result.ok
            fields["message"] = result.message
            if let backend = result.backend {
                fields["transportBackend"] = backend
            }
            if let failureReason = result.failureReason {
                fields["reason"] = failureReason.rawValue
            }
            if let requestID = result.requestID {
                fields["requestID"] = requestID
            }
        }
        runtimeStatus.recordMediaTransportEvent(event, fields: fields)
    }
}
