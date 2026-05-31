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
            fnHotkeysRegistered: fnHotkeysRegistered,
            clearFailureReason: true
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
