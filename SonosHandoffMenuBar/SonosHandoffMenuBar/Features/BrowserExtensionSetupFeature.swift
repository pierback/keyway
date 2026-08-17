import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct BrowserExtensionSetupFeature: View {
    static let preferredWindowSize = CGSize(width: 640, height: 620)

    @ObservedObject var session: BrowserExtensionSetupSession
    let finish: @MainActor () -> Void
    let setUpLater: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 58, height: 58)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect your browsers")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Keyway can show and control media playing in each Chromium browser profile where you add the extension.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("What Keyway accesses", systemImage: "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(ChromiumBrowserSetupPolicy.dataUseDisclosure)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityIdentifier("browserSetup.dataUseDisclosure")

            if session.snapshot.browsers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No supported Chromium browsers found")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Install a Chromium-family browser, then reopen this setup from Keyway Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 250)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Detected browsers")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(
                                session.snapshot.browsers,
                                id: \.definition.bundleIdentifier
                            ) { browser in
                                BrowserExtensionSetupRow(
                                    browser: browser,
                                    openStore: {
                                        session.openChromeWebStore(for: browser)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Your browser will ask you to confirm the installation. Keyway cannot approve that step for you.",
                    systemImage: "hand.raised.fill"
                )
                Text("Extensions are installed per browser profile. To use another profile, switch to it and choose Install Another Profile here.")
                    .padding(.leading, 22)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let actionMessage = session.actionMessage {
                Text(actionMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("browserSetup.message")
            }

            Spacer(minLength: 0)

            Divider()

            HStack {
                Button("Set Up Later", action: setUpLater)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("browserSetup.later")

                Spacer()

                Button("Done", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("browserSetup.done")
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(width: Self.preferredWindowSize.width, height: Self.preferredWindowSize.height)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshInstalledBrowsers()
        }
    }
}

private struct BrowserExtensionSetupRow: View {
    let browser: ChromiumBrowserSetupBrowser
    let openStore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.applicationURL.path))
                .resizable()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(browser.definition.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if browser.connectedProfileCount > 0 {
                    Label(
                        "Ready · \(browser.connectedProfileCount) active \(browser.connectedProfileCount == 1 ? "profile" : "profiles")",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Label("Browser detected · No profile connected", systemImage: "circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))

            Spacer(minLength: 12)

            Button(
                ChromiumBrowserSetupPolicy.consentActionTitle(
                    browserDisplayName: browser.definition.displayName,
                    hasConnectedProfile: browser.connectedProfileCount > 0
                ),
                action: openStore
            )
            .controlSize(.small)
            .accessibilityIdentifier("browserSetup.openStore.\(browser.definition.bundleIdentifier)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}
