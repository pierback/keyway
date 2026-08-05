import AppKit
import ApplicationServices
import os
import SonosHandoffCore
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
    static let schemaVersion = 3
    static let completionKey = "permissionOnboardingCompletedVersion"
    static let restartPendingKey = "permissionOnboardingRestartPending"
    static let localNetworkRequestedKey = "permissionOnboardingLocalNetworkRequested"
    private static let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "OnboardingUI")

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
                startLocalNetworkFeatures: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.localNetworkRequestedKey)
                    self?.startLocalNetworkFeatures()
                },
                localNetworkAlreadyRequested: localNetworkAlreadyRequested,
                requireRestart: {
                    UserDefaults.standard.set(true, forKey: Self.restartPendingKey)
                },
                quitForPermissionRestart: {
                    NSApp.terminate(nil)
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
                setExpanded: { [weak self] expanded in
                    self?.setPermissionCompanionExpanded(expanded)
                },
                dismiss: { [weak self] in
                    self?.hidePermissionCompanion()
                }
            )
        )

        panel.setContentSize(PermissionOnboardingCompanion.collapsedSize)
        let visibleFrame = window?.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 28,
                y: visibleFrame.maxY - panel.frame.height - 28
            )
        )
        permissionCompanionPanel = panel
        panel.orderFrontRegardless()
        Self.logger.notice(
            "PermissionCompanion state=shown permission=\(String(describing: permission), privacy: .public) frame=\(NSStringFromRect(panel.frame), privacy: .public)"
        )
    }

    private func makePermissionCompanionPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PermissionOnboardingCompanion.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    private func setPermissionCompanionExpanded(_ expanded: Bool) {
        guard let panel = permissionCompanionPanel else {
            return
        }
        let size = expanded
            ? PermissionOnboardingCompanion.expandedSize
            : PermissionOnboardingCompanion.collapsedSize
        let frame = NSRect(
            x: panel.frame.maxX - size.width,
            y: panel.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: true)
        Self.logger.notice(
            "PermissionCompanion state=\(expanded ? "expanded" : "collapsed", privacy: .public) frame=\(NSStringFromRect(frame), privacy: .public)"
        )
    }

    private func hidePermissionCompanion() {
        if let permissionCompanionPanel {
            Self.logger.notice(
                "PermissionCompanion state=hidden frame=\(NSStringFromRect(permissionCompanionPanel.frame), privacy: .public)"
            )
        }
        permissionCompanionPanel?.close()
        permissionCompanionPanel = nil
    }
}

private struct PermissionOnboardingCompanion: View {
    static let collapsedSize = NSSize(width: 244, height: 68)
    static let expandedSize = NSSize(width: 290, height: 276)

    let appURL: URL
    let permission: PermissionOnboardingCompanionPermission
    let setExpanded: (Bool) -> Void
    let dismiss: () -> Void

    @State private var expanded = false

    private var isTransientBuild: Bool {
        appURL.path.contains("/DerivedData/") || appURL.path.contains("/.build/")
    }

    var body: some View {
        Group {
            if expanded {
                VStack(spacing: 12) {
                    HStack {
                        Text("Add Keyway")
                            .font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button(action: dismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close permission helper")
                    }

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
            } else {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.supportsAppDrop ? "Drag Keyway into Settings" : "Finish permission setup")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Hover for instructions")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(
            width: expanded ? Self.expandedSize.width : Self.collapsedSize.width,
            height: expanded ? Self.expandedSize.height : Self.collapsedSize.height
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: expanded ? 20 : 17))
        .overlay {
            RoundedRectangle(cornerRadius: expanded ? 20 : 17)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard expanded != hovering else {
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                expanded = hovering
            }
            setExpanded(hovering)
        }
        .onTapGesture {
            expanded.toggle()
            setExpanded(expanded)
        }
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
