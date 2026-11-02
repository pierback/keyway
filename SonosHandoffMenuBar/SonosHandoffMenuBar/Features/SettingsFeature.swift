import AppKit
import os
import SonosHandoffCore
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
struct SettingsFeature: View {
    private static let preferredWindowSize = CGSize(width: 780, height: 560)
    private static let callbackURLText = SpotifyAuthCoordinator.callbackPorts
        .map { "http://\(SpotifyAuthCoordinator.callbackHost):\($0)\(SpotifyAuthCoordinator.callbackPath)" }
        .joined(separator: "\n")
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
    private let chromiumBrowserInstallationAdapter: ChromiumBrowserInstallationAdapter
    private let presentBrowserExtensionSetup: @MainActor () -> Void
    private let checkForUpdates: @MainActor () -> Void
    @ObservedObject private var mediaRemoteController: MediaRemoteController
    @ObservedObject private var chromiumBrowserExtensionController: ChromiumBrowserExtensionController

    @State private var spotifyClientID = ""
    @State private var desktopTokenAvailable = false
    @State private var webAPITokenAvailable = false
    @State private var spotifyAuthCheckError: String?
    @State private var authMessage: String?
    @State private var isSigningIn = false
    @State private var hasCheckedSpotifyAuthentication = false

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
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var isCopyingDiagnostics = false
    @State private var diagnosticsCopied = false
    @AppStorage(AppRuntime.mediaKeysPausedKey) private var mediaKeysPaused = false

