import Foundation
import os
@preconcurrency import UserNotifications

@MainActor
final class StatusHUD {
    static let shared = StatusHUD()

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Notifications")
    private var suppressVolumeNotifications = false

    private init() {}

    func setVolumeOverlaySuppressed(_ suppressed: Bool) {
        suppressVolumeNotifications = suppressed
    }

    func show(title: String, message: String) {
        logger.info("KeywayNotification pending title=\(title, privacy: .public) message=\(message, privacy: .public)")
    }

    func update(title: String? = nil, message: String) {
        logger.info("KeywayNotification update title=\(title ?? "", privacy: .public) message=\(message, privacy: .public)")
    }

    func finish(title: String, message: String, dismissAfter seconds: TimeInterval = 3.5) {
        deliver(title: title, message: message, identifier: "keyway.status")
    }

    func showVolume(roomName: String, volume: Int, dismissAfter seconds: TimeInterval = 3.0) {
        guard !suppressVolumeNotifications else {
            return
        }

        deliver(
            title: "\(roomName) Volume",
            message: "\(volume)%",
            identifier: "keyway.volume.\(roomName)"
        )
    }

    func showMutePending(roomName: String) {
        logger.info("KeywayNotification pending_mute room=\(roomName, privacy: .public)")
    }

    func showMute(roomName: String, muted: Bool, dismissAfter seconds: TimeInterval = 3.0) {
        guard !suppressVolumeNotifications else {
            return
        }

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
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        logger.error("KeywayNotification authorization_failed title=\(title, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        return
                    }
                    guard granted else {
                        logger.info("KeywayNotification authorization_denied title=\(title, privacy: .public)")
                        return
                    }
                    Self.addNotification(center: center, title: title, message: message, identifier: identifier, logger: logger)
                }
            case .denied:
                logger.info("KeywayNotification skipped title=\(title, privacy: .public) reason=authorization_denied")
            @unknown default:
                logger.info("KeywayNotification skipped title=\(title, privacy: .public) reason=unknown_authorization")
            }
        }
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
