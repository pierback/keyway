import AppKit
import SwiftUI

@MainActor
final class MediaTargetOverlayController {
    private let model = MediaTargetOverlayModel()
    private let audioController: MediaAudioControlController
    private var panel: MediaTargetOverlayPanel?
    private var onChoose: ((MediaRemoteTarget, MediaRemoteTransportCommand?) -> Void)?
    private var onDismiss: (() -> Void)?
    private var isClosing = false
    private var audioSnapshotGeneration = 0
    private var generation = 0

    init(audioController: MediaAudioControlController) {
        self.audioController = audioController
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var currentGeneration: Int {
        generation
    }

    func show(
        command: MediaRemoteTransportCommand?,
        targets: [MediaRemoteTarget],
        onChoose: @escaping (MediaRemoteTarget, MediaRemoteTransportCommand?) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        generation &+= 1
        self.onChoose = onChoose
        self.onDismiss = onDismiss
        isClosing = false
        model.update(command: command, targets: targets)
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

    private func close(notifyDismiss: Bool) {
        guard !isClosing else {
            return
        }

        isClosing = true
        let dismiss = onDismiss
        panel?.orderOut(nil)
        onChoose = nil
        onDismiss = nil
        isClosing = false

        if notifyDismiss {
            dismiss?()
        }
    }

    func updateTargetsIfVisible(targets: [MediaRemoteTarget], generation: Int) {
        guard isVisible, generation == self.generation else {
            return
        }

        model.updateTargetsPreservingSelection(targets)
        resizeAndPosition(ensurePanel())
        refreshAudioSnapshot()
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
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
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
            }
        ))
        self.panel = panel
        return panel
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if model.expanded, modifiers.contains(.command), keyCode == 126 {
            adjustSelectedExpandedVolume(direction: .up)
            return true
        }
        if model.expanded, modifiers.contains(.command), keyCode == 125 {
            adjustSelectedExpandedVolume(direction: .down)
            return true
        }

        switch keyCode {
        case 126:
            model.moveSelection(by: -1)
            refreshAudioSnapshot()
            return true
        case 125:
            model.moveSelection(by: 1)
            refreshAudioSnapshot()
            return true
        case 36, 76:
            if let target = model.selectedTarget {
                choose(target)
            }
            return true
        case 53:
            close()
            return true
        case 48:
            model.expanded.toggle()
            resizeAndPosition(ensurePanel())
            refreshAudioSnapshot()
            return true
        default:
            break
        }

        if let number = Int(characters), (1 ... 9).contains(number) {
            let index = number - 1
            guard model.targets.indices.contains(index) else {
                return true
            }
            if model.expanded {
                model.select(index: index)
                refreshAudioSnapshot()
                return true
            }
            choose(model.targets[index])
            return true
        }

        return false
    }

    private func choose(_ target: MediaRemoteTarget) {
        let choose = onChoose
        let command = model.command
        onChoose = nil
        onDismiss = nil
        close(notifyDismiss: false)
        choose?(target, command)
    }

    private func adjustSelectedExpandedVolume(direction: MediaAudioVolumeDirection) {
        guard let target = model.selectedTarget else {
            return
        }

        if target.isSpotify {
            audioController.adjustSpotifyVolume(direction: direction)
        } else if target.isBrowserLike {
            StatusHUD.shared.finish(
                title: "Browser Volume Disabled",
                message: "Keyway does not install a browser extension.",
                dismissAfter: 2.2
            )
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
    }

}
