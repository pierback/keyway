import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct BrowserExtensionSetupFeature: View {
    static let preferredWindowSize = CGSize(width: 600, height: 480)

    @ObservedObject var session: BrowserExtensionSetupSession
    let finish: @MainActor () -> Void
    let setUpLater: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 24, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect a browser")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Choose a browser. Keyway opens Extensions and copies the folder path.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label(ChromiumBrowserSetupPolicy.dataUseDisclosure, systemImage: "lock.shield.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
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
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Browsers")
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
                                    startSetup: {
                                        session.startDeveloperModeSetup(for: browser)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: session.developerModeSetup == nil ? 240 : 112)
                }
            }

            if let developerModeSetup = session.developerModeSetup {
                BrowserExtensionDeveloperModeInstructions(
                    setup: developerModeSetup,
                    copyPath: session.copyExtensionPath,
                    revealExtension: session.revealExtension,
                    reopenExtensionsPage: session.reopenExtensionsPage
                )
            }

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
                Button("Later", action: setUpLater)
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
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: Self.preferredWindowSize.width, height: Self.preferredWindowSize.height)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshInstalledBrowsers()
        }
    }
}

private struct BrowserExtensionSetupRow: View {
    let browser: ChromiumBrowserSetupBrowser
    let startSetup: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.applicationURL.path))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(browser.definition.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if browser.connectedProfileCount > 0 {
                    Label("Ready · \(browser.connectedProfileCount) \(browser.connectedProfileCount == 1 ? "profile" : "profiles")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not connected", systemImage: "circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))

            Spacer(minLength: 12)

            Button(
                ChromiumBrowserSetupPolicy.setupActionTitle(
                    hasConnectedProfile: browser.connectedProfileCount > 0
                ),
                action: startSetup
            )
            .controlSize(.small)
            .accessibilityIdentifier("browserSetup.startSetup.\(browser.definition.bundleIdentifier)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}

private struct BrowserExtensionDeveloperModeInstructions: View {
    let setup: ChromiumBrowserDeveloperModeSetup
    let copyPath: () -> Void
    let revealExtension: () -> Void
    let reopenExtensionsPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Finish in \(setup.browser.definition.displayName)", systemImage: "puzzlepiece.extension.fill")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for connection")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("Developer mode → Load unpacked → ⇧⌘G → Paste → Open")
                .fontWeight(.medium)

            Text(setup.extensionDirectoryURL.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("browserSetup.extensionPath")

            HStack(spacing: 8) {
                Button("Copy Path", action: copyPath)
                    .accessibilityIdentifier("browserSetup.copyPath")
                Button("Show Folder", action: revealExtension)
                    .accessibilityIdentifier("browserSetup.revealExtension")
                Button("Open Extensions", action: reopenExtensionsPage)
                    .accessibilityIdentifier("browserSetup.reopenExtensions")
            }
            .controlSize(.small)
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
        }
    }
}
