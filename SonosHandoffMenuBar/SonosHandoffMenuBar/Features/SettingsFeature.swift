import AppKit
import os
import SonosHandoffCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
struct SettingsFeature: View {
    static let menuTitle = "Settings"
    static let preferredWindowSize = CGSize(width: 720, height: 680)
    private static let callbackURLText = SpotifyAuthCoordinator.callbackPorts
        .map { "http://\(SpotifyAuthCoordinator.callbackHost):\($0)\(SpotifyAuthCoordinator.callbackPath)" }
        .joined(separator: "\n")
    private static let panelCornerRadius: CGFloat = 12
    private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Settings")
    private let configStore: ConfigStoring
    private let tokenStore: TokenStoring
    private let connectTokenStatusStore: ConnectTokenStatusChecking
    private let authCoordinator: SpotifyAuthCoordinating
    private let accessibilityAutomator: AccessibilityAutomating
    private let configImportService: ConfigImportService
    @ObservedObject private var mediaRemoteController: MediaRemoteController

    @State private var spotifyClientID = ""
    @State private var isSpotifyAuthenticated = false
    @State private var desktopTokenAvailable = false
    @State private var webAPITokenAvailable = false
    @State private var authMessage: String?
    @State private var isSigningIn = false
    @State private var hasCheckedSpotifyAuthentication = false
    @State private var showSpotifyAdvanced = false

    @State private var accessibilityGranted = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationAlertSetting: UNNotificationSetting = .notSupported
    @State private var notificationCenterSetting: UNNotificationSetting = .notSupported
    @State private var notificationAlertStyle: UNAlertStyle = .none
    @State private var hasCheckedNotificationAuthorization = false
    @State private var isRequestingNotifications = false
    @State private var notificationSettingsFallbackAvailable = false
    @State private var notificationMessage: String?
    @State private var configImportReport: ConfigImportReport?

    init(
        configStore: ConfigStoring = ConfigStore(),
        tokenStore: TokenStoring = KeychainTokenStore(),
        connectTokenStatusStore: ConnectTokenStatusChecking = ConnectTokenStatusStore(),
        authCoordinator: SpotifyAuthCoordinating? = nil,
        accessibilityAutomator: AccessibilityAutomating = SpotifyUIAutomator(),
        configImportService: ConfigImportService = ConfigImportService(),
        initialConfigImportReport: ConfigImportReport? = nil,
        mediaRemoteController: MediaRemoteController = MediaRemoteController()
    ) {
        self.configStore = configStore
        self.tokenStore = tokenStore
        self.connectTokenStatusStore = connectTokenStatusStore
        self.accessibilityAutomator = accessibilityAutomator
        self.configImportService = configImportService
        self.authCoordinator = authCoordinator ?? SpotifyAuthCoordinator(
            tokenStore: tokenStore,
            configStore: configStore,
            browserOpener: { NSWorkspace.shared.open($0) }
        )
        _configImportReport = State(initialValue: initialConfigImportReport)
        _mediaRemoteController = ObservedObject(wrappedValue: mediaRemoteController)
    }

    @State private var selectedSection: String = "General"

