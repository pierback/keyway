@preconcurrency import AppKit
import Combine
import SwiftUI

@MainActor
final class MediaTargetOverlayController {
    private let model = MediaTargetOverlayModel()
    private let audioController: MediaAudioControlController
    private var panel: MediaTargetOverlayPanel?
    private var onChoose: ((MediaRemoteTarget, MediaRemoteTransportCommand?) -> Void)?
    private var onFocus: ((MediaRemoteTarget) -> Void)?
    private var onDismiss: (() -> Void)?
    private var isClosing = false
    private var audioSnapshotGeneration = 0
    private var rowUpdatesSubscription: AnyCancellable?
    private var emptyConfirmationTask: Task<Void, Never>?
    private var emptyConfirmationGeneration = 0
    private var emptyDiagnostics: () -> String = { "Helper running / bridge connected" }
    private var resignActiveObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?

    init(audioController: MediaAudioControlController) {
        self.audioController = audioController
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusLossClose()
            }
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return
            }
            Task { @MainActor [weak self] in
                self?.scheduleFocusLossClose()
            }
        }
    }

    deinit {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(
        command: MediaRemoteTransportCommand?,
        rows: [SourceRow],
        rowUpdates: AnyPublisher<[SourceRow], Never>? = nil,
        emptyDiagnostics: @escaping () -> String = { "Helper running / bridge connected" },
        onChoose: @escaping (MediaRemoteTarget, MediaRemoteTransportCommand?) -> Void,
        onFocus: @escaping (MediaRemoteTarget) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onChoose = onChoose
        self.onFocus = onFocus
        self.onDismiss = onDismiss
        self.emptyDiagnostics = emptyDiagnostics
        isClosing = false
        model.update(command: command, rows: rows)
        subscribeToRows(rowUpdates)
        scheduleEmptyConfirmationIfNeeded(emptyDiagnostics: emptyDiagnostics)
        refreshAudioSnapshot()

        let panel = ensurePanel()
        resizeAndPosition(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        resizeAndPosition(panel)
    }

    func close() {
        close(notifyDismiss: true)
    }

    private func scheduleFocusLossClose() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self,
                  self.panel?.isKeyWindow != true
            else {
                return
            }
            self.closeFromFocusLoss()
        }
    }

    private func closeFromFocusLoss() {
        guard isVisible else {
            return
        }
        close(notifyDismiss: true)
    }

    private func close(notifyDismiss: Bool) {
        guard !isClosing else {
            return
        }

        isClosing = true
        let dismiss = onDismiss
        panel?.orderOut(nil)
        onChoose = nil
        onFocus = nil
        onDismiss = nil
        rowUpdatesSubscription = nil
        emptyConfirmationTask = nil
        emptyConfirmationGeneration += 1
        isClosing = false

        if notifyDismiss {
            dismiss?()
        }
    }

    private func ensurePanel() -> MediaTargetOverlayPanel {
        if let panel {
            return panel
        }

        let panel = MediaTargetOverlayPanel(
            contentRect: NSRect(origin: .zero, size: panelSize()),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
        ]
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        panel.onResignKey = { [weak self] in
            self?.scheduleFocusLossClose()
        }
        panel.contentView = NSHostingView(rootView: MediaTargetOverlayView(
            model: model,
            onChoose: { [weak self] target in
                self?.choose(target)
            },
            onSelect: { [weak self] index in
                self?.model.select(index: index)
                self?.refreshAudioSnapshot()
            },
            onSonosVolume: { [weak self] direction in
                self?.audioController.adjustSonosVolume(direction: direction)
                self?.refreshAudioSnapshot(delay: 0.35)
            },
            onSonosMute: { [weak self] in
                self?.audioController.toggleSonosMute()
                self?.refreshAudioSnapshot(delay: 0.35)
            },
            onSpotifyVolume: { [weak self] direction in
                self?.audioController.adjustSpotifyVolume(direction: direction)
                self?.refreshAudioSnapshot(delay: 0.35)
            },
            onBrowserVolume: { [weak self] direction in
                guard let self,
                      let target = self.model.selectedTarget
                else {
                    return
                }
                self.audioController.adjustBrowserVolume(direction: direction, target: target)
                self.refreshAudioSnapshot(delay: 0.35)
            },
            onBrowserMute: { [weak self] in
                guard let self,
                      let target = self.model.selectedTarget
                else {
                    return
                }
                self.audioController.toggleBrowserMute(target: target)
                self.refreshAudioSnapshot(delay: 0.35)
            }
        ))
        self.panel = panel
        return panel
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action = MediaTargetOverlayKeyboardInterpreter.action(
            keyCode: keyCode,
            characters: characters,
            commandDown: modifiers.contains(.command),
            expanded: model.expanded,
            targetCount: model.targets.count
        )

        switch action {
        case .moveSelection(let delta):
            model.moveSelection(by: delta)
            refreshAudioSnapshot()
            return true
        case .adjustExpandedVolume(let direction):
            adjustSelectedExpandedVolume(direction: direction)
            return true
        case .routeSelected:
            if let target = model.selectedTarget {
                choose(target)
            }
            return true
        case .focusSelected:
            if let target = model.selectedTarget {
                focus(target)
            }
            return true
        case .close:
            close()
            return true
        case .toggleControls:
            model.expanded.toggle()
            resizeAndPosition(ensurePanel())
            refreshAudioSnapshot()
            return true
        case .quickRoute(let index):
            choose(model.targets[index])
            return true
        case .quickSelect(let index):
            model.select(index: index)
            refreshAudioSnapshot()
            return true
        case .none:
            return false
        }
    }

    private func choose(_ target: MediaRemoteTarget) {
        let choose = onChoose
        let command = model.command
        onChoose = nil
        onDismiss = nil
        close(notifyDismiss: false)
        choose?(target, command)
    }

    private func focus(_ target: MediaRemoteTarget) {
        let focus = onFocus
        onChoose = nil
        onFocus = nil
        onDismiss = nil
        close(notifyDismiss: false)
        focus?(target)
    }

    private func adjustSelectedExpandedVolume(direction: MediaAudioVolumeDirection) {
        guard let target = model.selectedTarget else {
            return
        }

        if target.isSpotify {
            audioController.adjustSpotifyVolume(direction: direction)
        } else if target.isBrowserLike {
            audioController.adjustBrowserVolume(direction: direction, target: target)
        } else {
            StatusHUD.shared.finish(
                title: "Volume Unsupported",
                message: "\(target.appName) does not expose a Keyway volume backend.",
                dismissAfter: 2.2
            )
        }
        refreshAudioSnapshot(delay: 0.35)
    }

    private func refreshAudioSnapshot(delay: TimeInterval = 0) {
        let selectedTarget = model.selectedTarget
        let snapshotTargetID = selectedTarget?.id
        audioSnapshotGeneration += 1
        let generation = audioSnapshotGeneration
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self else { return }
            let snapshot = await audioController.snapshot(for: selectedTarget)
            guard generation == audioSnapshotGeneration,
                  model.selectedTarget?.id == snapshotTargetID
            else {
                return
            }
            model.audioSnapshot = snapshot
        }
    }

    private func subscribeToRows(_ rowUpdates: AnyPublisher<[SourceRow], Never>?) {
        rowUpdatesSubscription = rowUpdates?.sink { [weak self] rows in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.updateRowsPreservingSelection(rows)
                self.refreshAudioSnapshot()
                self.scheduleEmptyConfirmationIfNeeded(emptyDiagnostics: self.emptyDiagnostics)
                if let panel = self.panel {
                    self.resizeAndPosition(panel)
                }
            }
        }
    }

    private func scheduleEmptyConfirmationIfNeeded(emptyDiagnostics: @escaping () -> String) {
        guard model.rows.isEmpty else {
            emptyConfirmationTask = nil
            emptyConfirmationGeneration += 1
            model.emptyState = .discovering
            return
        }
        guard emptyConfirmationTask == nil else {
            return
        }
        emptyConfirmationGeneration += 1
        let generation = emptyConfirmationGeneration
        model.emptyState = .discovering
        emptyConfirmationTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(
                nanoseconds: UInt64(MediaTransportCommandRules.emptyDiscoveryInterval * 1_000_000_000)
            )) != nil else {
                return
            }
            guard let self,
                  self.emptyConfirmationGeneration == generation,
                  self.isVisible,
                  self.model.rows.isEmpty
            else {
                return
            }
            self.emptyConfirmationTask = nil
            self.model.emptyState = .confirmedEmpty(detail: emptyDiagnostics())
        }
    }

    private func resizeAndPosition(_ panel: NSPanel) {
        let size = panelSize()
        panel.setContentSize(size)
        guard let screen = screenContainingMouse() else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func panelSize() -> NSSize {
        let visibleRows = min(model.targets.count, 6)
        let rowHeight: CGFloat = 52
        let rowSpacing: CGFloat = 3
        let topPad: CGFloat = 14
        let bottomPad: CGFloat = model.expanded ? 0 : 8
        let listHeight = topPad
            + CGFloat(max(1, visibleRows)) * rowHeight
            + CGFloat(max(0, visibleRows - 1)) * rowSpacing
            + bottomPad
        let expandedHeight: CGFloat = model.expanded ? 120 : 0
        let footerHeight: CGFloat = 36
        let height = min(600, listHeight + expandedHeight + footerHeight)

        return NSSize(width: 680, height: height)
    }

    private func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
private final class MediaTargetOverlayPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

}
