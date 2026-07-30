import AppKit
import SwiftUI

enum PermissionOnboardingCompanionPermission {
    case accessibility
    case inputMonitoring
    case notifications

    var instruction: String {
        switch self {
        case .accessibility:
            "If Keyway is not listed, drag it into Accessibility."
        case .inputMonitoring:
            "If Keyway is not listed, drag it into Input Monitoring."
        case .notifications:
            "Use Allow in the macOS prompt. Keyway is added automatically."
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
    static let schemaVersion = 2
    static let completionKey = "permissionOnboardingCompletedVersion"

    private let refreshMediaPermissions: @MainActor () -> Void
    private let startLocalNetworkFeatures: @MainActor () -> Void
    private var window: NSWindow?
    private var permissionCompanionPanel: NSPanel?

    init(
        refreshMediaPermissions: @escaping @MainActor () -> Void,
        startLocalNetworkFeatures: @escaping @MainActor () -> Void
    ) {
        self.refreshMediaPermissions = refreshMediaPermissions
        self.startLocalNetworkFeatures = startLocalNetworkFeatures
        super.init()
    }

    func presentIfNeeded() -> Bool {
        guard UserDefaults.standard.integer(forKey: Self.completionKey) < Self.schemaVersion,
              window == nil
        else {
            return false
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PermissionOnboardingFeature.preferredWindowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Keyway"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
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
                startLocalNetworkFeatures: startLocalNetworkFeatures,
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
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        hidePermissionCompanion()
        window = nil
        refreshMediaPermissions()
        _ = NSApp.setActivationPolicy(.accessory)
    }

    private func showPermissionCompanion(for permission: PermissionOnboardingCompanionPermission) {
        let appURL = Bundle.main.bundleURL
        let panel = permissionCompanionPanel ?? makePermissionCompanionPanel()
        panel.contentViewController = NSHostingController(
            rootView: PermissionOnboardingCompanion(
                appURL: appURL,
                permission: permission,
                dismiss: { [weak self] in
                    self?.hidePermissionCompanion()
                }
            )
        )

        let visibleFrame = window?.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 28,
                y: visibleFrame.maxY - panel.frame.height - 28
            )
        )
        permissionCompanionPanel = panel
        panel.orderFrontRegardless()
    }

    private func makePermissionCompanionPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 270, height: 260)),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Add Keyway"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    private func hidePermissionCompanion() {
        permissionCompanionPanel?.close()
        permissionCompanionPanel = nil
    }
}

private struct PermissionOnboardingCompanion: View {
    let appURL: URL
    let permission: PermissionOnboardingCompanionPermission
    let dismiss: () -> Void

    private var isTransientBuild: Bool {
        appURL.path.contains("/DerivedData/") || appURL.path.contains("/.build/")
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Add Keyway")
                .font(.system(size: 17, weight: .semibold))

            Text(permission.instruction)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if permission.supportsAppDrop {
                DraggableApplicationIcon(appURL: appURL, onSuccessfulDrop: dismiss)
                    .frame(width: 72, height: 72)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                Label("Drag Keyway.app", systemImage: "hand.draw")
                    .font(.system(size: 12, weight: .medium))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                Label("Continue in the macOS prompt", systemImage: "bell.badge")
                    .font(.system(size: 12, weight: .medium))
            }

            if isTransientBuild {
                Text("This is a development build. Install the final app before granting permanent access.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 270, height: 260)
    }
}

private struct DraggableApplicationIcon: NSViewRepresentable {
    let appURL: URL
    let onSuccessfulDrop: () -> Void

    func makeNSView(context: Context) -> DraggableApplicationIconView {
        DraggableApplicationIconView(appURL: appURL, onSuccessfulDrop: onSuccessfulDrop)
    }

    func updateNSView(_ nsView: DraggableApplicationIconView, context: Context) {
        nsView.onSuccessfulDrop = onSuccessfulDrop
    }
}

private final class DraggableApplicationIconView: NSImageView, NSDraggingSource {
    private let appURL: URL
    private var isDragging = false
    var onSuccessfulDrop: () -> Void

    init(appURL: URL, onSuccessfulDrop: @escaping () -> Void) {
        self.appURL = appURL
        self.onSuccessfulDrop = onSuccessfulDrop
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: appURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        toolTip = "Drag Keyway into the permission list"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag Keyway app")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging else {
            return
        }
        isDragging = true
        discardCursorRects()
        resetCursorRects()

        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        discardCursorRects()
        resetCursorRects()
        if operation.contains(.copy) {
            onSuccessfulDrop()
        }
    }
}
