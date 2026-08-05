import AppKit
import os
import SonosHandoffCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
struct PermissionOnboardingFeature: View {
    static let preferredWindowSize = CGSize(width: 620, height: 710)

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
    let quitForPermissionRestart: @MainActor () -> Void
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
        quitForPermissionRestart: @escaping @MainActor () -> Void,
        finish: @escaping @MainActor () -> Void,
        skip: @escaping @MainActor () -> Void
    ) {
        self.refreshMediaPermissions = refreshMediaPermissions
        self.showPermissionCompanion = showPermissionCompanion
        self.hidePermissionCompanion = hidePermissionCompanion
        self.startLocalNetworkFeatures = startLocalNetworkFeatures
        self.requireRestart = requireRestart
        self.quitForPermissionRestart = quitForPermissionRestart
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
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 58, height: 58)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Finish setting up Keyway")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Grant each permission deliberately. Keyway checks the result when you return from System Settings.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                PermissionOnboardingRow(
                    systemImage: "accessibility",
                    title: "Accessibility",
                    detail: "Lets Keyway intercept media keys before the foreground app handles them.",
                    requirement: "Required",
                    granted: accessibilityGranted,
                    actionTitle: accessibilityGranted ? "Granted" : "Grant",
                    actionDisabled: accessibilityGranted,
                    action: requestAccessibility
                )
                .accessibilityIdentifier("onboarding.permission.accessibility")

                PermissionOnboardingRow(
                    systemImage: "keyboard.badge.ellipsis",
                    title: "Input Monitoring",
                    detail: "Lets Keyway receive media-key events. macOS may require Keyway to be reopened after this changes.",
                    requirement: "Required",
                    granted: inputMonitoringGranted,
                    actionTitle: inputMonitoringGranted ? "Granted" : "Grant",
                    actionDisabled: inputMonitoringGranted,
                    action: requestInputMonitoring
                )
                .accessibilityIdentifier("onboarding.permission.input-monitoring")

                PermissionOnboardingRow(
                    systemImage: "network",
                    title: "Local Network",
                    detail: "Lets Keyway discover and control Sonos speakers on this network.",
                    requirement: "Required",
                    granted: localNetworkRequested,
                    statusTitle: localNetworkRequested ? "Requested" : "Not requested",
                    actionTitle: localNetworkRequested ? "Requested" : "Allow",
                    actionDisabled: localNetworkRequested,
                    action: requestLocalNetwork
                )
                .accessibilityIdentifier("onboarding.permission.local-network")

                PermissionOnboardingRow(
                    systemImage: "bell.badge",
                    title: "Speaker suggestions",
                    detail: "Allows optional notifications when Keyway has a useful speaker or playback suggestion.",
                    requirement: "Optional",
                    granted: notificationsGranted,
                    actionTitle: notificationActionTitle,
                    actionDisabled: !hasCheckedNotificationAuthorization
                        || isRequestingNotifications
                        || notificationsGranted,
                    action: handleNotificationAction
                )
                .accessibilityIdentifier("onboarding.permission.notifications")
            }

            Text("Spotify sign-in is configured separately when you first use its connected features.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 14) {
                Button("Set Up Later", action: skip)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                if restartRequired {
                    Label("Reopen Keyway to activate the new permission.", systemImage: "arrow.clockwise.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)

                    Button("Quit Keyway", action: quitForPermissionRestart)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else if requiredSetupComplete {
                    Label("Core setup ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)

                    Button("Finish Setup", action: finish)
                        .buttonStyle(.borderedProminent)
                        .disabled(!requiredSetupComplete)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.finish")
                } else {
                    Text("Complete the three required steps to finish.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Button("Finish Setup", action: finish)
                        .buttonStyle(.borderedProminent)
                        .disabled(!requiredSetupComplete)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.finish")
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: Self.preferredWindowSize.width, height: Self.preferredWindowSize.height)
        .task {
            refreshNotificationState()
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
        AccessibilityPermission.requestPrompt()
        if !AccessibilityPermission.isGranted() {
            NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        }
        refreshMediaPermissionState()
    }

    private func requestInputMonitoring() {
        showPermissionCompanion(.inputMonitoring)
        _ = CGRequestListenEventAccess()
        if !CGPreflightListenEventAccess() {
            NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
        }
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

private struct PermissionOnboardingRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let requirement: String
    let granted: Bool
    var statusTitle: String? = nil
    let actionTitle: String
    let actionDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    (granted ? Color.green : Color.accentColor).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(requirement)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                Label(
                    statusTitle ?? (granted ? "Enabled" : "Not enabled"),
                    systemImage: granted ? "checkmark.circle.fill" : "circle"
                )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(granted ? Color.green : Color.secondary)
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(actionDisabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 91, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}
