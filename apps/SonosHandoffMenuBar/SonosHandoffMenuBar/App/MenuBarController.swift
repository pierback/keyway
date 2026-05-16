import AppKit
import os
import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarController: View {
    static let settingsWindowID = "settings-window"

    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @StateObject private var playback: PlaybackSyncController
    private let doctorFeature = DoctorFeature()
    private let shortcutLogger = os.Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Shortcuts")

    @State private var showMore = false

    init(environment: AppEnvironment) {
        self.environment = environment
        _playback = StateObject(wrappedValue: PlaybackSyncController(environment: environment))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuBarVolumeControl(playback: playback)
            divider
            MenuBarOutputSection(playback: playback, openSpotifySettings: openSettingsWindow)
            divider
                .padding(.top, 8)
            footer
        }
        .frame(width: 296)
        .padding(.vertical, 0)
        .background(.ultraThickMaterial)
        .onAppear {
            StatusHUD.shared.setVolumeOverlaySuppressed(true)
            playback.appear()
        }
        .onDisappear {
            StatusHUD.shared.setVolumeOverlaySuppressed(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sound")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            if playback.isRefreshingOutputs || playback.loadingRoomName != nil {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.64)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow(title: "Show More", systemImage: showMore ? "chevron.down" : "chevron.right", emphasized: true) {
                withAnimation(.easeInOut(duration: 0.14)) {
                    showMore.toggle()
                }
            }

            if showMore {
                footerRow(title: "Check Shortcut Status", systemImage: "keyboard") {
                    checkShortcutStatus()
                }

                footerRow(title: doctorFeature.menuTitle, systemImage: "stethoscope") {
                    doctorFeature.runDoctor(using: environment)
                }

                if !AccessibilityPermission.isGranted() {
                    footerRow(title: "Enable fn Volume Shortcuts...", systemImage: "accessibility") {
                        openShortcutPermissions()
                    }
                }

                footerRow(title: "Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }

            divider
            footerRow(title: "Sound Settings...", systemImage: nil, emphasized: true) {
                openSettingsWindow()
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator.opacity(0.7))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func footerRow(
        title: String,
        systemImage: String?,
        emphasized: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                    .foregroundStyle(emphasized ? Color.primary : Color.secondary.opacity(0.92))
                Spacer()
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.secondary.opacity(0.74))
                        .frame(width: 16, height: 16)
                }
            }
            .frame(height: emphasized ? 29 : 27)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSettingsWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: Self.settingsWindowID)
        }
    }

    private func checkShortcutStatus() {
        NotificationCenter.default.post(name: .sonosHandoffRefreshHotkeys, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let status = ShortcutRuntimeStatus.shared.snapshot()
            shortcutLogger.info("SonosHandoffShortcuts accessibility=\(status.accessibilityGranted, privacy: .public) mediaFallback=\(status.mediaFallback.rawValue, privacy: .public) plainHotkeys=\(status.plainHotkeysRegistered, privacy: .public) fnHotkeys=\(status.fnHotkeysRegistered, privacy: .public) failure=\(status.lastFailureReason ?? "none", privacy: .public) step=\(status.step, privacy: .public) appPath=\(status.appPath, privacy: .public)")
            StatusHUD.shared.finish(title: status.title, message: status.message, dismissAfter: status.mediaFallback == .enabled ? 4.0 : 7.0)
            showNotification(title: status.title, message: status.message)
        }
    }

    private func openShortcutPermissions() {
        AccessibilityPermission.requestPrompt()
        NotificationCenter.default.post(name: .sonosHandoffRefreshHotkeys, object: nil)
        shortcutLogger.info("SonosHandoffShortcuts action=open_accessibility_settings appPath=\(Bundle.main.bundlePath, privacy: .public)")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        StatusHUD.shared.finish(
            title: "Enable Shortcuts",
            message: "Add and enable Sonos Handoff in Accessibility",
            dismissAfter: 7.0
        )
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }
}