    var body: some View {
        HStack(spacing: 0) {
            sidebarList
                .frame(width: 180)
                .background(Color.primary.opacity(0.02))

            Divider()

            ScrollView {
                sidebarDetailContent
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: Self.preferredWindowSize.width)
        .frame(minHeight: Self.preferredWindowSize.height)
        .task {
            await reloadState()
        }
        .onDisappear {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(sidebarSections, id: \.self) { name in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedSection = name
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sidebarIcon(for: name))
                                .font(.system(size: 12))
                                .frame(width: 18)
                            Text(name)
                                .font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            selectedSection == name
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(selectedSection == name ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private var sidebarSections: [String] {
        ["General", "Transport", "Overlay", "Audio", "Sonos", "Spotify", "Shortcuts", "Permissions", "Helper", "Diagnostics"]
    }

    private func sidebarIcon(for section: String) -> String {
        switch section {
        case "General": return "slider.horizontal.3"
        case "Transport": return "arrow.triangle.branch"
        case "Overlay": return "rectangle.center.inset.filled"
        case "Audio": return "speaker.wave.2"
        case "Sonos": return "hifispeaker"
        case "Spotify": return "music.note"
        case "Shortcuts": return "keyboard"
        case "Permissions": return "lock.shield"
        case "Helper": return "terminal"
        case "Diagnostics": return "stethoscope"
        default: return "questionmark"
        }
    }

    @ViewBuilder
    private var sidebarDetailContent: some View {
        switch selectedSection {
        case "General": generalSection
        case "Transport": transportRoutingSection
        case "Overlay": overlaySection
        case "Audio": audioControlsSection
        case "Sonos": sonosSection
        case "Spotify": spotifySection
        case "Shortcuts": shortcutsSection
        case "Permissions": permissionsSection
        case "Helper": helperStatusSection
        case "Diagnostics": diagnosticsSection
        default: generalSection
        }
    }

    private var generalSection: some View {
        settingsPanel(title: "General") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    StatusBadge(
                        title: configImportBadgeTitle,
                        available: !(configImportReport?.hasFailures ?? false) && !(configImportReport?.hasConflicts ?? false)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local app state")
                            .font(.system(size: 13, weight: .medium))
                        Text(configImportSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .layoutPriority(1)

                    Spacer()

                    Button("Run Import") {
                        runConfigImport()
                    }
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 5) {
                    settingsPathRow(title: "Keyway", url: ConfigPaths.applicationSupportDirectory)
                    settingsPathRow(title: "Legacy", url: ConfigPaths.legacyApplicationSupportDirectory)
                }
            }
        }
    }

    private var transportRoutingSection: some View {
        settingsPanel(title: "Transport Routing") {
            serviceStatusRow(
                title: "Media keys",
                available: accessibilityGranted,
                availableText: "Play/Pause, Next, Previous",
                missingText: "Accessibility required"
            )
            Text("Routing policy: Focused Target, Pinned Target, Recent Target, chooser.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var overlaySection: some View {
        settingsPanel(title: "Overlay") {
            HStack(spacing: 8) {
                StatusDot(available: true, size: 7)
                Text("Centered on the display containing the mouse pointer")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Up/Down, Enter, Escape, Tab, 1-9, P")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var audioControlsSection: some View {
        settingsPanel(title: "Audio Controls") {
            VStack(alignment: .leading, spacing: 7) {
                serviceStatusRow(title: "Sonos", available: true, availableText: "Volume and mute", missingText: "")
                serviceStatusRow(title: "Spotify", available: webAPITokenAvailable, availableText: "Active Device Volume", missingText: "Sign in required")
                serviceStatusRow(title: "Browser", available: false, availableText: "", missingText: "Volume disabled without browser extension")
            }
        }
    }

    private var sonosSection: some View {
        settingsPanel(title: "Sonos") {
            VStack(alignment: .leading, spacing: 7) {
                serviceStatusRow(title: "Discovery", available: true, availableText: "Enabled", missingText: "")
                serviceStatusRow(title: "Handoff", available: isSpotifyAuthenticated, availableText: "Ready", missingText: "Token files required")
                serviceStatusRow(title: "Volume", available: true, availableText: "Enabled", missingText: "")
            }
        }
    }

    private var spotifySection: some View {
        settingsPanel(title: "Spotify") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    readinessRow
                    Spacer()
                    spotifyAuthActionButton
                }

                HStack(spacing: 8) {
                    Button("Check") {
                        Task {
                            await reloadSpotifyAuthState()
                        }
                    }
                    .controlSize(.small)
                    .disabled(isSigningIn)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showSpotifyAdvanced.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Advanced")
                            Image(systemName: showSpotifyAdvanced ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                if showSpotifyAdvanced {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Client ID")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("Spotify Client ID", text: $spotifyClientID)
                                .font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .accessibilityIdentifier("settings.spotify.clientID")
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                }

                            Button("Save") {
                                _ = saveSpotifyClientID(showMessage: true)
                            }
                            .controlSize(.small)
                            .disabled(isSigningIn)
                            .accessibilityIdentifier("settings.spotify.saveClientID")
                        }

                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.left")
                                .font(.system(size: 10, weight: .medium))
                            Text(Self.callbackURLText)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(alignment: .leading, spacing: 7) {
                    serviceStatusRow(
                        title: "Desktop Connect",
                        available: desktopTokenAvailable,
                        availableText: "Token present",
                        missingText: "Token missing"
                    )
                    serviceStatusRow(
                        title: "Web API",
                        available: webAPITokenAvailable,
                        availableText: "Sign-in valid",
                        missingText: "Sign in again"
                    )
                }

                if let authMessage {
                    Text(authMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var spotifyAuthActionButton: some View {
        if webAPITokenAvailable {
            Button("Sign Out") {
                signOutSpotify()
            }
            .controlSize(.small)
            .disabled(isSigningIn)
        } else {
            Button(isSigningIn ? "Signing In..." : "Sign In") {
                startSpotifySignIn()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isSigningIn)
        }
    }

    private var shortcutsSection: some View {
        settingsPanel(title: "Shortcuts") {
            HStack(alignment: .center, spacing: 10) {
                StatusBadge(
                    title: accessibilityGranted ? "Enabled" : "Required",
                    available: accessibilityGranted
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global keyboard control")
                        .font(.system(size: 13, weight: .medium))
                    Text(accessibilityGranted ? "Keyboard routing can listen in the background." : "Required for media-key routing and expanded control shortcuts.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)

                Spacer()

                Button("Refresh") {
                    refreshShortcutState()
                }
                .controlSize(.small)

                Button("Open Settings") {
                    AccessibilityPermission.requestPrompt()
                    refreshShortcutState()
                    NSWorkspace.shared.open(accessibilitySettingsURL)
                }
                .controlSize(.small)
            }
        }
    }

    private var permissionsSection: some View {
        settingsPanel(title: "Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    StatusBadge(
                        title: accessibilityGranted ? "Enabled" : "Required",
                        available: accessibilityGranted
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 13, weight: .medium))
                        Text(accessibilityGranted ? "Keyway can intercept keyboard events." : "Enable Accessibility for Keyway in System Settings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        AccessibilityPermission.requestPrompt()
                        refreshShortcutState()
                        NSWorkspace.shared.open(accessibilitySettingsURL)
                    }
                    .controlSize(.small)
                }

                HStack(alignment: .center, spacing: 10) {
                    StatusBadge(
                        title: notificationBadgeTitle,
                        available: notificationsEnabled
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speaker suggestions")
                            .font(.system(size: 13, weight: .medium))
                        Text(notificationDetailText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .layoutPriority(1)

                    Spacer()

                    Button("Refresh") {
                        refreshNotificationState()
                    }
                    .controlSize(.small)
                    .disabled(isRequestingNotifications)

                    if showsNotificationAction {
                        Button(notificationActionTitle) {
                            handleNotificationAction()
                        }
                        .controlSize(.small)
                        .disabled(isRequestingNotifications)
                    }
                }

                if let notificationMessage {
                    Text(notificationMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var helperStatusSection: some View {
        settingsPanel(title: "Helper Status") {
            HStack(alignment: .top, spacing: 10) {
                StatusBadge(
                    title: mediaRemoteController.health.badgeTitle,
                    available: mediaRemoteController.health.isHealthy
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("MediaRemote helper")
                        .font(.system(size: 13, weight: .medium))
                    Text(mediaRemoteController.health.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(helperStatusDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .layoutPriority(1)

                Spacer()

                Button("Restart") {
                    mediaRemoteController.restart()
                }
                .controlSize(.small)
            }
        }
    }

    private var diagnosticsSection: some View {
        settingsPanel(title: "Diagnostics") {
            VStack(alignment: .leading, spacing: 7) {
                if let configImportReport {
                    ForEach(configImportReport.fileResults, id: \.file.rawValue) { result in
                        settingsDiagnosticRow(title: result.file.fileName, detail: fileStatusText(result.status))
                    }
                    settingsDiagnosticRow(title: "spotify keychain", detail: keychainStatusText(configImportReport.keychainStatus))
                    settingsDiagnosticRow(title: "media targets", detail: "\(mediaRemoteController.targets.count)")
                } else {
                    Text("No diagnostics recorded yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var readinessRow: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(available: isSpotifyAuthenticated)

            VStack(alignment: .leading, spacing: 2) {
                Text(spotifyAuthStatusText)
                    .font(.system(size: 14, weight: .semibold))
                Text(spotifyAuthDetailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsPanel<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func serviceStatusRow(
        title: String,
        available: Bool,
        availableText: String,
        missingText: String
    ) -> some View {
        HStack(spacing: 8) {
            StatusDot(available: available, size: 7)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
            Spacer()
            Text(available ? availableText : missingText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func settingsPathRow(title: String, url: URL) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 48, alignment: .leading)
            Text(url.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func settingsDiagnosticRow(title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
            Spacer()
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var spotifyAuthStatusText: String {
        if isSpotifyAuthenticated {
            return "Ready for Sonos handoff"
        }

        if hasCheckedSpotifyAuthentication {
            return "Missing Sonos handoff token files"
        }

        return "Authentication not checked"
    }

    private var spotifyAuthDetailText: String {
        if isSpotifyAuthenticated {
            return "Spotify Desktop Connect and Web API tokens are available."
        }

        if hasCheckedSpotifyAuthentication {
            return "Sign in again if Spotify control stops syncing."
        }

        return "Checking token files..."
    }

    private var configImportBadgeTitle: String {
        guard let configImportReport else {
            return "Not Run"
        }

        if configImportReport.hasFailures {
            return "Failed"
        }

        if configImportReport.hasConflicts {
            return "Conflict"
        }

        return configImportReport.copiedCount > 0 ? "Imported" : "Ready"
    }

    private var configImportSummary: String {
        guard let configImportReport else {
            return "Keyway will copy old Sonos Handoff config and token files into its own support directory."
        }

        if configImportReport.hasConflicts {
            return "Import found existing Keyway files that differ from old Sonos Handoff files. Keyway did not overwrite them."
        }

        if configImportReport.hasFailures {
            return "Import hit an error. Check Diagnostics and re-run import after fixing the file or Keychain access issue."
        }

        if configImportReport.copiedCount > 0 {
            return "Copied \(configImportReport.copiedCount) legacy item\(configImportReport.copiedCount == 1 ? "" : "s") into Keyway without modifying old Sonos Handoff files."
        }

        return "No legacy items needed copying, or the Keyway copies already match."
    }

    private var helperStatusDetail: String {
        let pid = mediaRemoteController.health.pid.map(String.init) ?? "none"
        let targetCount = mediaRemoteController.health.targetCount
        if let lastSnapshotAt = mediaRemoteController.health.lastSnapshotAt {
            return "pid=\(pid) targets=\(targetCount) snapshot=\(lastSnapshotAt.formatted(date: .omitted, time: .standard))"
        }
        return "pid=\(pid) targets=\(targetCount) snapshot=none"
    }

    private var notificationsEnabled: Bool {
        notificationPermissionViewState == .enabled
    }

    private var notificationBadgeTitle: String {
        switch notificationPermissionViewState {
        case .checking:
            return "Checking"
        case .enabled:
            return "Enabled"
        case .notAsked:
            return "Not Asked"
        case .off:
            return "Off"
        case .unknown:
            return "Unknown"
        }
    }

    private var notificationDetailText: String {
        switch notificationPermissionViewState {
        case .checking:
            return "Checking notification permission."
        case .enabled:
            return "Speaker suggestion banners can be delivered."
        case .notAsked:
            return "Click Enable to ask macOS for notification permission."
        case .off:
            return "Turn on Sonos Handoff notifications in System Settings."
        case .unknown:
            return "Notification permission is unavailable."
        }
    }

    private var showsNotificationAction: Bool {
        hasCheckedNotificationAuthorization && !notificationsEnabled
    }

    private var notificationActionTitle: String {
        switch notificationPermissionViewState {
        case .notAsked:
            if isRequestingNotifications {
                return "Enabling..."
            }

            return "Enable"
        case .off, .unknown, .checking, .enabled:
            return "Open Settings"
        }
    }

    private var notificationPermissionViewState: NotificationPermissionViewState {
        guard hasCheckedNotificationAuthorization else {
            return .checking
        }

        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return notificationDeliverySettingsEnabled ? .enabled : .off
        case .notDetermined:
            return notificationSettingsFallbackAvailable ? .off : .notAsked
        case .denied:
            return .off
        @unknown default:
            return .unknown
        }
    }

    private var notificationDeliverySettingsEnabled: Bool {
        notificationSettingAllowsDelivery(notificationAlertSetting) && notificationAlertStyle != .none
    }

    private func notificationSettingAllowsDelivery(_ setting: UNNotificationSetting) -> Bool {
        switch setting {
        case .enabled, .notSupported:
            return true
        case .disabled:
            return false
        @unknown default:
            return false
        }
    }

    private func reloadState() async {
        refreshAccessibilityState()
        refreshNotificationState()
        await reloadSpotifyAuthState()

        do {
            let config = try configStore.load()
            spotifyClientID = config.spotifyClientID ?? ""
        } catch {
            authMessage = "Could not load settings."
        }
    }

    private func runConfigImport() {
        configImportReport = configImportService.importLegacyState()
        Task {
            await reloadSpotifyAuthState()
        }
    }

    private func reloadSpotifyAuthState() async {
        let tokenStatus = await connectTokenStatusStore.validatedStatus()
        desktopTokenAvailable = tokenStatus.desktopTokenAvailable
        webAPITokenAvailable = tokenStatus.projectTokenAvailable
        isSpotifyAuthenticated = tokenStatus.isReadyForHandoff
        hasCheckedSpotifyAuthentication = true
    }

    private func refreshAccessibilityState() {
        accessibilityGranted = accessibilityAutomator.checkAccessibilityPermission()
    }

    private func refreshShortcutState() {
        refreshAccessibilityState()
        NotificationCenter.default.post(name: .sonosHandoffRefreshHotkeys, object: nil)
    }

    private func refreshNotificationState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            let alertSetting = settings.alertSetting
            let notificationCenterSetting = settings.notificationCenterSetting
            let alertStyle = settings.alertStyle
            Task { @MainActor in
                notificationAuthorizationStatus = status
                notificationAlertSetting = alertSetting
                self.notificationCenterSetting = notificationCenterSetting
                notificationAlertStyle = alertStyle
                hasCheckedNotificationAuthorization = true
                if status != .notDetermined {
                    notificationSettingsFallbackAvailable = false
                }
                logger.info("SonosHandoffNotificationSettings status=\(status.rawValue, privacy: .public) alert=\(alertSetting.rawValue, privacy: .public) center=\(notificationCenterSetting.rawValue, privacy: .public) style=\(alertStyle.rawValue, privacy: .public)")
            }
        }
    }

    private func handleNotificationAction() {
        switch notificationPermissionViewState {
        case .notAsked:
            requestNotificationPermission()
        case .off, .unknown, .checking, .enabled:
            openNotificationSettings()
        }
    }

    private func requestNotificationPermission() {
        isRequestingNotifications = true
        notificationMessage = nil
        PlaybackSuggestionNotificationAuthorization.requestFromSettings(
            notificationCenter: .current(),
            logger: logger
        ) { granted in
            Task { @MainActor in
                isRequestingNotifications = false
                if granted {
                    notificationMessage = "Notifications enabled."
                    notificationSettingsFallbackAvailable = false
                } else {
                    notificationMessage = "Enable notifications in System Settings."
                    notificationSettingsFallbackAvailable = true
                    openNotificationSettings()
                }
                refreshNotificationState()
            }
        }
    }

    private func openNotificationSettings() {
        NSWorkspace.shared.open(notificationSettingsURL)
    }

    private static let spotifyClientIDPattern = /^[0-9a-f]{32}$/

    private func saveSpotifyClientID(showMessage: Bool) -> Bool {
        let trimmedClientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)

        if let id = trimmedClientID.nilIfEmpty, id.wholeMatch(of: Self.spotifyClientIDPattern) == nil {
            authMessage = "Invalid Client ID format. Expected 32 hex characters."
            return false
        }

        do {
            let config = try configStore.load()
            guard config.spotifyClientID != trimmedClientID.nilIfEmpty else {
                if showMessage {
                    authMessage = "Spotify Client ID unchanged."
                }
                return true
            }

            try configStore.save(
                AppConfig(
                    spotifyClientID: trimmedClientID.nilIfEmpty,
                    spotifyVirtualDisplayName: config.spotifyVirtualDisplayName
                )
            )
            if showMessage {
                authMessage = trimmedClientID.isEmpty ? "Removed Spotify Client ID." : "Saved Spotify Client ID."
            }
            return true
        } catch {
            authMessage = "Could not save Spotify Client ID."
            return false
        }
    }

    private func startSpotifySignIn() {
        guard saveSpotifyClientID(showMessage: false) else {
            return
        }
        authMessage = nil
        isSigningIn = true
        let authCoordinator = self.authCoordinator

        Task {
            defer { isSigningIn = false }
            do {
                try await authCoordinator.login()
                authMessage = "Spotify Web API sign-in completed. Desktop Connect token is still required for handoff."
            } catch {
                authMessage = error.localizedDescription
            }
            await reloadState()
        }
    }

    private func signOutSpotify() {
        do {
            try tokenStore.deleteRefreshToken()
            try connectTokenStatusStore.deleteProjectToken()
            authMessage = "Removed Spotify sign-in tokens."
            Task { await reloadSpotifyAuthState() }
        } catch {
            authMessage = "Could not remove the Spotify token."
        }
    }

    private func fileStatusText(_ status: ConfigImportFileStatus) -> String {
        switch status {
        case .copied:
            return "copied"
        case .missingLegacyFile:
            return "not found in legacy dir"
        case .alreadyImported:
            return "already imported"
        case .conflict:
            return "different existing Keyway file"
        case .failed(let message):
            return "failed: \(message)"
        }
    }

    private func keychainStatusText(_ status: ConfigImportKeychainStatus) -> String {
        switch status {
        case .copied:
            return "copied"
        case .missingLegacyToken:
            return "not found in legacy keychain"
        case .alreadyImported:
            return "already imported"
        case .failed(let message):
            return "failed: \(message)"
        }
    }
}

private enum NotificationPermissionViewState {
    case checking
    case enabled
    case notAsked
    case off
    case unknown
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct StatusDot: View {
    let available: Bool
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(available ? Color.green : Color.orange)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct StatusIcon: View {
    let available: Bool

    var body: some View {
        Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(available ? Color.green : Color.orange)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

private struct StatusBadge: View {
    let title: String
    let available: Bool

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(available: available, size: 7)
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            Capsule(style: .continuous)
                .fill((available ? Color.green : Color.orange).opacity(0.12))
        }
        .foregroundStyle(available ? Color.green : Color.orange)
    }
}