    init(
        configStore: ConfigStoring = ConfigStore(),
        tokenStore: TokenStoring = KeychainTokenStore(),
        connectTokenStatusStore: ConnectTokenStatusChecking = ConnectTokenStatusStore(),
        authCoordinator: SpotifyAuthCoordinating? = nil,
        configImportService: ConfigImportService = ConfigImportService(),
        chromiumNativeMessagingHostInstaller: ChromiumNativeMessagingHostInstaller = ChromiumNativeMessagingHostInstaller(),
        chromiumBrowserInstallationAdapter: ChromiumBrowserInstallationAdapter = ChromiumBrowserInstallationAdapter(),
        presentBrowserExtensionSetup: @escaping @MainActor () -> Void,
        checkForUpdates: @escaping @MainActor () -> Void,
        initialChromiumBridgeMessage: String? = nil,
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    ) {
        self.configStore = configStore
        self.tokenStore = tokenStore
        self.connectTokenStatusStore = connectTokenStatusStore
        self.configImportService = configImportService
        self.chromiumNativeMessagingHostInstaller = chromiumNativeMessagingHostInstaller
        self.chromiumBrowserInstallationAdapter = chromiumBrowserInstallationAdapter
        self.presentBrowserExtensionSetup = presentBrowserExtensionSetup
        self.checkForUpdates = checkForUpdates
        self.authCoordinator = authCoordinator ?? SpotifyAuthCoordinator(
            tokenStore: tokenStore,
            configStore: configStore,
            browserOpener: { NSWorkspace.shared.open($0) }
        )
        _chromiumBridgeMessage = State(initialValue: initialChromiumBridgeMessage)
        _mediaRemoteController = ObservedObject(wrappedValue: mediaRemoteController)
        _chromiumBrowserExtensionController = ObservedObject(wrappedValue: chromiumBrowserExtensionController)
    }

    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .tag(pane)
                .accessibilityIdentifier("settings.sidebar.\(pane.rawValue.lowercased())")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch selectedPane {
                case .general: generalPane
                case .shortcuts: shortcutsPane
                case .spotify: spotifyPane
                case .sonos: sonosPane
                case .browsers: browsersPane
                case .permissions: permissionsPane
                case .advanced: advancedPane
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selectedPane.rawValue)
        }
        .frame(width: Self.preferredWindowSize.width, height: Self.preferredWindowSize.height)
        .task {
            await reloadState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshShortcutState()
            refreshNotificationState()
            launchAtLoginStatus = SMAppService.mainApp.status
        }
        .onAppear {
            _ = NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var generalPane: some View {
        Section {
            Toggle(isOn: Binding(
                get: { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval },
                set: { enabled in
                    if enabled {
                        try! SMAppService.mainApp.register()
                    } else {
                        try! SMAppService.mainApp.unregister()
                    }
                    launchAtLoginStatus = SMAppService.mainApp.status
                }
            )) {
                Text("Launch at login")
                Text(launchAtLoginStatus == .requiresApproval
                    ? "Approve Keyway in System Settings → General → Login Items."
                    : "Start Keyway when you log in.")
            }
            .accessibilityIdentifier("settings.general.launchAtLogin")

            Toggle(isOn: Binding(
                get: { !mediaKeysPaused },
                set: { enabled in
                    mediaKeysPaused = !enabled
                    NotificationCenter.default.post(name: .sonosHandoffRefreshHotkeys, object: nil)
                }
            )) {
                Text("Route media keys")
                Text("Turn off to leave Play/Pause, Next and Previous to macOS, e.g. for games or presentations.")
            }
            .accessibilityIdentifier("settings.general.routeMediaKeys")
        }

        Section("Status") {
            LabeledContent("Media keys") {
                StatusLabel(
                    text: mediaKeysPaused
                        ? "Paused"
                        : !accessibilityGranted ? "Accessibility required"
                        : !listenEventGranted ? "Input Monitoring required" : "Ready",
                    available: !mediaKeysPaused && accessibilityGranted && listenEventGranted
                )
            }
            LabeledContent("Browser extension") {
                StatusLabel(
                    text: chromiumBrowserExtensionController.connected ? chromiumExtensionStatusText : "Disconnected",
                    available: chromiumBrowserExtensionController.connected
                )
            }
        }

        Section {
            LabeledContent("Send the command", value: "↵ or click")
            LabeledContent("Pick a row directly", value: "1 – 9")
            LabeledContent("Open the app or tab", value: "⌘↵ or ⌘-click")
            LabeledContent("Volume controls", value: "⇥, then ←→ and M")
        } header: {
            Text("Source Chooser")
        } footer: {
            Text("Command-click or Command-Enter opens the selected app or browser tab.")
        }

        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String)
            LabeledContent("Keyway checks for updates daily.") {
                Button("Check for Updates…", action: checkForUpdates)
                    .accessibilityIdentifier("settings.general.checkForUpdates")
            }
        }
    }

    private var shortcutsPane: some View {
        Section {
            ForEach(GlobalShortcutAction.allCases) { action in
                LabeledContent {
                    ShortcutRecorderField(action: action)
                } label: {
                    Text(action.title)
                    Text(action.detail)
                }
            }
        } footer: {
            Text("Global shortcuts work from any app. Click a field and press the keys; Esc cancels, Delete clears.")
        }
    }

    @ViewBuilder
    private var spotifyPane: some View {
        Section {
            LabeledContent {
                spotifyAuthActionButton
            } label: {
                Label {
                    Text(spotifyAuthStatusText)
                    Text(spotifyAuthDetailText)
                } icon: {
                    StatusLabel(text: "", available: spotifyAuthCheckError == nil && desktopTokenAvailable && webAPITokenAvailable)
                }
            }
        } footer: {
            if let authMessage {
                Text(authMessage)
            }
        }

        Section("Connections") {
            LabeledContent {
                HStack(spacing: 10) {
                    StatusLabel(
                        text: spotifyAuthCheckError != nil ? "Check failed" : desktopTokenAvailable ? "Signed in" : "Sign-in required",
                        available: spotifyAuthCheckError == nil && desktopTokenAvailable
                    )
                    Button(desktopTokenAvailable ? "Sign In Again" : "Sign In") {
                        startSpotifyDesktopSignIn()
                    }
                    .disabled(isSigningIn)
                    .help("Signs in through the Spotify desktop client, which Sonos handoff requires. Not an official Spotify integration.")
                    .accessibilityIdentifier("settings.spotify.desktopSignIn")
                }
            } label: {
                Text("Sonos handoff")
                Text("Desktop Connect token")
            }
            LabeledContent {
                StatusLabel(
                    text: spotifyAuthCheckError != nil ? "Check failed" : webAPITokenAvailable ? "Sign-in valid" : "Sign in again",
                    available: spotifyAuthCheckError == nil && webAPITokenAvailable
                )
            } label: {
                Text("Web API")
                Text("Playback state and device volume")
            }
            LabeledContent("Status") {
                Button("Refresh") {
                    Task {
                        await reloadSpotifyAuthState()
                    }
                }
                .disabled(isSigningIn)
            }
        }

        Section {
            DisclosureGroup("Developer") {
                LabeledContent("Client ID") {
                    HStack(spacing: 8) {
                        TextField("Client ID", text: $spotifyClientID, prompt: Text("Spotify Client ID"))
                            .labelsHidden()
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 260)
                            .accessibilityIdentifier("settings.spotify.clientID")
                        Button("Save") {
                            _ = saveSpotifyClientID(showMessage: true)
                        }
                        .disabled(isSigningIn)
                        .accessibilityIdentifier("settings.spotify.saveClientID")
                    }
                }
                LabeledContent("Redirect URIs") {
                    Text(Self.callbackURLText)
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
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
            .disabled(isSigningIn)
        } else {
            Button(isSigningIn ? "Signing In..." : "Sign In to Web API") {
                startSpotifySignIn()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)
        }
    }

    private var sonosPane: some View {
        Section {
            LabeledContent {
                StatusLabel(
                    text: spotifyAuthCheckError != nil ? "Status check failed" : desktopTokenAvailable && webAPITokenAvailable ? "Ready" : "Spotify sign-in required",
                    available: spotifyAuthCheckError == nil && desktopTokenAvailable && webAPITokenAvailable
                )
            } label: {
                Text("Send Spotify to speakers")
                Text("Hands playback between this Mac and Sonos")
            }
        } footer: {
            Text("Discovery, volume, and mute become available when Keyway finds a speaker on your local network.")
        }
    }

    @ViewBuilder
    private var browsersPane: some View {
        Section {
            LabeledContent {
                StatusLabel(
                    text: chromiumBrowserExtensionController.profileConnections.isEmpty
                        ? "No profiles connected"
                        : "\(chromiumBrowserExtensionController.profileConnections.count) \(chromiumBrowserExtensionController.profileConnections.count == 1 ? "profile" : "profiles") connected",
                    available: chromiumBrowserExtensionController.connected
                )
            } label: {
                Text("Browser extension")
                Text("Controls tabs in Chromium-family browsers")
            }
            LabeledContent("Tab audio") {
                StatusLabel(
                    text: chromiumBrowserExtensionController.connected ? chromiumBrowserAudioStatusText : "Extension disconnected",
                    available: chromiumBrowserExtensionController.connected
                )
            }
        } footer: {
            if let chromiumBridgeMessage {
                Text(chromiumBridgeMessage)
            }
        }

        Section {
            let installedBrowsers = chromiumBrowserInstallationAdapter.installedApplicationURLsByBundleIdentifier()
            ForEach(ChromiumBrowserDefinition.supported.filter { installedBrowsers[$0.bundleIdentifier] != nil }, id: \.bundleIdentifier) { browser in
                let profileCount = chromiumBrowserExtensionController.profileConnections
                    .filter { $0.browserBundleIdentifier == browser.bundleIdentifier }
                    .count
                LabeledContent {
                    if profileCount == 0 {
                        Button("Connect…", action: presentBrowserExtensionSetup)
                    } else {
                        StatusLabel(text: "\(profileCount) \(profileCount == 1 ? "profile" : "profiles")", available: true)
                    }
                } label: {
                    Label {
                        Text(browser.displayName)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: installedBrowsers[browser.bundleIdentifier]!.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                    }
                }
                .accessibilityIdentifier("settings.browserExtension.browser.\(browser.bundleIdentifier)")
            }
        } header: {
            Text("Installed Browsers")
        } footer: {
            HStack {
                Spacer()
                Button("Set Up Browsers…", action: presentBrowserExtensionSetup)
                    .accessibilityIdentifier("settings.browserExtension.setup")
            }
        }
    }

    @ViewBuilder
    private var permissionsPane: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    StatusLabel(text: accessibilityGranted ? "Enabled" : "Required", available: accessibilityGranted)
                    if !accessibilityGranted {
                        Button("Open Settings") {
                            AccessibilityPermission.requestPrompt()
                            refreshShortcutState()
                            NSWorkspace.shared.open(accessibilitySettingsURL)
                        }
                    }
                }
            } label: {
                Text("Accessibility")
                Text("Lets Keyway intercept keyboard events.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    StatusLabel(text: listenEventGranted ? "Enabled" : "Required", available: listenEventGranted)
                    if !listenEventGranted {
                        Button("Open Settings") {
                            _ = CGRequestListenEventAccess()
                            refreshShortcutState()
                            NSWorkspace.shared.open(inputMonitoringSettingsURL)
                        }
                    }
                }
            } label: {
                Text("Input Monitoring")
                Text("Lets Keyway receive media-key events.")
            }
        } header: {
            Text("Required")
        }

        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    StatusLabel(text: notificationBadgeTitle, available: notificationsEnabled)
                    if showsNotificationAction {
                        Button(notificationActionTitle) {
                            handleNotificationAction()
                        }
                        .disabled(isRequestingNotifications)
                    } else {
                        Button("Refresh") {
                            refreshNotificationState()
                        }
                        .disabled(isRequestingNotifications)
                    }
                }
            } label: {
                Text("Speaker suggestions")
                Text(notificationDetailText)
            }
        } header: {
            Text("Optional")
        } footer: {
            if let notificationMessage {
                Text(notificationMessage)
            }
        }
    }

    @ViewBuilder
    private var advancedPane: some View {
        Section("Media Helper") {
            LabeledContent {
                HStack(spacing: 10) {
                    StatusLabel(text: mediaRemoteController.health.badgeTitle, available: mediaRemoteController.health.isHealthy)
                    Button("Restart") {
                        mediaRemoteController.restart()
                    }
                }
            } label: {
                Text(mediaRemoteController.health.message)
                Text(helperStatusDetail)
                    .font(.system(size: 11, design: .monospaced))
            }
        }

        Section("Browser Bridge") {
            LabeledContent("Reinstall the native messaging host") {
                Button("Repair Bridge") {
                    installChromiumNativeBridge()
                }
            }
            LabeledContent("Unpacked extension folder") {
                HStack {
                    Button("Reveal Extension") {
                        revealChromiumExtension()
                    }
                    Button("Open Extensions") {
                        openChromiumExtensionsPage()
                    }
                }
            }
        }

        Section {
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
            LabeledContent("App state and the last 15 minutes of logs") {
                Button(isCopyingDiagnostics ? "Copying…" : diagnosticsCopied ? "Copied" : "Copy Diagnostics") {
                    Task { await copyDiagnostics() }
                }
                .disabled(isCopyingDiagnostics)
                .accessibilityIdentifier("settings.diagnostics.copy")
            }
        } header: {
            Text("Diagnostics")
        }

        Section {
            LabeledContent {
                StatusLabel(text: configImportBadgeTitle, available: configImportBadgeAvailable)
            } label: {
                Text("Sonos Handoff settings")
                Text(configImportSummary)
            }
            settingsPathRow(title: "Keyway", url: ConfigPaths.applicationSupportDirectory)
            settingsPathRow(title: "Legacy", url: ConfigPaths.legacyApplicationSupportDirectory)
            LabeledContent("Copy config and tokens from the old app") {
                Button("Import Existing Settings") {
                    runConfigImport()
                }
            }
        } header: {
            Text("Migration")
        }
    }

    private func copyDiagnostics() async {
        isCopyingDiagnostics = true
        defer { isCopyingDiagnostics = false }
        let bundle = Bundle.main
        let health = mediaRemoteController.health
        let runtimeStatusURL = ShortcutRuntimeStatus.persistenceURL
        let runtimeStatus = FileManager.default.fileExists(atPath: runtimeStatusURL.path)
            ? try! String(contentsOf: runtimeStatusURL, encoding: .utf8)
            : "missing"
        let logProcess = Process()
        let logPipe = Pipe()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        logProcess.arguments = [
            "show", "--last", "15m", "--info", "--style", "compact",
            "--predicate", "subsystem == \"\(AppIdentity.loggerSubsystem)\" AND NOT eventMessage CONTAINS \"pong\"",
        ]
        logProcess.standardOutput = logPipe
        try! logProcess.run()
        let logData = await Task.detached { logPipe.fileHandleForReading.readDataToEndOfFile() }.value
        let logLines = String(decoding: logData, as: UTF8.self).split(separator: "\n").suffix(600)
        let report = """
        Keyway \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String) (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as! String))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        accessibility=\(accessibilityGranted) inputMonitoring=\(listenEventGranted) notifications=\(notificationAuthorizationStatus.rawValue)
        mediaKeysPaused=\(mediaKeysPaused) launchAtLogin=\(launchAtLoginStatus.rawValue)
        spotifyWebAPI=\(webAPITokenAvailable) spotifyDesktop=\(desktopTokenAvailable)
        helper=\(health.badgeTitle) pid=\(health.pid.map(String.init) ?? "none") message=\(health.message)
        mediaTargets=\(mediaRemoteController.targets.map(\.appName).joined(separator: ","))
        chromiumProfiles=\(chromiumBrowserExtensionController.profileConnections.map(\.browserBundleIdentifier).joined(separator: ",")) chromiumTargets=\(chromiumBrowserExtensionController.targets.count)

        shortcut-runtime-status.json:
        \(runtimeStatus)

        logs:
        \(logLines.joined(separator: "\n"))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        diagnosticsCopied = true
    }

    private func settingsPathRow(title: String, url: URL) -> some View {
        LabeledContent(title) {
            Text(url.path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func settingsDiagnosticRow(title: String, detail: String) -> some View {
        LabeledContent(title, value: detail)
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
        do {
            let extensionURL = try chromiumBrowserInstallationAdapter.prepareUnpackedExtension()
            chromiumBrowserInstallationAdapter.revealExtension(extensionURL)
            chromiumBridgeMessage = "Revealed Keyway's managed Chromium extension folder."
        } catch {
            chromiumBridgeMessage = "Could not prepare the Chromium extension: \(error.localizedDescription)"
            logger.error("Chromium extension reveal failed error=\(error.localizedDescription, privacy: .public)")
        }
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
                authMessage = "Spotify Web API sign-in completed."
            } catch {
                authMessage = error.localizedDescription
            }
            await reloadState()
        }
    }

    private func startSpotifyDesktopSignIn() {
        authMessage = nil
        isSigningIn = true
        let authCoordinator = self.authCoordinator

        Task {
            defer { isSigningIn = false }
            do {
                try await authCoordinator.loginDesktop()
                authMessage = "Spotify sign-in for Sonos handoff completed."
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

/// Click, then press a key combination to bind it; Esc cancels, Delete clears.
private struct ShortcutRecorderField: View {
    let action: GlobalShortcutAction
    @AppStorage private var storage: String
    @State private var keyMonitor: Any?

    init(action: GlobalShortcutAction) {
        self.action = action
        _storage = AppStorage(wrappedValue: "", action.defaultsKey)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                keyMonitor == nil ? startRecording() : stopRecording()
            } label: {
                Text(keyMonitor != nil ? "Press shortcut…" : GlobalShortcut(storage: storage)?.label ?? "Record Shortcut")
                    .font(.system(size: 12, design: storage.isEmpty || keyMonitor != nil ? .default : .monospaced))
                    .foregroundStyle(storage.isEmpty && keyMonitor == nil ? .secondary : .primary)
                    .frame(minWidth: 120)
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings.shortcuts.\(action.rawValue)")

            if !storage.isEmpty, keyMonitor == nil {
                Button {
                    storage = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
                .accessibilityLabel("Clear \(action.title) shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        NotificationCenter.default.post(name: .keywayShortcutRecordingChanged, object: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
            } else if flags.isDisjoint(with: [.command, .option, .control, .shift]),
                      [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
                storage = ""
                stopRecording()
            } else if let shortcut = GlobalShortcut(event: event) {
                // One combination drives one action: take it away from any other action.
                for other in GlobalShortcutAction.allCases where other != action
                    && GlobalShortcut(storage: UserDefaults.standard.string(forKey: other.defaultsKey)) == shortcut {
                    UserDefaults.standard.set("", forKey: other.defaultsKey)
                }
                storage = shortcut.storage
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard let keyMonitor else {
            return
        }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
        NotificationCenter.default.post(name: .keywayShortcutRecordingChanged, object: false)
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case spotify = "Spotify"
    case sonos = "Sonos"
    case browsers = "Browsers"
    case permissions = "Permissions"
    case advanced = "Advanced"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "command"
        case .spotify: "music.note"
        case .sonos: "hifispeaker.2.fill"
        case .browsers: "globe"
        case .permissions: "hand.raised.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .shortcuts: .blue
        case .spotify: .green
        case .sonos: .orange
        case .browsers: .indigo
        case .permissions: .blue
        case .advanced: .gray
        }
    }
}

private struct StatusLabel: View {
    let text: String
    let available: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(available ? Color.green : Color.orange)
            if !text.isEmpty {
                Text(text)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
