import AppKit
import os
import SonosHandoffCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
struct SettingsFeature: View {
    private static let preferredWindowSize = CGSize(width: 720, height: 520)
    private static let callbackURLText = SpotifyAuthCoordinator.callbackPorts
        .map { "http://\(SpotifyAuthCoordinator.callbackHost):\($0)\(SpotifyAuthCoordinator.callbackPath)" }
        .joined(separator: "\n")
    private static let panelCornerRadius: CGFloat = 12
    private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    private let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
    private let chromiumExtensionsURL = URL(string: "chrome://extensions")!
    private let heliumBundleIdentifier = "net.imput.helium"
    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Settings")
    private let configStore: ConfigStoring
    private let tokenStore: TokenStoring
    private let connectTokenStatusStore: ConnectTokenStatusChecking
    private let authCoordinator: SpotifyAuthCoordinating
    private let configImportService: ConfigImportService
    private let chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller
    private let presentBrowserExtensionSetup: @MainActor () -> Void
    @ObservedObject private var mediaRemoteController: MediaRemoteController
    @ObservedObject private var chromiumBrowserExtensionController: ChromiumBrowserExtensionController

    @State private var spotifyClientID = ""
    @State private var desktopTokenAvailable = false
    @State private var webAPITokenAvailable = false
    @State private var spotifyAuthCheckError: String?
    @State private var authMessage: String?
    @State private var isSigningIn = false
    @State private var hasCheckedSpotifyAuthentication = false
    @State private var showSpotifyAdvanced = false

    @State private var accessibilityGranted = false
    @State private var listenEventGranted = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationAlertSetting: UNNotificationSetting = .notSupported
    @State private var notificationCenterSetting: UNNotificationSetting = .notSupported
    @State private var notificationAlertStyle: UNAlertStyle = .none
    @State private var hasCheckedNotificationAuthorization = false
    @State private var isRequestingNotifications = false
    @State private var notificationSettingsFallbackAvailable = false
    @State private var notificationMessage: String?
    @State private var configImportReport: ConfigImportReport?
    @State private var chromiumBridgeMessage: String?

    init(
        configStore: ConfigStoring = ConfigStore(),
        tokenStore: TokenStoring = KeychainTokenStore(),
        connectTokenStatusStore: ConnectTokenStatusChecking = ConnectTokenStatusStore(),
        authCoordinator: SpotifyAuthCoordinating? = nil,
        configImportService: ConfigImportService = ConfigImportService(),
        chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller = ChromiumNativeMessagingHostInstaller(),
        presentBrowserExtensionSetup: @escaping @MainActor () -> Void,
        initialChromiumBridgeMessage: String? = nil,
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    ) {
        self.configStore = configStore
        self.tokenStore = tokenStore
        self.connectTokenStatusStore = connectTokenStatusStore
        self.configImportService = configImportService
        self.chromiumNativeMessagingHostInstaller = chromiumNativeMessagingHostInstaller
        self.presentBrowserExtensionSetup = presentBrowserExtensionSetup
        self.authCoordinator = authCoordinator ?? SpotifyAuthCoordinator(
            tokenStore: tokenStore,
            configStore: configStore,
            browserOpener: { NSWorkspace.shared.open($0) }
        )
        _chromiumBridgeMessage = State(initialValue: initialChromiumBridgeMessage)
        _mediaRemoteController = ObservedObject(wrappedValue: mediaRemoteController)
        _chromiumBrowserExtensionController = ObservedObject(wrappedValue: chromiumBrowserExtensionController)
    }

