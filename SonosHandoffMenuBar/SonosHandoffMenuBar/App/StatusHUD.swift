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

    func setVolumeAnchorProvider(_ provider: @escaping () -> NSRect?) {
        volumeHUD.setAnchorFrameProvider(provider)
    }

    func showMutePending(roomName: String) {
        deliver(title: roomName, message: "Toggling mute...", identifier: Self.pendingStatusIdentifier)
    }

    func showMute(roomName: String, muted: Bool, dismissAfter seconds: TimeInterval = 3.0) {
        clearPendingStatusNotification()

        deliver(
            title: roomName,
            message: muted ? "Muted" : "Unmuted",
            identifier: "keyway.mute.\(roomName)"
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
        model.roomName = roomName
        model.volume = min(max(volume, 0), 100)

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
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: VolumeHUDView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let size = VolumeHUDView.size
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
    @Published var roomName = ""
    @Published var volume = 0
}

@MainActor
private struct VolumeHUDView: View {
    static let size = NSSize(width: 292, height: 63)

    @ObservedObject var model: VolumeHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.roomName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.96))

            HStack(spacing: 7) {
                Image(systemName: leadingIconName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                    .foregroundStyle(.white.opacity(0.94))

                VolumeHUDSlider(volume: model.volume)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(.white.opacity(0.94))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.24), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var leadingIconName: String {
        if model.volume == 0 {
            return "speaker.slash.fill"
        }
        if model.volume < 35 {
            return "speaker.wave.1.fill"
        }
        if model.volume < 70 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }
}

private struct VolumeHUDSlider: View {
    let volume: Int

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = CGFloat(volume) / 100

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.24))
                    .frame(height: 4)

                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: width * progress, height: 4)

                HStack {
                    ForEach(0 ..< 13, id: \.self) { _ in
                        Circle()
                            .fill(.black.opacity(0.22))
                            .frame(width: 2, height: 2)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 4)
                .offset(y: 8)
            }
            .frame(height: 13)
        }
        .frame(height: 13)
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
