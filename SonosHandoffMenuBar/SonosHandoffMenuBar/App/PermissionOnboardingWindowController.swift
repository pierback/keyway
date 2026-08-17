import AppKit
import ApplicationServices
import PermissionCompanionKit
import SonosHandoffCore
import SwiftUI

enum PermissionOnboardingCompanionPermission {
    case accessibility
    case inputMonitoring
    case notifications

    var displayName: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .inputMonitoring:
            "Input Monitoring"
        case .notifications:
            "Notifications"
        }
    }

    var supportsAppDrop: Bool {
        switch self {
        case .accessibility, .inputMonitoring:
            true
        case .notifications:
            false
        }
    }
}

@MainActor
final class PermissionOnboardingWindowController: NSObject, NSWindowDelegate {
    static let schemaVersion = 3
    static let completionKey = "permissionOnboardingCompletedVersion"
    static let restartPendingKey = "permissionOnboardingRestartPending"
    static let localNetworkRequestedKey = "permissionOnboardingLocalNetworkRequested"

    private let refreshMediaPermissions: @MainActor () -> Void
    private let startLocalNetworkFeatures: @MainActor () -> Void
    private let didComplete: @MainActor () -> Void
    private let permissionCompanion = PermissionCompanionController()
    private var window: NSWindow?

    init(
        refreshMediaPermissions: @escaping @MainActor () -> Void,
        startLocalNetworkFeatures: @escaping @MainActor () -> Void,
        didComplete: @escaping @MainActor () -> Void
    ) {
        self.refreshMediaPermissions = refreshMediaPermissions
        self.startLocalNetworkFeatures = startLocalNetworkFeatures
        self.didComplete = didComplete
        super.init()
    }

    func presentIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        let setupNeedsAttention = defaults.integer(forKey: Self.completionKey) < Self.schemaVersion
            || defaults.bool(forKey: Self.restartPendingKey)
            || !AccessibilityPermission.isGranted()
            || !CGPreflightListenEventAccess()
        guard setupNeedsAttention else {
            return false
        }
        return present()
    }

    func present() -> Bool {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return false
        }
        let defaults = UserDefaults.standard
        let localNetworkAlreadyRequested = defaults.bool(forKey: Self.localNetworkRequestedKey)
            || defaults.integer(forKey: Self.completionKey) > 0
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PermissionOnboardingFeature.preferredWindowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Keyway"
        window.contentMinSize = PermissionOnboardingFeature.preferredWindowSize
        window.contentMaxSize = PermissionOnboardingFeature.preferredWindowSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = NSHostingController(
            rootView: PermissionOnboardingFeature(
                refreshMediaPermissions: refreshMediaPermissions,
                showPermissionCompanion: { [weak self] permission in
                    self?.showPermissionCompanion(for: permission)
                },
                hidePermissionCompanion: { [weak self] in
                    self?.hidePermissionCompanion()
                },
                startLocalNetworkFeatures: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.localNetworkRequestedKey)
                    self?.startLocalNetworkFeatures()
                },
                localNetworkAlreadyRequested: localNetworkAlreadyRequested,
                requireRestart: {
                    UserDefaults.standard.set(true, forKey: Self.restartPendingKey)
                },
                reopenForPermissionRestart: { [weak self] in
                    self?.reopenForPermissionRestart()
                },
                finish: { [weak self] in
                    self?.complete()
                },
                skip: { [weak self] in
                    self?.window?.close()
                }
            )
        )
        window.center()
        self.window = window

        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func complete() {
        UserDefaults.standard.set(Self.schemaVersion, forKey: Self.completionKey)
        UserDefaults.standard.set(true, forKey: Self.localNetworkRequestedKey)
        UserDefaults.standard.removeObject(forKey: Self.restartPendingKey)
        startLocalNetworkFeatures()
        window?.close()
        didComplete()
    }

    private func reopenForPermissionRestart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { application, error in
            precondition(
                application != nil && error == nil,
                "Failed to reopen Keyway: \(String(describing: error))"
            )
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        hidePermissionCompanion()
        window = nil
        refreshMediaPermissions()
        _ = NSApp.setActivationPolicy(.accessory)
    }

    private func showPermissionCompanion(for permission: PermissionOnboardingCompanionPermission) {
        permissionCompanion.present(
            PermissionCompanionConfiguration(
                applicationName: "Keyway",
                applicationURL: Bundle.main.bundleURL,
                permissionName: permission.displayName,
                interaction: permission.supportsAppDrop ? .dragApplication : .informational
            ),
            beneath: .systemSettings,
            onReturnToApplication: { [weak self] in
                self?.returnToPermissionWizard()
            }
        )
    }

    private func returnToPermissionWizard() {
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshMediaPermissions()
    }

    private func hidePermissionCompanion() {
        permissionCompanion.dismiss()
    }
}