    @State private var selectedSection: String = "Playback"

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
        .frame(width: Self.preferredWindowSize.width, height: Self.preferredWindowSize.height)
        .task {
            await reloadState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshShortcutState()
            refreshNotificationState()
        }
        .onAppear {
            _ = NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(sidebarSections, id: \.self) { name in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedSection = name
                        }
                    } label: {
                        Label(name, systemImage: sidebarIcon(for: name))
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            selectedSection == name
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(selectedSection == name ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.sidebar.\(name.lowercased())")
                }
            }
            .padding(10)
        }
    }

    private var sidebarSections: [String] {
        ["Playback", "Spotify", "Permissions", "Support"]
    }

    private func sidebarIcon(for section: String) -> String {
        switch section {
        case "Playback":
            return "play.rectangle.on.rectangle"
        case "Spotify":
            return "music.note"
        case "Permissions":
            return "lock.shield"
        case "Support":
            return "wrench.and.screwdriver"
        default:
            return "questionmark"
        }
    }

    @ViewBuilder
    private var sidebarDetailContent: some View {
        switch selectedSection {
        case "Playback":
            VStack(spacing: 12) {
                transportRoutingSection
                overlaySection
                audioControlsSection
                sonosSection
            }
        case "Spotify": spotifySection
        case "Permissions": permissionsSection
        case "Support":
            VStack(spacing: 12) {
                browserSetupSection
                migrationSection
                helperStatusSection
                diagnosticsSection
            }
        default: transportRoutingSection
        }
    }

    private var migrationSection: some View {
        settingsPanel(title: "Migration") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    StatusBadge(
                        title: configImportBadgeTitle,
                        available: configImportBadgeAvailable
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
                }

                VStack(alignment: .leading, spacing: 5) {
                    settingsPathRow(title: "Keyway", url: ConfigPaths.applicationSupportDirectory)
                    settingsPathRow(title: "Legacy", url: ConfigPaths.legacyApplicationSupportDirectory)
                }

                HStack {
                    Spacer()
                    Button("Import Existing Settings") {
                        runConfigImport()
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
    }

    private var transportRoutingSection: some View {
        settingsPanel(title: "Media Control") {
            serviceStatusRow(
                title: "Media keys",
                available: accessibilityGranted && listenEventGranted,
                availableText: "Play/Pause, Next, Previous",
                missingText: accessibilityGranted ? "Input Monitoring required" : "Accessibility required"
            )
            serviceStatusRow(
                title: "Chromium extension",
                available: chromiumBrowserExtensionController.connected,
                availableText: chromiumExtensionStatusText,
                missingText: "Disconnected"
            )
        }
    }

    private var browserSetupSection: some View {
        settingsPanel(title: "Browser Extension") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    StatusDot(available: chromiumBrowserExtensionController.connected, size: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chromium native bridge")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                        Text(
                            chromiumBrowserExtensionController.profileConnections.isEmpty
                                ? "No browser profiles connected"
                                : "\(chromiumBrowserExtensionController.profileConnections.count) browser \(chromiumBrowserExtensionController.profileConnections.count == 1 ? "profile" : "profiles") connected"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        if let chromiumBridgeMessage {
                            Text(chromiumBridgeMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button("Set Up Browsers", action: presentBrowserExtensionSetup)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.browserExtension.setup")

                    Spacer()

                    Button("Repair Bridge") {
                        installChromiumNativeBridge()
                    }
                    .controlSize(.small)
                    Button("Reveal Extension") {
                        revealChromiumExtension()
                    }
                    .controlSize(.small)
                    Button("Open Extensions") {
                        openChromiumExtensionsPage()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var overlaySection: some View {
        settingsPanel(title: "Source Chooser") {
            Text("Click or press Enter to route; with volume controls open, click selects instead. Command-click or Command-Enter opens the selected app or browser tab. Tab shows volume controls.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioControlsSection: some View {
        settingsPanel(title: "Audio Controls") {
            VStack(alignment: .leading, spacing: 7) {
                serviceStatusRow(
                    title: "Spotify",
                    available: spotifyAuthCheckError == nil && webAPITokenAvailable,
                    availableText: "Active Device Volume",
                    missingText: spotifyAuthCheckError == nil ? "Sign in required" : "Status check failed"
                )
                serviceStatusRow(title: "Browser", available: chromiumBrowserExtensionController.connected, availableText: chromiumBrowserAudioStatusText, missingText: "Extension disconnected")
            }
        }
    }

    private var sonosSection: some View {
        settingsPanel(title: "Sonos") {
            VStack(alignment: .leading, spacing: 7) {
                serviceStatusRow(
                    title: "Handoff",
                    available: spotifyAuthCheckError == nil && desktopTokenAvailable && webAPITokenAvailable,
                    availableText: "Ready",
                    missingText: spotifyAuthCheckError == nil ? "Token files required" : "Status check failed"
                )
                Text("Discovery, volume, and mute become available when Keyway finds a speaker on your local network.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var spotifySection: some View {
        settingsPanel(title: "Spotify") {
            VStack(alignment: .leading, spacing: 12) {
                readinessRow

                HStack(spacing: 8) {
                    Button("Refresh Status") {
                        Task {
                            await reloadSpotifyAuthState()
                        }
                    }
                    .controlSize(.small)
                    .disabled(isSigningIn)

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

                    Spacer()

                    spotifyAuthActionButton
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
                        available: spotifyAuthCheckError == nil && desktopTokenAvailable,
                        availableText: "Token present",
                        missingText: spotifyAuthCheckError == nil ? "Token missing" : "Check failed"
                    )
                    serviceStatusRow(
                        title: "Web API",
                        available: spotifyAuthCheckError == nil && webAPITokenAvailable,
                        availableText: "Sign-in valid",
                        missingText: spotifyAuthCheckError == nil ? "Sign in again" : "Check failed"
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
            Button(isSigningIn ? "Signing In..." : "Sign In to Web API") {
                startSpotifySignIn()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isSigningIn)
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
                        title: listenEventGranted ? "Enabled" : "Required",
                        available: listenEventGranted
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Input Monitoring")
                            .font(.system(size: 13, weight: .medium))
                        Text(listenEventGranted ? "Keyway can receive media-key events." : "Enable Input Monitoring for media-key routing.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        _ = CGRequestListenEventAccess()
                        refreshShortcutState()
                        NSWorkspace.shared.open(inputMonitoringSettingsURL)
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
                    settingsDiagnosticRow(title: "chromium targets", detail: "\(chromiumBrowserExtensionController.targets.count)")
                }
                if let chromiumBridgeMessage {
                    settingsDiagnosticRow(title: "chromium bridge", detail: chromiumBridgeMessage)
                }
                if configImportReport == nil && chromiumBridgeMessage == nil {
                    Text("No diagnostics recorded yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var readinessRow: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(available: spotifyAuthCheckError == nil && desktopTokenAvailable && webAPITokenAvailable)

            VStack(alignment: .leading, spacing: 2) {
                Text(spotifyAuthStatusText)
                    .font(.system(size: 14, weight: .semibold))
                Text(spotifyAuthDetailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
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
                .font(.system(size: 15, weight: .semibold))

            content()
        }
        .padding(16)
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
        if spotifyAuthCheckError != nil {
            return "Spotify status check failed"
        }

        if desktopTokenAvailable && webAPITokenAvailable {
            return "Ready for Sonos handoff"
        }

        guard hasCheckedSpotifyAuthentication else {
            return "Authentication not checked"
        }

        if webAPITokenAvailable {
            return "Desktop Connect token missing"
        }

        if desktopTokenAvailable {
            return "Spotify Web API sign-in required"
        }

        return "Spotify setup incomplete"
    }

    private var spotifyAuthDetailText: String {
        if let spotifyAuthCheckError {
            return "Could not verify Spotify credentials: \(spotifyAuthCheckError)"
        }

        if desktopTokenAvailable && webAPITokenAvailable {
            return "Spotify Desktop Connect and Web API tokens are available."
        }

        guard hasCheckedSpotifyAuthentication else {
            return "Checking token files..."
        }

        if webAPITokenAvailable {
            return "Web API sign-in is valid. Copy the Desktop Connect token from a working Keyway Mac to enable Sonos handoff."
        }

        if desktopTokenAvailable {
            return "Desktop Connect is ready. Sign in for Spotify playback verification and volume sync."
        }

        return "Sign in for Web API access, then copy the Desktop Connect token from a working Keyway Mac."
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

    private var configImportBadgeAvailable: Bool {
        guard let configImportReport else {
            return false
        }

        return !configImportReport.hasFailures && !configImportReport.hasConflicts
    }

    private var configImportSummary: String {
        guard let configImportReport else {
            return "Config import has not run yet. Keyway will copy old Sonos Handoff config and token files into its own support directory."
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

    private var chromiumExtensionStatusText: String {
        let count = chromiumBrowserExtensionController.targets.count
        return "\(count) media target\(count == 1 ? "" : "s")"
    }

    private var chromiumBrowserAudioStatusText: String {
        chromiumBrowserExtensionController.targets.isEmpty ? "Connected, no media" : "Mute and volume"
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
            return "Turn on Keyway notifications in System Settings."
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
            await reloadState()
        }
    }

    private func installChromiumNativeBridge() {
        do {
            let state = try chromiumNativeMessagingHostInstaller.install()
            chromiumBridgeMessage = "Installed native host manifests in \(state.manifestPaths.count) supported Chromium-family locations."
        } catch {
            chromiumBridgeMessage = "Chromium bridge install failed: \(error.localizedDescription)"
            logger.error("Chromium native bridge install failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func revealChromiumExtension() {
        guard let resourceURL = Bundle.main.resourceURL else {
            chromiumBridgeMessage = "Bundled Chromium extension is missing: app bundle has no resource directory."
            logger.error("Chromium extension reveal failed: Bundle.main.resourceURL is nil")
            return
        }
        let extensionURL = resourceURL.appendingPathComponent("ChromiumExtension", isDirectory: true)
        guard FileManager.default.fileExists(atPath: extensionURL.appendingPathComponent("manifest.json").path) else {
            chromiumBridgeMessage = "Bundled Chromium extension is missing at \(extensionURL.path)"
            logger.error("Chromium extension reveal failed: missing manifest at path=\(extensionURL.path, privacy: .public)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([extensionURL])
        chromiumBridgeMessage = "Revealed bundled Chromium extension folder."
    }

    private func openChromiumExtensionsPage() {
        if let heliumURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: heliumBundleIdentifier) {
            NSWorkspace.shared.open(
                [chromiumExtensionsURL],
                withApplicationAt: heliumURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            chromiumBridgeMessage = "Opened Helium extension settings."
            return
        }
        NSWorkspace.shared.open(chromiumExtensionsURL)
        chromiumBridgeMessage = "Opened Chromium extension settings."
    }

    private func reloadSpotifyAuthState() async {
        do {
            let tokenStatus = try await connectTokenStatusStore.validatedStatus()
            desktopTokenAvailable = tokenStatus.desktopTokenAvailable
            webAPITokenAvailable = tokenStatus.projectTokenAvailable
            spotifyAuthCheckError = nil
        } catch {
            desktopTokenAvailable = false
            webAPITokenAvailable = false
            spotifyAuthCheckError = error.localizedDescription
        }
        hasCheckedSpotifyAuthentication = true
    }

    private func refreshAccessibilityState() {
        accessibilityGranted = AccessibilityPermission.isGranted()
        listenEventGranted = CGPreflightListenEventAccess()
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
        let clientID = trimmedClientID.isEmpty ? nil : trimmedClientID

        if let clientID, clientID.wholeMatch(of: Self.spotifyClientIDPattern) == nil {
            authMessage = "Invalid Client ID format. Expected 32 hex characters."
            return false
        }

        do {
            let config = try configStore.load()
            guard config.spotifyClientID != clientID else {
                if showMessage {
                    authMessage = "Spotify Client ID unchanged."
                }
                return true
            }

            try configStore.save(
                AppConfig(
                    spotifyClientID: clientID
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
            authMessage = "Removed Spotify Web API sign-in tokens."
            Task { await reloadSpotifyAuthState() }
        } catch {
            authMessage = "Could not remove the Spotify Web API token."
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
        .fixedSize(horizontal: true, vertical: false)
    }
}
