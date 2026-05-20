import AppKit
import Foundation
import os
import SonosHandoffCore

@MainActor
final class MediaTransportActionController {
    private enum RoutingReason: String {
        case single = "single target"
        case focused = "focused target"
        case pinned = "pinned target"
        case recent = "recent target"
        case chooser = "chooser"
    }

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaTransport")
    private let mediaRemoteController: MediaRemoteController
    private let preferenceStore: MediaTargetPreferenceStore
    private let overlayController: MediaTargetOverlayController

    init(
        mediaRemoteController: MediaRemoteController,
        preferenceStore: MediaTargetPreferenceStore,
        overlayController: MediaTargetOverlayController
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.preferenceStore = preferenceStore
        self.overlayController = overlayController
    }

    func route(command: MediaRemoteTransportCommand) {
        mediaRemoteController.refreshSnapshot()
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty else {
            StatusHUD.shared.show(title: "Media Targets", message: "Looking for Now Playing sessions...")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                self?.routeUsingCurrentSnapshot(command: command)
            }
            return
        }

        route(command: command, targets: targets)
    }

    private func routeUsingCurrentSnapshot(command: MediaRemoteTransportCommand) {
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty else {
            StatusHUD.shared.finish(
                title: "No Media Target",
                message: "Start Spotify, a browser video, or QuickTime playback.",
                dismissAfter: 2.4
            )
            return
        }

        route(command: command, targets: targets)
    }

    private func route(command: MediaRemoteTransportCommand, targets: [MediaRemoteTarget]) {
        if let decision = automaticTarget(from: targets) {
            send(command: command, to: decision.target, reason: decision.reason)
            return
        }

        overlayController.show(
            command: command,
            targets: targets,
            pinnedIdentity: preferenceStore.pinnedTargetIdentity,
            onChoose: { [weak self] target, command in
                self?.send(command: command, to: target, reason: .chooser)
            },
            onPinToggle: { [weak self] target in
                self?.preferenceStore.togglePinnedTarget(target)
                let pinned = target.matchesRoutingIdentity(self?.preferenceStore.pinnedTargetIdentity)
                self?.logger.info("MediaTransport pin target=\(target.appName, privacy: .public) pinned=\(pinned, privacy: .public)")
            }
        )
    }

    private func automaticTarget(from targets: [MediaRemoteTarget]) -> (target: MediaRemoteTarget, reason: RoutingReason)? {
        if targets.count == 1, let target = targets.first {
            return (target, .single)
        }

        if let focusedTarget = focusedTarget(in: targets) {
            return (focusedTarget, .focused)
        }

        if let pinnedTarget = target(matching: preferenceStore.pinnedTargetIdentity, in: targets) {
            return (pinnedTarget, .pinned)
        }

        if let recentTarget = target(matching: preferenceStore.recentTargetIdentity, in: targets) {
            return (recentTarget, .recent)
        }

        return nil
    }

    private func send(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget, reason: RoutingReason) {
        preferenceStore.markRecentTarget(target)
        mediaRemoteController.send(command: command, targetID: target.id)
        logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        StatusHUD.shared.finish(
            title: "\(command.displayName) → \(target.appName)",
            message: "Routed by \(reason.rawValue)",
            dismissAfter: 1.35
        )
    }

    private func focusedTarget(in targets: [MediaRemoteTarget]) -> MediaRemoteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return prominentWindowTarget(in: targets)
        }
        let bundleID = app.bundleIdentifier ?? ""
        let pid = Int(app.processIdentifier)
        if let foregroundTarget = targets.first(where: { target in
            target.pid == pid
                || target.bundleIdentifier == bundleID
                || target.parentBundleIdentifier == bundleID
                || target.routingIdentity == bundleID
        }) {
            return foregroundTarget
        }

        return prominentWindowTarget(in: targets)
    }

    private func target(matching identity: String?, in targets: [MediaRemoteTarget]) -> MediaRemoteTarget? {
        targets.first { $0.matchesRoutingIdentity(identity) }
    }

    private func sortedTargets(_ targets: [MediaRemoteTarget]) -> [MediaRemoteTarget] {
        let activeTargetID = mediaRemoteController.activeTargetID
        return targets.sorted { lhs, rhs in
            if lhs.id == activeTargetID {
                return true
            }
            if rhs.id == activeTargetID {
                return false
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    private func prominentWindowTarget(in targets: [MediaRemoteTarget]) -> MediaRemoteTarget? {
        guard let screen = screenContainingMouse(),
              let screenWindowFrame = windowCoordinateFrame(for: screen),
              let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        var higherWindows: [CGRect] = []
        for window in windowInfo {
            guard let candidate = windowCandidate(from: window, within: screenWindowFrame) else {
                continue
            }

            if candidate.frame.width >= 80,
               candidate.frame.height >= 60,
               isProminentlyVisible(candidate.frame, aboveWindows: higherWindows),
               let target = target(forWindowOwnerPID: candidate.ownerPID, in: targets) {
                return target
            }

            higherWindows.append(candidate.frame)
        }

        return nil
    }

    private func windowCandidate(from window: [String: Any], within screenFrame: CGRect) -> (ownerPID: Int, frame: CGRect)? {
        guard let layer = window[kCGWindowLayer as String] as? Int,
              layer == 0,
              let alpha = window[kCGWindowAlpha as String] as? Double,
              alpha > 0,
              let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"],
              let y = bounds["Y"],
              let width = bounds["Width"],
              let height = bounds["Height"],
              width > 0,
              height > 0
        else {
            return nil
        }

        let frame = CGRect(x: x, y: y, width: width, height: height).intersection(screenFrame)
        guard !frame.isNull, !frame.isEmpty else {
            return nil
        }
        return (ownerPID, frame)
    }

    private func isProminentlyVisible(_ frame: CGRect, aboveWindows: [CGRect]) -> Bool {
        let samplePoints = visibilitySamplePoints(in: frame)
        let visibleCount = samplePoints.filter { point in
            !aboveWindows.contains { $0.contains(point) }
        }.count
        return visibleCount >= 3
    }

    private func visibilitySamplePoints(in frame: CGRect) -> [CGPoint] {
        let xPositions = [frame.minX + frame.width * 0.25, frame.midX, frame.minX + frame.width * 0.75]
        let yPositions = [frame.minY + frame.height * 0.25, frame.midY, frame.minY + frame.height * 0.75]
        return xPositions.flatMap { x in
            yPositions.map { y in
                CGPoint(x: x, y: y)
            }
        }
    }

    private func target(forWindowOwnerPID pid: Int, in targets: [MediaRemoteTarget]) -> MediaRemoteTarget? {
        let app = NSRunningApplication(processIdentifier: pid_t(pid))
        let bundleID = app?.bundleIdentifier ?? ""
        return targets.first { target in
            target.pid == pid
                || target.bundleIdentifier == bundleID
                || target.parentBundleIdentifier == bundleID
                || target.routingIdentity == bundleID
        }
    }

    private func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func windowCoordinateFrame(for screen: NSScreen) -> CGRect? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return CGDisplayBounds(displayID)
    }
}
