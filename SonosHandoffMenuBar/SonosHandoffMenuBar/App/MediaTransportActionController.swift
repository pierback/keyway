import AppKit
import Foundation
import os
import SonosHandoffCore

enum MediaRouteStatusKind: String, Equatable {
    case auto
    case focused
    case chooser
    case unavailable

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .focused:
            return "Focused"
        case .chooser:
            return "Chooser"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct MediaRouteStatus: Equatable {
    var kind: MediaRouteStatusKind
    var target: MediaRemoteTarget?
    var targetCount: Int

    var subtitle: String {
        switch kind {
        case .auto:
            return targetCount == 1 ? "Single media target" : "Automatic routing"
        case .focused:
            return "Foreground or visible window"
        case .chooser:
            return "Choose target"
        case .unavailable:
            return "Start Spotify, browser media, or QuickTime"
        }
    }
}

@MainActor
final class MediaTransportActionController {
    private static let routeSnapshotMaxAge: TimeInterval = 0.75
    private static let chooserSnapshotMaxAge: TimeInterval = 1.5

    private enum RoutingReason: String {
        case single = "single target"
        case focused = "focused target"
        case current = "current media target"
        case chooser = "chooser"
    }

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "MediaTransport")
    private let mediaRemoteController: MediaRemoteController
    private let overlayController: MediaTargetOverlayController

    init(
        mediaRemoteController: MediaRemoteController,
        overlayController: MediaTargetOverlayController
    ) {
        self.mediaRemoteController = mediaRemoteController
        self.overlayController = overlayController
    }

    func route(command: MediaRemoteTransportCommand) {
        if command == .playPause || command == .pause {
            if !showChooserImmediately(command: command) {
                showChooser(command: command)
            }
            return
        }
        Task { [weak self] in
            await self?.routeAfterRefreshingSnapshot(command: command)
        }
    }

    func showChooser(command: MediaRemoteTransportCommand = .playPause) {
        Task { [weak self] in
            await self?.showChooserAfterRefreshingSnapshot(command: command)
        }
    }

    func showTargetChooser() {
        Task { [weak self] in
            await self?.showChooserAfterRefreshingSnapshot(command: .playPause)
        }
    }

    func route(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget) {
        Task { [weak self] in
            await self?.send(command: command, to: target, reason: .current)
        }
    }

    func currentRouteStatus() -> MediaRouteStatus {
        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty, mediaRemoteController.canRouteCommands else {
            return MediaRouteStatus(kind: .unavailable, target: nil, targetCount: 0)
        }

        if let decision = automaticTarget(from: targets) {
            let kind: MediaRouteStatusKind = targets.count > 1
                ? .chooser
                : statusKind(for: decision.reason)

            return MediaRouteStatus(
                kind: kind,
                target: decision.target,
                targetCount: targets.count
            )
        }

        return MediaRouteStatus(
            kind: .chooser,
            target: mediaRemoteController.activeTarget ?? targets.first,
            targetCount: targets.count
        )
    }

    private func showChooserImmediately(command: MediaRemoteTransportCommand) -> Bool {
        guard mediaRemoteController.canRouteCommands,
              !mediaRemoteController.targets.isEmpty,
              mediaRemoteController.hasFreshSnapshot(maxAge: Self.chooserSnapshotMaxAge)
        else {
            return false
        }

        mediaRemoteController.refreshSnapshot()

        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty else {
            return false
        }

        showChooserOverlay(command: command, targets: targets)

        return true
    }

    private func routeAfterRefreshingSnapshot(command: MediaRemoteTransportCommand) async {
        let needsFreshSnapshot = !mediaRemoteController.canRouteCommands
            || mediaRemoteController.targets.isEmpty
            || !mediaRemoteController.hasFreshSnapshot(maxAge: Self.routeSnapshotMaxAge)

        if needsFreshSnapshot {
            StatusHUD.shared.show(title: "Media Targets", message: "Looking for Now Playing sessions...")
            let refreshed = await mediaRemoteController.refreshSnapshotAndWait()
            guard refreshed || mediaRemoteController.hasFreshSnapshot(maxAge: Self.routeSnapshotMaxAge) else {
                StatusHUD.shared.finish(
                    title: "Media Targets Unavailable",
                    message: "Keyway could not refresh Now Playing sessions.",
                    dismissAfter: 2.4
                )
                return
            }
        } else {
            mediaRemoteController.refreshSnapshot()
        }

        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty, mediaRemoteController.canRouteCommands else {
            StatusHUD.shared.finish(
                title: "No Media Target",
                message: "Start Spotify, a browser video, or QuickTime playback.",
                dismissAfter: 2.4
            )
            return
        }

        route(command: command, targets: targets)
    }

