import AppKit
import os
import SonosHandoffCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
struct PermissionOnboardingFeature: View {
    static let preferredWindowSize = CGSize(width: 620, height: 600)
    private static let mediaPermissionRefreshInterval: TimeInterval = 0.2

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
    private static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )!
    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications"
    )!
    private static let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Onboarding")

    let refreshMediaPermissions: @MainActor () -> Void
    let showPermissionCompanion: @MainActor (PermissionOnboardingCompanionPermission) -> Void
    let hidePermissionCompanion: @MainActor () -> Void
    let startLocalNetworkFeatures: @MainActor () -> Void
    let requireRestart: @MainActor () -> Void
    let reopenForPermissionRestart: @MainActor () -> Void
    let finish: @MainActor () -> Void
    let skip: @MainActor () -> Void

    @State private var accessibilityGranted = AccessibilityPermission.isGranted()
    @State private var inputMonitoringGranted = CGPreflightListenEventAccess()
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var hasCheckedNotificationAuthorization = false
    @State private var isRequestingNotifications = false
    @State private var localNetworkRequested: Bool
    @State private var restartRequired = false

    private var requiredSetupComplete: Bool {
        accessibilityGranted && inputMonitoringGranted && localNetworkRequested && !restartRequired
    }

    init(
        refreshMediaPermissions: @escaping @MainActor () -> Void,
        showPermissionCompanion: @escaping @MainActor (PermissionOnboardingCompanionPermission) -> Void,
        hidePermissionCompanion: @escaping @MainActor () -> Void,
        startLocalNetworkFeatures: @escaping @MainActor () -> Void,
        localNetworkAlreadyRequested: Bool,
        requireRestart: @escaping @MainActor () -> Void,
        reopenForPermissionRestart: @escaping @MainActor () -> Void,
        finish: @escaping @MainActor () -> Void,
        skip: @escaping @MainActor () -> Void
    ) {
        self.refreshMediaPermissions = refreshMediaPermissions
        self.showPermissionCompanion = showPermissionCompanion
        self.hidePermissionCompanion = hidePermissionCompanion
        self.startLocalNetworkFeatures = startLocalNetworkFeatures
        self.requireRestart = requireRestart
        self.reopenForPermissionRestart = reopenForPermissionRestart
        self.finish = finish
        self.skip = skip
        _localNetworkRequested = State(initialValue: localNetworkAlreadyRequested)
    }

    private var notificationsGranted: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                Text("Set Up Keyway")
                    .font(.system(size: 24, weight: .bold))
                Text("Keyway needs a few permissions to control playback with your media keys. It notices each one as soon as you allow it in System Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 40)
            .padding(.bottom, 24)

            VStack(spacing: 0) {
                PermissionOnboardingRow(
                    systemImage: "accessibility",
                    tint: .blue,
                    title: "Accessibility",
                    detail: "Lets Keyway intercept media keys before the foreground app handles them.",
                    granted: accessibilityGranted,
                    actionTitle: "Grant",
                    actionDisabled: accessibilityGranted,
                    action: requestAccessibility
                )
                .accessibilityIdentifier("onboarding.permission.accessibility")

                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.leading, 56)

                PermissionOnboardingRow(
                    systemImage: "keyboard",
                    tint: .gray,
                    title: "Input Monitoring",
                    detail: "Lets Keyway receive media-key events. Keyway may need to reopen after this changes.",
                    granted: inputMonitoringGranted,
                    actionTitle: "Grant",
                    actionDisabled: inputMonitoringGranted,
                    action: requestInputMonitoring
                )
                .accessibilityIdentifier("onboarding.permission.input-monitoring")

                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.leading, 56)

                PermissionOnboardingRow(
                    systemImage: "network",
                    tint: .teal,
                    title: "Local Network",
                    detail: "Lets Keyway discover and control Sonos speakers on this network.",
                    granted: localNetworkRequested,
                    statusTitle: "Requested",
                    actionTitle: "Allow",
                    actionDisabled: localNetworkRequested,
                    action: requestLocalNetwork
                )
                .accessibilityIdentifier("onboarding.permission.local-network")

                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.leading, 56)

                PermissionOnboardingRow(
                    systemImage: "bell.badge.fill",
                    tint: .red,
                    title: "Speaker Suggestions",
                    detail: "Notifies you when Keyway has a useful speaker or playback suggestion.",
                    optional: true,
                    granted: notificationsGranted,
                    actionTitle: notificationActionTitle,
                    actionDisabled: !hasCheckedNotificationAuthorization
                        || isRequestingNotifications
                        || notificationsGranted,
                    action: handleNotificationAction
                )
                .accessibilityIdentifier("onboarding.permission.notifications")
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.40), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.30), radius: 20, y: 10)

            Text("Spotify sign-in is configured separately when you first use its connected features.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .padding(.horizontal, 4)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Set Up Later", action: skip)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                if restartRequired {
                    Label("Reopen Keyway to activate the new permission.", systemImage: "arrow.clockwise.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Button("Reopen Keyway", action: reopenForPermissionRestart)
                        .buttonStyle(PermissionOnboardingGlassButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else if requiredSetupComplete {
                    Label("Core setup ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)

                    Button("Finish Setup", action: finish)
                        .buttonStyle(PermissionOnboardingGlassButtonStyle(prominent: true))
                        .disabled(!requiredSetupComplete)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.finish")
                } else {
                    Text("Complete the three required steps to finish.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Button("Finish Setup", action: finish)
                        .buttonStyle(PermissionOnboardingGlassButtonStyle(prominent: true))
                        .disabled(!requiredSetupComplete)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.finish")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: Self.preferredWindowSize.width, height: Self.preferredWindowSize.height)
        .background {
            ZStack {
                PermissionOnboardingGlass()
                Circle().fill(Color.blue).frame(width: 340).blur(radius: 90).opacity(0.55).offset(x: -220, y: -170)
                Circle().fill(Color.purple).frame(width: 300).blur(radius: 100).opacity(0.45).offset(x: 230, y: 40)
                Circle().fill(Color.teal).frame(width: 260).blur(radius: 90).opacity(0.35).offset(x: -120, y: 260)
            }
            .ignoresSafeArea()
        }
        .task {
            refreshNotificationState()
        }
        .onReceive(Timer.publish(every: Self.mediaPermissionRefreshInterval, on: .main, in: .default).autoconnect()) { _ in
            refreshMediaPermissionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMediaPermissionState()
            refreshNotificationState()
        }
    }

    private var notificationActionTitle: String {
        guard hasCheckedNotificationAuthorization else {
            return "Checking…"
        }
        if isRequestingNotifications {
            return "Requesting…"
        }

        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Granted"
        case .notDetermined:
            return "Allow"
        case .denied:
            return "Open Settings"
        @unknown default:
            return "Open Settings"
        }
    }

    private func requestAccessibility() {
        showPermissionCompanion(.accessibility)
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        refreshMediaPermissionState()
    }

    private func requestInputMonitoring() {
        showPermissionCompanion(.inputMonitoring)
        NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
        refreshMediaPermissionState()
    }

    private func requestLocalNetwork() {
        hidePermissionCompanion()
        localNetworkRequested = true
        startLocalNetworkFeatures()
    }

    private func handleNotificationAction() {
        switch notificationAuthorizationStatus {
        case .notDetermined:
            isRequestingNotifications = true
            PlaybackSuggestionNotificationAuthorization.requestFromSettings(
                notificationCenter: .current(),
                logger: Self.logger
            ) { granted in
                Task { @MainActor in
                    isRequestingNotifications = false
                    if granted {
                        hidePermissionCompanion()
                    } else {
                        showPermissionCompanion(.notifications)
                        NSWorkspace.shared.open(Self.notificationSettingsURL)
                    }
                    refreshNotificationState()
                }
            }
        case .denied:
            showPermissionCompanion(.notifications)
            NSWorkspace.shared.open(Self.notificationSettingsURL)
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            showPermissionCompanion(.notifications)
            NSWorkspace.shared.open(Self.notificationSettingsURL)
        }
    }

    private func refreshMediaPermissionState() {
        let wasReady = requiredSetupComplete
        let wasAccessibilityGranted = accessibilityGranted
        let wasInputMonitoringGranted = inputMonitoringGranted
        let accessibilityGranted = AccessibilityPermission.isGranted()
        let inputMonitoringGranted = CGPreflightListenEventAccess()
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        if (!wasAccessibilityGranted && accessibilityGranted)
            || (!wasInputMonitoringGranted && inputMonitoringGranted)
        {
            restartRequired = true
            requireRestart()
            hidePermissionCompanion()
        }
        if !wasReady, requiredSetupComplete {
            refreshMediaPermissions()
        }
    }

    private func refreshNotificationState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                notificationAuthorizationStatus = status
                hasCheckedNotificationAuthorization = true
            }
        }
    }
}

private struct PermissionOnboardingGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct PermissionOnboardingGlassButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(prominent ? Color.accentColor.opacity(0.85) : .white.opacity(0.10))
            }
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: (prominent ? Color.accentColor : .black).opacity(0.35), radius: 8, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

private struct PermissionOnboardingRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    var optional = false
    let granted: Bool
    var statusTitle = "Allowed"
    let actionTitle: String
    let actionDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .top, endPoint: .center),
                            lineWidth: 0.75
                        )
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if optional {
                        Text("Optional")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if granted {
                Label(statusTitle, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(PermissionOnboardingGlassButtonStyle())
                    .disabled(actionDisabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
