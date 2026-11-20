import AppKit
import os
import PermissionCompanionKit
import SonosHandoffCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
struct PermissionOnboardingFeature: View {
    static let preferredWindowSize = CGSize(width: 620, height: 640)
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
    let arrangeBesideSystemSettings: @MainActor () -> Void
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
        arrangeBesideSystemSettings: @escaping @MainActor () -> Void,
        startLocalNetworkFeatures: @escaping @MainActor () -> Void,
        localNetworkAlreadyRequested: Bool,
        requireRestart: @escaping @MainActor () -> Void,
        reopenForPermissionRestart: @escaping @MainActor () -> Void,
        finish: @escaping @MainActor () -> Void,
        skip: @escaping @MainActor () -> Void
    ) {
        self.refreshMediaPermissions = refreshMediaPermissions
        self.arrangeBesideSystemSettings = arrangeBesideSystemSettings
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
        PermissionSetupView(
            steps: [
                PermissionSetupStep(
                    systemImage: "accessibility",
                    title: "Accessibility",
                    detail: "Keyway intercepts media keys before the app in front handles them.",
                    actionTitle: "Open System Settings",
                    privacyService: .accessibility,
                    isComplete: accessibilityGranted,
                    action: requestAccessibility
                ),
                PermissionSetupStep(
                    systemImage: "keyboard",
                    title: "Input Monitoring",
                    detail: "Keyway receives media-key events. macOS may ask Keyway to reopen after you allow it.",
                    actionTitle: "Open System Settings",
                    privacyService: .inputMonitoring,
                    isComplete: inputMonitoringGranted,
                    action: requestInputMonitoring
                ),
                PermissionSetupStep(
                    systemImage: "network",
                    title: "Local Network",
                    detail: "Keyway finds and controls Sonos speakers on this network.",
                    actionTitle: "Allow",
                    isComplete: localNetworkRequested,
                    action: requestLocalNetwork
                ),
                PermissionSetupStep(
                    systemImage: "bell",
                    title: "Speaker Suggestions",
                    detail: "Keyway notifies you when it has a useful speaker or playback suggestion. Spotify sign-in is set up separately when you first use it.",
                    actionTitle: notificationActionTitle,
                    actionEnabled: hasCheckedNotificationAuthorization && !isRequestingNotifications,
                    isOptional: true,
                    isComplete: notificationsGranted,
                    action: handleNotificationAction
                ),
            ],
            status: restartRequired
                ? "Reopen Keyway to activate the new permission."
                : requiredSetupComplete
                    ? "Core setup ready"
                    : "\([accessibilityGranted, inputMonitoringGranted, localNetworkRequested].filter { !$0 }.count) required left",
            primaryTitle: restartRequired ? "Reopen Keyway" : "Finish Setup",
            primaryEnabled: restartRequired || requiredSetupComplete,
            primaryAction: restartRequired ? reopenForPermissionRestart : finish,
            later: skip
        )
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
        arrangeBesideSystemSettings()
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        refreshMediaPermissionState()
    }

    private func requestInputMonitoring() {
        arrangeBesideSystemSettings()
        NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
        refreshMediaPermissionState()
    }

    private func requestLocalNetwork() {
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
                    if !granted {
                        arrangeBesideSystemSettings()
                        NSWorkspace.shared.open(Self.notificationSettingsURL)
                    }
                    refreshNotificationState()
                }
            }
        case .denied:
            arrangeBesideSystemSettings()
            NSWorkspace.shared.open(Self.notificationSettingsURL)
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            arrangeBesideSystemSettings()
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
