import AppKit
import ApplicationServices
import PermissionCompanionKit
import SonosHandoffCore
import SwiftUI

@MainActor
final class PermissionOnboardingWindowController: NSObject, NSWindowDelegate {
    static let schemaVersion = 3
    static let completionKey = "permissionOnboardingCompletedVersion"
    static let restartPendingKey = "permissionOnboardingRestartPending"
    static let localNetworkRequestedKey = "permissionOnboardingLocalNetworkRequested"

    private let refreshMediaPermissions: @MainActor () -> Void
    private let startLocalNetworkFeatures: @MainActor () -> Void
    private let didComplete: @MainActor () -> Void
    private var window: PermissionSetupWindow?

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
        let window = PermissionSetupWindow(
            contentSize: PermissionOnboardingFeature.preferredWindowSize,
            rootView: PermissionOnboardingFeature(
                refreshMediaPermissions: refreshMediaPermissions,
                arrangeBesideSystemSettings: { [weak self] in
                    self?.window?.arrange(beside: .systemSettings)
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
        window.title = "Set Up Keyway"
        window.delegate = self
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
        window = nil
        refreshMediaPermissions()
        _ = NSApp.setActivationPolicy(.accessory)
    }
}
