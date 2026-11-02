import Foundation
import os
@preconcurrency import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class StatusHUD {
    static let shared = StatusHUD()
    private static let statusIdentifier = "keyway.status"
    private static let pendingStatusIdentifier = "keyway.status.pending"

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Notifications")
    private let volumeHUD = VolumeHUDController()

    private init() {}

    func show(title: String, message: String) {
        deliver(title: title, message: message, identifier: Self.pendingStatusIdentifier)
    }

    func update(title: String? = nil, message: String) {
        deliver(title: title ?? "", message: message, identifier: Self.pendingStatusIdentifier)
    }

    func finish(title: String, message: String, dismissAfter seconds: TimeInterval = 3.5) {
        clearPendingStatusNotification()
        deliver(title: title, message: message, identifier: Self.statusIdentifier)
    }

    func showVolume(roomName: String, volume: Int, dismissAfter seconds: TimeInterval = 3.0) {
        volumeHUD.show(roomName: roomName, volume: volume, dismissAfter: seconds)
    }

    func showStatus(title: String, message: String, symbol: String, dismissAfter seconds: TimeInterval = 1.6) {
        volumeHUD.show(title: title, message: message, symbol: symbol, level: nil, dismissAfter: seconds)
    }

    func setVolumeAnchorProvider(_ provider: @escaping () -> NSRect?) {
        volumeHUD.setAnchorFrameProvider(provider)
    }

    func showMutePending(roomName: String) {
        showStatus(title: roomName, message: "Toggling mute…", symbol: "speaker.fill", dismissAfter: 3.0)
    }

    func showMute(roomName: String, muted: Bool, dismissAfter seconds: TimeInterval = 3.0) {
        showStatus(
            title: roomName,
            message: muted ? "Muted" : "Unmuted",
            symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            dismissAfter: seconds
        )
    }

    private func deliver(title: String, message: String, identifier: String) {
        let logger = logger
        logger.info("KeywayNotification request title=\(title, privacy: .public) message=\(message, privacy: .public) identifier=\(identifier, privacy: .public)")

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.addNotification(center: center, title: title, message: message, identifier: identifier, logger: logger)
            case .notDetermined:
                logger.info("KeywayNotification skipped title=\(title, privacy: .public) reason=authorization_not_requested")
            case .denied:
                logger.info("KeywayNotification skipped title=\(title, privacy: .public) reason=authorization_denied")
            @unknown default:
                logger.info("KeywayNotification skipped title=\(title, privacy: .public) reason=unknown_authorization")
            }
        }
    }

    private func clearPendingStatusNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.pendingStatusIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.pendingStatusIdentifier])
    }

    private nonisolated static func addNotification(
        center: UNUserNotificationCenter,
        title: String,
        message: String,
        identifier: String,
        logger: Logger
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = nil

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(request) { error in
            if let error {
                logger.error("KeywayNotification delivery_failed title=\(title, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("KeywayNotification delivered title=\(title, privacy: .public) identifier=\(identifier, privacy: .public)")
            }
        }
    }
}

@MainActor
private final class VolumeHUDController {
    private let model = VolumeHUDModel()
    private var panel: VolumeHUDPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var anchorFrameProvider: (() -> NSRect?)?

    func setAnchorFrameProvider(_ provider: @escaping () -> NSRect?) {
        anchorFrameProvider = provider
    }

    func show(roomName: String, volume: Int, dismissAfter seconds: TimeInterval) {
        let level = min(max(volume, 0), 100)
        let symbol = level == 0 ? "speaker.slash.fill" : level < 35 ? "speaker.wave.1.fill" : level < 70 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        show(title: roomName, message: "\(level)%", symbol: symbol, level: level, dismissAfter: seconds)
    }

    func show(title: String, message: String, symbol: String, level: Int?, dismissAfter seconds: TimeInterval) {
        model.title = title
        model.message = message
        model.symbol = symbol
        model.level = level

        let panel = ensurePanel()
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
            }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func ensurePanel() -> VolumeHUDPanel {
        if let panel {
            return panel
        }

        let panel = VolumeHUDPanel(
            contentRect: NSRect(origin: .zero, size: VolumeHUDView.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: VolumeHUDView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let size = NSSize(width: VolumeHUDView.size.width, height: model.level == nil ? VolumeHUDView.compactHeight : VolumeHUDView.size.height)
        if let anchorFrame = anchorFrameProvider?(),
           let screen = screen(containing: anchorFrame)
        {
            let visibleFrame = screen.visibleFrame
            let verticalGap: CGFloat = 8
            let edgeInset: CGFloat = 8
            let x = clamped(
                anchorFrame.midX - size.width / 2,
                min: visibleFrame.minX + edgeInset,
                max: visibleFrame.maxX - size.width - edgeInset
            )
            let y = clamped(
                anchorFrame.minY - verticalGap - size.height,
                min: visibleFrame.minY + edgeInset,
                max: visibleFrame.maxY - size.height - edgeInset
            )
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            return
        }

        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 16,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else {
            return minValue
        }
        return min(max(value, minValue), maxValue)
    }
}

@MainActor
private final class VolumeHUDModel: ObservableObject {
    @Published var title = ""
    @Published var message = ""
    @Published var symbol = "speaker.wave.2.fill"
    @Published var level: Int?
}

@MainActor
private struct VolumeHUDView: View {
    static let size = NSSize(width: 300, height: 70)
    static let compactHeight: CGFloat = 56

    @ObservedObject var model: VolumeHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(model.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let level = model.level {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule()
                            .fill(Color.primary.opacity(0.85))
                            .frame(width: geometry.size.width * CGFloat(level) / 100)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keywayGlass(cornerRadius: 18)
    }
}

@MainActor
private final class VolumeHUDPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
