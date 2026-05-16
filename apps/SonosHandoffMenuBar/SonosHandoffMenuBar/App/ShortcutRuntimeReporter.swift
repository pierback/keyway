import ApplicationServices
import Foundation

@MainActor
final class ShortcutRuntimeReporter {
    private let status: ShortcutRuntimeStatus

    init(status: ShortcutRuntimeStatus = .shared) {
        self.status = status
    }

    func mediaFallbackAlreadyRunning(fnHotkeysRegistered: Bool) {
        status.update(
            accessibilityGranted: AXIsProcessTrusted(),
            mediaFallback: .enabled,
            fnHotkeysRegistered: fnHotkeysRegistered,
            clearFailureReason: true
        )
    }

    func mediaFallbackStarting(accessibilityGranted: Bool) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            mediaFallback: .starting,
            clearFailureReason: true
        )
    }

    func eventTapCreateFailed(accessibilityGranted: Bool) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            mediaFallback: .eventTapCreateFailed,
            fnHotkeysRegistered: false,
            lastFailureReason: "event_tap_create_failed"
        )
    }

    func mediaFallbackEnabled(accessibilityGranted: Bool, fnHotkeysRegistered: Bool) {
        status.update(
            accessibilityGranted: accessibilityGranted,
            mediaFallback: .enabled,
            fnHotkeysRegistered: fnHotkeysRegistered,
            clearFailureReason: true
        )
    }

    func plainHotkeysRegistered(_ registered: Bool) {
        status.update(plainHotkeysRegistered: registered)
    }

    func fnHotkeysRegistered(_ registered: Bool) {
        status.update(fnHotkeysRegistered: registered)
    }
}
