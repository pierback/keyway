import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct SettingsFeature: View {
    static let menuTitle = "Settings"
    private static let callbackURLText = "http://127.0.0.1:43821/callback"
    private static let panelCornerRadius: CGFloat = 12
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
    @State private var showSpotifyAdvanced = false

    @State private var accessibilityGranted = false

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
            VStack(alignment: .leading, spacing: 10) {
                spotifySection
                shortcutsSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 500, alignment: .topLeading)
        .frame(minHeight: 310, alignment: .topLeading)
        .task {
            await reloadState()
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
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                }

                            Button("Save") {
                                saveSpotifyClientID()
                            }
                            .controlSize(.small)
                            .disabled(isSigningIn)
                        }

                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.left")
                                .font(.system(size: 10, weight: .medium))
                            Text(Self.callbackURLText)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
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
                    Text("Global volume shortcuts")
                        .font(.system(size: 13, weight: .medium))
                    Text(accessibilityGranted ? "Global volume shortcuts can listen in the background." : "Required for Shift-fn-F11/F12 volume shortcuts.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Button("Refresh") {
                    refreshAccessibilityState()
                }
                .controlSize(.small)

                Button("Open Settings") {
                    AccessibilityPermission.requestPrompt()
                    refreshAccessibilityState()
                    NSWorkspace.shared.open(accessibilitySettingsURL)
                }
                .controlSize(.small)
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

    private func reloadState() async {
        refreshAccessibilityState()
        await reloadSpotifyAuthState()

        do {
            let config = try configStore.load()
            spotifyClientID = config.spotifyClientID ?? ""
        } catch {
            authMessage = "Could not load settings."
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