    private func showChooserAfterRefreshingSnapshot(command: MediaRemoteTransportCommand?) async {
        let needsFreshSnapshot = !mediaRemoteController.canRouteCommands
            || mediaRemoteController.targets.isEmpty
            || !mediaRemoteController.hasFreshSnapshot(maxAge: Self.chooserSnapshotMaxAge)

        if needsFreshSnapshot {
            StatusHUD.shared.show(title: "Media Targets", message: "Looking for Now Playing sessions...")
            let refreshed = await mediaRemoteController.refreshSnapshotAndWait()
            guard refreshed || mediaRemoteController.hasFreshSnapshot(maxAge: Self.chooserSnapshotMaxAge) else {
                StatusHUD.shared.finish(
                    title: "Media Targets Unavailable",
                    message: "Keyway could not refresh Now Playing sessions.",
                    dismissAfter: 2.4
                )
                return
            }
        } else {
            mediaRemoteController.refreshSnapshot()
        }

        let targets = sortedTargets(mediaRemoteController.targets)
        guard !targets.isEmpty, mediaRemoteController.canRouteCommands else {
            StatusHUD.shared.finish(
                title: "No Media Target",
                message: "Start Spotify, a browser video, or QuickTime playback.",
                dismissAfter: 2.4
            )
            return
        }

        showChooserOverlay(command: command, targets: targets)
    }

    private func route(command: MediaRemoteTransportCommand, targets: [MediaRemoteTarget]) {
        if let decision = automaticTarget(from: targets) {
            Task { [weak self] in
                await self?.send(command: command, to: decision.target, reason: decision.reason)
            }
            return
        }

        showChooserOverlay(command: command, targets: targets)
    }

    private func showChooserOverlay(command: MediaRemoteTransportCommand?, targets: [MediaRemoteTarget]) {
        let displayedTargets = targets
        overlayController.show(
            command: command,
            targets: targets,
            onChoose: { [weak self] target, command in
                guard let self else { return }
                let displayedTarget = displayedTargets.first { $0.id == target.id } ?? target

                guard let command else {
                    self.mediaRemoteController.refreshSnapshot()
                    StatusHUD.shared.finish(
                        title: "\(displayedTarget.appName)",
                        message: "No transport command was pending.",
                        dismissAfter: 1.35
                    )
                    return
                }

                if command == .playPause || command == .pause {
                    Task { [weak self] in
                        await self?.sendFromChooser(command: command, to: displayedTarget)
                    }
                } else {
                    Task { [weak self] in
                        await self?.send(command: command, to: displayedTarget, reason: .chooser)
                    }
                }
            }
        )
    }

    private func statusKind(for reason: RoutingReason) -> MediaRouteStatusKind {
        switch reason {
        case .single:
            return .auto
        case .focused:
            return .focused
        case .current:
            return .auto
        case .chooser:
            return .chooser
        }
    }

    private func automaticTarget(from targets: [MediaRemoteTarget]) -> (target: MediaRemoteTarget, reason: RoutingReason)? {
        if targets.count == 1, let target = targets.first {
            return (target, .single)
        }

        let playingTargets = targets.filter(\.isCurrentlyPlaying)

        if let focusedTarget = focusedTarget(in: targets) {
            return (focusedTarget, .focused)
        }

        if playingTargets.count == 1, let playingTarget = playingTargets.first {
            return (playingTarget, .current)
        }

        return nil
    }

    private func send(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget, reason: RoutingReason) async {
        let sent = await mediaRemoteController.send(command: command, targetID: target.id)
        guard sent else {
            logger.error("MediaTransport route_failed command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: "Keyway could not reach \(target.appName).",
                dismissAfter: 2.2
            )
            return
        }

        logger.info("MediaTransport route command=\(command.rawValue, privacy: .public) target=\(target.appName, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        StatusHUD.shared.finish(
            title: "\(command.displayName) → \(target.appName)",
            message: "Routed by \(reason.rawValue)",
            dismissAfter: 1.35
        )
    }

    private func sendFromChooser(command: MediaRemoteTransportCommand, to target: MediaRemoteTarget) async {
        let routedCommand = command == .playPause
            ? (target.isCurrentlyPlaying ? MediaRemoteTransportCommand.pause : .play)
            : command
        let sent = await mediaRemoteController.send(command: routedCommand, targetID: target.id)
        guard sent else {
            logger.error("MediaTransport chooser_failed command=\(routedCommand.rawValue, privacy: .public) target=\(target.appName, privacy: .public)")
            StatusHUD.shared.finish(
                title: "Media Command Failed",
                message: "Keyway could not reach \(target.appName).",
                dismissAfter: 2.2
            )
            return
        }

        logger.info("MediaTransport chooser command=\(routedCommand.rawValue, privacy: .public) target=\(target.appName, privacy: .public)")
        StatusHUD.shared.finish(
            title: "\(routedCommand.displayName) → \(target.appName)",
            message: "Routed by chooser",
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

    private func sortedTargets(_ targets: [MediaRemoteTarget]) -> [MediaRemoteTarget] {
        let activeTargetID = mediaRemoteController.activeTargetID

        return targets.sorted { lhs, rhs in
            if lhs.isCurrentlyPlaying != rhs.isCurrentlyPlaying {
                return lhs.isCurrentlyPlaying
            }
            if lhs.isCurrentlyPlaying, rhs.isCurrentlyPlaying {
                let lhsActive = lhs.id == activeTargetID
                let rhsActive = rhs.id == activeTargetID
                if lhsActive != rhsActive {
                    return lhsActive
                }
                if lhs.playbackFreshness != rhs.playbackFreshness {
                    return lhs.playbackFreshness > rhs.playbackFreshness
                }
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
