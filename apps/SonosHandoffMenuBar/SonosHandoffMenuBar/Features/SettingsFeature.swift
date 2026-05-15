import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct SettingsFeature: View {
    static let menuTitle = "Settings"
    private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private let configStore: ConfigStoring
    private let tokenStore: TokenStoring
    private let connectTokenStatusStore: ConnectTokenStatusChecking
    private let authCoordinator: SpotifyAuthCoordinating
    private let accessibilityAutomator: AccessibilityAutomating

    @State private var spotifyClientID = ""
    @State private var isSpotifyAuthenticated = false
    @State private var desktopTokenAvailable = false
    @State private var webAPITokenAvailable = false
    @State private var authMessage: String?
    @State private var isSigningIn = false
    @State private var hasCheckedSpotifyAuthentication = false

    @State private var alias = ""
    @State private var deviceName = ""
    @State private var targets: [SavedTarget] = []
    @State private var statusMessage: String?

    @State private var virtualDisplayName = ""
    @State private var availableDisplayNames: [String] = []
    @State private var accessibilityGranted = false
    @State private var desktopMessage: String?

    init(
        configStore: ConfigStoring = ConfigStore(),
        tokenStore: TokenStoring = KeychainTokenStore(),
        connectTokenStatusStore: ConnectTokenStatusChecking = ConnectTokenStatusStore(),
        authCoordinator: SpotifyAuthCoordinating? = nil,
        accessibilityAutomator: AccessibilityAutomating = SpotifyUIAutomator()
    ) {
        self.configStore = configStore
        self.tokenStore = tokenStore
        self.connectTokenStatusStore = connectTokenStatusStore
        self.accessibilityAutomator = accessibilityAutomator
        self.authCoordinator = authCoordinator ?? SpotifyAuthCoordinator(
            tokenStore: tokenStore,
            configStore: configStore
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("sonos-handoff")
                    .font(.title2)
                    .bold()

                spotifySection
                Divider()
                targetsSection
                Divider()
                desktopAutomationSection
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 520)
        .task {
            await reloadState()
        }
    }

    private var spotifySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotify")
                .font(.headline)

            Text("Handoff uses the Spotify Desktop Connect token and a Web API verification token in Application Support. The generic Spotify sign-in below is only for refreshing the Web API token and does not replace the Desktop Connect token.")
                .foregroundStyle(.secondary)

            Text("http://127.0.0.1:43821/callback")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            HStack {
                TextField("Spotify Client ID", text: $spotifyClientID)
                    .textFieldStyle(.roundedBorder)
                Button("Save Client ID") {
                    saveSpotifyClientID()
                }
                .disabled(isSigningIn)
            }

            HStack {
                Label(
                    spotifyAuthStatusText,
                    systemImage: isSpotifyAuthenticated ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(isSpotifyAuthenticated ? .green : .secondary)

                Spacer()

                Button("Check Tokens") {
                    Task {
                        await reloadSpotifyAuthState()
                    }
                }
                .disabled(isSigningIn)

                Button(isSigningIn ? "Signing In..." : "Sign In for Web API") {
                    startSpotifySignIn()
                }
                .disabled(isSigningIn)

                Button("Forget Web API Sign-In") {
                    signOutSpotify()
                }
                .disabled(isSigningIn)
            }

            HStack {
                Label(
                    desktopTokenAvailable ? "Desktop Connect token present" : "Desktop Connect token missing",
                    systemImage: desktopTokenAvailable ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(desktopTokenAvailable ? .green : .orange)

                Label(
                    webAPITokenAvailable ? "Web API token file valid" : "Web API token file missing or stale",
                    systemImage: webAPITokenAvailable ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(webAPITokenAvailable ? .green : .orange)
            }

            if let authMessage {
                Text(authMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved Targets")
                .font(.headline)

            HStack {
                TextField("Alias", text: $alias)
                TextField("Spotify device name", text: $deviceName)
                Button("Save", action: saveTarget)
                    .keyboardShortcut(.defaultAction)
            }

            if targets.isEmpty {
                Text("No saved targets yet.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(targets, id: \.alias) { target in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.alias)
                                    .font(.body.weight(.medium))
                                Text(target.spotifyDeviceName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete") {
                                deleteTarget(alias: target.alias)
                            }
                        }
                    }
                }
                .frame(height: 120)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var desktopAutomationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Desktop Automation")
                .font(.headline)

            Text("Desktop automation works best when Spotify is visible and unobstructed. A named display is optional and only used if you want this app to reposition the Spotify window before opening the Connect panel.")
                .foregroundStyle(.secondary)

            HStack {
                TextField("Virtual display name (for example: Virtual 16:9)", text: $virtualDisplayName)
                    .textFieldStyle(.roundedBorder)
                Button("Save Display") {
                    saveVirtualDisplayName()
                }
            }

            if !availableDisplayNames.isEmpty {
                Text("Detected displays: \(availableDisplayNames.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(
                    accessibilityGranted ? "Accessibility granted" : "Accessibility required",
                    systemImage: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .foregroundStyle(accessibilityGranted ? .green : .orange)

                Spacer()

                Button("Refresh") {
                    refreshAccessibilityState()
                }

                Button("Request Permission") {
                    AccessibilityPermission.requestPrompt()
                    refreshAccessibilityState()
                }

                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(accessibilitySettingsURL)
                }
            }

            Text("Leave this empty to keep Spotify on its current display. Only save a display name if you explicitly want transfers to move Spotify onto that screen first.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let desktopMessage {
                Text(desktopMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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

    private func reloadState() async {
        availableDisplayNames = NSScreen.screens.map(\.localizedName).sorted()
        refreshAccessibilityState()
        await reloadSpotifyAuthState()

        do {
            let config = try configStore.load()
            spotifyClientID = config.spotifyClientID ?? ""
            virtualDisplayName = config.spotifyVirtualDisplayName ?? ""
            targets = config.targets.sorted {
                $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
            }
        } catch {
            statusMessage = "Could not load settings."
        }
    }

    private func reloadSpotifyAuthState() async {
        let tokenStatus = connectTokenStatusStore.status()
        desktopTokenAvailable = tokenStatus.desktopTokenAvailable
        webAPITokenAvailable = tokenStatus.projectTokenAvailable
        isSpotifyAuthenticated = tokenStatus.isReadyForHandoff
        hasCheckedSpotifyAuthentication = true
    }

    private func refreshAccessibilityState() {
        accessibilityGranted = accessibilityAutomator.checkAccessibilityPermission()
    }

    private func saveSpotifyClientID() {
        let trimmedClientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let config = try configStore.load()
            try configStore.save(
                AppConfig(
                    targets: config.targets,
                    spotifyClientID: trimmedClientID.isEmpty ? nil : trimmedClientID,
                    spotifyVirtualDisplayName: config.spotifyVirtualDisplayName
                )
            )
            authMessage = trimmedClientID.isEmpty ? "Removed Spotify Client ID." : "Saved Spotify Client ID."
        } catch {
            authMessage = "Could not save Spotify Client ID."
        }
    }

    private func startSpotifySignIn() {
        saveSpotifyClientID()
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
            await reloadSpotifyAuthState()
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

    private func saveTarget() {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAlias.isEmpty, !trimmedDeviceName.isEmpty else {
            statusMessage = "Alias and Spotify device name are required."
            return
        }

        do {
            let config = try configStore.load()
            let filtered = config.targets.filter {
                $0.alias.caseInsensitiveCompare(trimmedAlias) != .orderedSame
            }
            let saved = SavedTarget(alias: trimmedAlias, spotifyDeviceName: trimmedDeviceName)
            try configStore.save(
                AppConfig(
                    targets: filtered + [saved],
                    spotifyClientID: config.spotifyClientID,
                    spotifyVirtualDisplayName: config.spotifyVirtualDisplayName
                )
            )
            alias = ""
            deviceName = ""
            statusMessage = "Saved target '\(trimmedAlias)'."
            Task { await reloadState() }
        } catch {
            statusMessage = "Could not save the target."
        }
    }

    private func deleteTarget(alias: String) {
        do {
            let config = try configStore.load()
            let filtered = config.targets.filter {
                $0.alias.caseInsensitiveCompare(alias) != .orderedSame
            }
            try configStore.save(
                AppConfig(
                    targets: filtered,
                    spotifyClientID: config.spotifyClientID,
                    spotifyVirtualDisplayName: config.spotifyVirtualDisplayName
                )
            )
            statusMessage = "Deleted target '\(alias)'."
            Task { await reloadState() }
        } catch {
            statusMessage = "Could not delete the target."
        }
    }

    private func saveVirtualDisplayName() {
        let trimmedName = virtualDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let config = try configStore.load()
            try configStore.save(
                AppConfig(
                    targets: config.targets,
                    spotifyClientID: config.spotifyClientID,
                    spotifyVirtualDisplayName: trimmedName.isEmpty ? nil : trimmedName
                )
            )
            desktopMessage = trimmedName.isEmpty ? "Cleared virtual display target." : "Saved virtual display '\(trimmedName)'."
        } catch {
            desktopMessage = "Could not save the virtual display name."
        }
    }
}
