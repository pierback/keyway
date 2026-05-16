@preconcurrency import AppKit

@MainActor
final class StatusHUD {
    static let shared = StatusHUD()

    private var hudPanel: StatusHUDPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var suppressVolumeOverlay = false

    private init() {}

    func setVolumeOverlaySuppressed(_ suppressed: Bool) {
        suppressVolumeOverlay = suppressed
        guard suppressed else {
            return
        }

        hideWorkItem?.cancel()
        hudPanel?.orderOut()
    }

    func show(title: String, message: String) {
        hideWorkItem?.cancel()
        let panel = ensurePanel()
        panel.showLoadingMessage(title: title, message: message)
        panel.orderFront()
    }

    func update(title: String? = nil, message: String) {
        let panel = ensurePanel()
        panel.updateMessage(title: title, message: message)
        panel.position()
    }

    func finish(title: String, message: String, dismissAfter seconds: TimeInterval = 3.5) {
        hideWorkItem?.cancel()
        let panel = ensurePanel()
        panel.showFinishedMessage(title: title, message: message)
        panel.orderFront()
        scheduleDismiss(after: seconds)
    }

    func showVolumePending(roomName: String, direction: VolumeDirection) {
        guard !suppressVolumeOverlay else {
            return
        }

        hideWorkItem?.cancel()
        let panel = ensurePanel()
        panel.showVolumePending(roomName: roomName)
        panel.orderFront()
    }

    func showVolume(roomName: String, volume: Int, direction: VolumeDirection, dismissAfter seconds: TimeInterval = 3.0) {
        guard !suppressVolumeOverlay else {
            return
        }

        hideWorkItem?.cancel()
        let panel = ensurePanel()
        panel.showVolume(roomName: roomName, volume: volume)
        panel.orderFront()
        scheduleDismiss(after: seconds)
    }

    func showMutePending(roomName: String) {
        guard !suppressVolumeOverlay else {
            return
        }

        hideWorkItem?.cancel()
        let panel = ensurePanel()
        panel.showMutePending(roomName: roomName)
        panel.orderFront()
    }

    func showMute(roomName: String, muted: Bool, dismissAfter seconds: TimeInterval = 3.0) {
        guard !suppressVolumeOverlay else {
            return
        }

        hideWorkItem?.cancel()
        let panel = ensurePanel()
        panel.showMute(roomName: roomName, muted: muted)
        panel.orderFront()
        scheduleDismiss(after: seconds)
    }

    private func ensurePanel() -> StatusHUDPanel {
        if let hudPanel {
            return hudPanel
        }

        let panel = StatusHUDPanel { [weak self] in
            self?.hideWorkItem?.cancel()
            self?.hudPanel?.orderOut()
        }
        hudPanel = panel
        return panel
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hudPanel?.orderOut()
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }
}
