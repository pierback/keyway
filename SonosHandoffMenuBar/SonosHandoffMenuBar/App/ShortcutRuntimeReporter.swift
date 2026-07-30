import ApplicationServices
import Foundation

@MainActor
final class ShortcutRuntimeReporter {
    private let status: ShortcutRuntimeStatus

    init(status: ShortcutRuntimeStatus = .shared) {
        self.status = status
    }

    func mediaFallbackAlreadyRunning(fnHotkeysRegistered: Bool, activeEventTap: String?) {
        status.update(
            accessibilityGranted: AXIsProcessTrusted(),
            listenEventGranted: CGPreflightListenEventAccess(),
            mediaFallback: .enabled,
            eventTapRunning: true,
            activeEventTap: activeEventTap,
            commandCenterRouteRunning: true,
            fnHotkeysRegistered: fnHotkeysRegistered,
            clearFailureReason: true
        )
    }

    func mediaFallbackStarting(accessibilityGranted: Bool, listenEventGranted: Bool) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: .starting,
            eventTapRunning: false,
            clearActiveEventTap: true,
            commandCenterRouteRunning: false,
            clearFailureReason: true
        )
    }

    func mediaFallbackPermissionDenied(accessibilityGranted: Bool, listenEventGranted: Bool) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: .permissionDenied,
            eventTapRunning: false,
            clearActiveEventTap: true,
            commandCenterRouteRunning: false,
            fnHotkeysRegistered: false,
            lastFailureReason: "permission_denied"
        )
    }

    func eventTapCreateFailed(accessibilityGranted: Bool, listenEventGranted: Bool) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: .eventTapCreateFailed,
            eventTapRunning: false,
            clearActiveEventTap: true,
            commandCenterRouteRunning: false,
            fnHotkeysRegistered: false,
            lastFailureReason: "event_tap_create_failed"
        )
    }

    func mediaFallbackEnabled(accessibilityGranted: Bool, listenEventGranted: Bool, fnHotkeysRegistered: Bool, activeEventTap: String?) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: .enabled,
            eventTapRunning: true,
            activeEventTap: activeEventTap,
            commandCenterRouteRunning: true,
            fnHotkeysRegistered: fnHotkeysRegistered,
            clearFailureReason: true
        )
    }

    func mediaFallbackWaitingForCommandCenter(
        accessibilityGranted: Bool,
        listenEventGranted: Bool,
        activeEventTap: String?
    ) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: .starting,
            eventTapRunning: true,
            activeEventTap: activeEventTap,
            commandCenterRouteRunning: false,
            fnHotkeysRegistered: false,
            clearFailureReason: true
        )
    }

    func commandCenterRouteFailed(
        accessibilityGranted: Bool,
        listenEventGranted: Bool
    ) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: .commandCenterRouteFailed,
            eventTapRunning: false,
            clearActiveEventTap: true,
            commandCenterRouteRunning: false,
            fnHotkeysRegistered: false,
            lastFailureReason: "command_center_route_failed"
        )
    }

    func eventTapUnavailable(
        accessibilityGranted: Bool,
        listenEventGranted: Bool
    ) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            listenEventGranted: listenEventGranted,
            mediaFallback: .eventTapUnavailable,
            eventTapRunning: false,
            clearActiveEventTap: true,
            commandCenterRouteRunning: false,
            fnHotkeysRegistered: false,
            lastFailureReason: "event_tap_unavailable"
        )
    }

    func plainHotkeysRegistered(_ registered: Bool) {
        status.update(plainHotkeysRegistered: registered)
    }

    func commandCenterRouteRunning(_ running: Bool) {
        status.update(commandCenterRouteRunning: running)
    }

    func fnHotkeysRegistered(_ registered: Bool) {
        status.update(fnHotkeysRegistered: registered)
    }
}
