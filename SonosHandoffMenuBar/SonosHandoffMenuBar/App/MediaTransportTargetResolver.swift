import AppKit

struct MediaTransportTargetResolver {
    func sortedTargets(_ targets: [MediaRemoteTarget], preferredTargetID: String?) -> [MediaRemoteTarget] {
        MediaTransportCommandRules.sortedTargets(
            targets,
            preferredTargetID: preferredTargetID
        )
    }

    func automaticTarget(
        command: MediaRemoteTransportCommand,
        from targets: [MediaRemoteTarget],
        recentTargetID: String?
    ) -> (target: MediaRemoteTarget, reason: MediaTransportRoutingReason)? {
        if let extensionTarget = preferredChromiumExtensionTarget(command: command, from: targets) {
            return (extensionTarget, .current)
        }

        if targets.count == 1, let target = targets.first {
            return (target, .single)
        }

        let playingTargets = targets.filter(\.isCurrentlyPlaying)

        if playingTargets.count == 1, let playingTarget = playingTargets.first {
            return (playingTarget, .current)
        }

        if let focusedTarget = focusedTarget(in: targets) {
            return (focusedTarget, .focused)
        }

        if let recentTargetID,
           let recentTarget = targets.first(where: { $0.id == recentTargetID }) {
            return (recentTarget, .recent)
        }

        return nil
    }

    private func preferredChromiumExtensionTarget(command: MediaRemoteTransportCommand, from targets: [MediaRemoteTarget]) -> MediaRemoteTarget? {
        let extensionTargets = targets.filter {
            ChromiumBrowserExtensionTransport.supports(command: command, target: $0)
        }
        let playingExtensionTargets = extensionTargets.filter(\.isCurrentlyPlaying)
        guard playingExtensionTargets.count == 1 else {
            return nil
        }
        return playingExtensionTargets[0]
    }

    private func focusedTarget(in targets: [MediaRemoteTarget]) -> MediaRemoteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return prominentWindowTarget(in: targets)
        }

        if let foregroundTarget = target(
            matchingProcessID: app.processIdentifier,
            liveBundleIdentifier: app.bundleIdentifier,
            in: targets
        ) {
            return foregroundTarget
        }

        return prominentWindowTarget(in: targets)
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
               let target = target(forProcessID: pid_t(candidate.ownerPID), in: targets) {
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

    private func target(forProcessID pid: pid_t, in targets: [MediaRemoteTarget]) -> MediaRemoteTarget? {
        let app = NSRunningApplication(processIdentifier: pid)
        return target(
            matchingProcessID: pid,
            liveBundleIdentifier: app?.bundleIdentifier,
            in: targets
        )
    }

    private func target(
        matchingProcessID pid: pid_t,
        liveBundleIdentifier: String?,
        in targets: [MediaRemoteTarget]
    ) -> MediaRemoteTarget? {
        guard let liveBundleIdentifier, !liveBundleIdentifier.isEmpty else {
            return nil
        }

        let processID = Int(pid)
        if let exactTarget = targets.first(where: { target in
            target.pid == processID && target.matchesRoutingIdentity(liveBundleIdentifier)
        }) {
            return exactTarget
        }

        return targets.first { $0.matchesRoutingIdentity(liveBundleIdentifier) }
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
