import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarController: View {
    static let settingsWindowID = "settings-window"
    private static let footerHorizontalPadding: CGFloat = 20
    private static let footerPrimaryRowHeight: CGFloat = 36
    private static let footerUtilityRowHeight: CGFloat = 31

    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @StateObject private var playback: PlaybackSyncController

    @State private var showMore = false
    @State private var optionKeyPressed = false
    @State private var localModifierMonitor: Any?
    @State private var globalModifierMonitor: Any?
    @State private var modifierPollTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        _playback = StateObject(wrappedValue: PlaybackSyncController(environment: environment))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuBarVolumeControl(playback: playback)
            divider
            MenuBarOutputSection(
                playback: playback,
                groupEditing: groupEditingActive,
                openSpotifySettings: openSettingsWindow
            )
            divider
                .padding(.top, 8)
            footer
        }
        .frame(width: 296)
        .padding(.vertical, 0)
        .background {
            ZStack {
                Rectangle()
                    .fill(.thinMaterial)
                Rectangle()
                    .fill(Color.black.opacity(0.18))
            }
        }
        .onAppear {
            StatusHUD.shared.setVolumeOverlaySuppressed(true)
            startModifierMonitor()
            playback.appear()
        }
        .onDisappear {
            StatusHUD.shared.setVolumeOverlaySuppressed(false)
            stopModifierMonitor()
        }
    }

    private var groupEditingActive: Bool {
        optionKeyPressed
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sound")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            if playback.isRefreshingOutputs || playback.loadingRoomName != nil {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.64)
                    .frame(width: 16, height: 16)
                    .transition(MenuBarMotion.rowTransition)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 3)
        .animation(MenuBarMotion.rowUpdate, value: playback.isRefreshingOutputs)
        .animation(MenuBarMotion.rowUpdate, value: playback.loadingRoomName)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow(title: "Show More", systemImage: showMore ? "chevron.down" : "chevron.right", emphasized: true) {
                withAnimation(MenuBarMotion.modeSwitch) {
                    showMore.toggle()
                }
            }

            if showMore {
                VStack(spacing: 0) {
                    footerRow(title: "Settings...", systemImage: "gearshape") {
                        openSettingsWindow()
                    }

                    footerRow(title: "Quit", systemImage: "power") {
                        NSApp.terminate(nil)
                    }
                }
                .padding(.top, 1)
                .padding(.bottom, 5)
                .transition(MenuBarMotion.statusTransition)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator.opacity(0.7))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func footerRow(
        title: String,
        systemImage: String?,
        emphasized: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                    .foregroundStyle(emphasized ? Color.primary : Color.primary.opacity(0.82))
                Spacer()
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.secondary.opacity(0.82))
                        .frame(width: 16, height: 16)
                }
            }
            .frame(height: emphasized ? Self.footerPrimaryRowHeight : Self.footerUtilityRowHeight)
            .padding(.horizontal, Self.footerHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSettingsWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: Self.settingsWindowID)
        }
    }

    private func startModifierMonitor() {
        applyModifierFlags(NSEvent.modifierFlags)
        if modifierPollTask == nil {
            modifierPollTask = Task { @MainActor in
                while !Task.isCancelled {
                    applyModifierFlags(NSEvent.modifierFlags)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        if localModifierMonitor == nil {
            localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                applyModifierFlags(event.modifierFlags)
                return event
            }
        }

        if globalModifierMonitor == nil {
            globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                applyModifierFlags(event.modifierFlags)
            }
        }
    }

    private func stopModifierMonitor() {
        modifierPollTask?.cancel()
        modifierPollTask = nil
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
        }
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
        }
        localModifierMonitor = nil
        globalModifierMonitor = nil
        optionKeyPressed = false
    }

    private func applyModifierFlags(_ flags: NSEvent.ModifierFlags) {
        let modifierFlags = flags.intersection(.deviceIndependentFlagsMask)
        let optionPressed = modifierFlags.contains(.option)
        if optionPressed != optionKeyPressed {
            optionKeyPressed = optionPressed
        }
    }
}
