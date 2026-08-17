import AppKit
import SwiftUI

@MainActor
final class BrowserExtensionSetupWindowController: NSObject, NSWindowDelegate {
    static let schemaVersion = 1
    static let completionKey = "browserExtensionSetupCompletedVersion"

    private let session: BrowserExtensionSetupSession
    private var window: NSWindow?

    init(extensionController: ChromiumBrowserExtensionController) {
        session = BrowserExtensionSetupSession(extensionController: extensionController)
        super.init()
    }

    func presentIfNeeded() -> Bool {
        guard UserDefaults.standard.integer(forKey: Self.completionKey) < Self.schemaVersion else {
            return false
        }
        return present()
    }

    func present() -> Bool {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return false
        }
        session.refreshInstalledBrowsers()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: BrowserExtensionSetupFeature.preferredWindowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Browser Extension"
        window.contentMinSize = BrowserExtensionSetupFeature.preferredWindowSize
        window.contentMaxSize = BrowserExtensionSetupFeature.preferredWindowSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = NSHostingController(
            rootView: BrowserExtensionSetupFeature(
                session: session,
                finish: { [weak self] in
                    UserDefaults.standard.set(Self.schemaVersion, forKey: Self.completionKey)
                    self?.window?.close()
                },
                setUpLater: { [weak self] in
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

    func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        window = nil
        if !NSApp.windows.contains(where: { $0 !== closingWindow && $0.isVisible }) {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}
