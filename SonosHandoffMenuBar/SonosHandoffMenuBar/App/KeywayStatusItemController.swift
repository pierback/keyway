import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
final class KeywayStatusItemController: NSObject, NSPopoverDelegate {
    private let environment: AppEnvironment
    private let playback: PlaybackSyncController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var popover: NSPopover = makePopover()
    private var localStatusItemMonitor: Any?
    private var globalStatusItemMonitor: Any?
    private var lastModifierChooserClickTime: TimeInterval = 0

    init(environment: AppEnvironment) {
        self.environment = environment
        self.playback = PlaybackSyncController(environment: environment)
        super.init()
    }

    func start() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "Keyway"
        )
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Keyway"
        startStatusItemModifierMonitor()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let modifiers = (event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
            .union(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))

        if event?.type == .rightMouseUp || modifiers.contains(.control) {
            closePopover()
            showUtilityMenu(from: sender, event: event)
            return
        }

        if modifiers.contains(.option) || modifiers.contains(.command) {
            closePopover()
            showCenteredChooserFromModifierClick()
            return
        }

        togglePopover(relativeTo: sender)
    }

    private func startStatusItemModifierMonitor() {
        if localStatusItemMonitor == nil {
            localStatusItemMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.handleModifierMonitorEvent(event)
                return event
            }
        }

        if globalStatusItemMonitor == nil {
            globalStatusItemMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.handleModifierMonitorEvent(event)
            }
        }
    }

    private func handleModifierMonitorEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.option) || modifiers.contains(.command) else {
            return
        }
        guard statusItemFrameContains(event) else {
            return
        }
        closePopover()
        showCenteredChooserFromModifierClick()
    }

    private func statusItemFrameContains(_ event: NSEvent) -> Bool {
        guard let frame = statusItem.button?.window?.frame else {
            return false
        }

        let screenPoint: NSPoint
        if let window = event.window {
            screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = event.locationInWindow
        }

        return frame.insetBy(dx: -4, dy: -4).contains(screenPoint)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        environment.mediaRemoteController.refreshSnapshot()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func showCenteredChooser() {
        environment.mediaTransportActionController.showChooser(command: .playPause)
    }

    private func showCenteredChooserFromModifierClick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastModifierChooserClickTime > 0.25 else {
            return
        }
        lastModifierChooserClickTime = now
        showCenteredChooser()
    }

    private func openSettings() {
        closePopover()
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func openDiagnostics() {
        openSettings()
    }

    private func openChooserFromPopover() {
        closePopover()
        showCenteredChooser()
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        openSettings()
    }

    @objc private func openDiagnosticsFromMenu(_ sender: Any?) {
        openDiagnostics()
    }

    @objc private func restartMediaRemoteHelper(_ sender: Any?) {
        environment.mediaRemoteController.restart()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showUtilityMenu(from button: NSStatusBarButton, event: NSEvent?) {
        let menu = NSMenu()
        menu.addItem(menuItem("Settings...", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ","))
        menu.addItem(menuItem("Restart MediaRemote Helper", action: #selector(restartMediaRemoteHelper(_:))))
        menu.addItem(menuItem("Diagnostics", action: #selector(openDiagnosticsFromMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Keyway", action: #selector(quit(_:)), keyEquivalent: "q"))

        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: KeywayControlCenterPopoverView(
                playback: playback,
                mediaRemoteController: environment.mediaRemoteController,
                mediaTargetPreferenceStore: environment.mediaTargetPreferenceStore,
                mediaTransportActions: environment.mediaTransportActionController,
                openChooser: { [weak self] in self?.openChooserFromPopover() },
                openSettings: { [weak self] in self?.openSettings() },
                openDiagnostics: { [weak self] in self?.openDiagnostics() },
                restartMediaRemoteHelper: { [weak self] in self?.restartMediaRemoteHelper(nil) },
                quit: { NSApp.terminate(nil) }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = hostingController
        return popover
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else {
            return
        }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

@MainActor
private struct KeywayControlCenterPopoverView: View {
    @ObservedObject private var playback: PlaybackSyncController
    @ObservedObject private var mediaRemoteController: MediaRemoteController

    private let mediaTargetPreferenceStore: MediaTargetPreferenceStore
    private let mediaTransportActions: MediaTransportActionController
    private let openChooser: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void
    private let openDiagnostics: @MainActor () -> Void
    private let restartMediaRemoteHelper: @MainActor () -> Void
    private let quit: @MainActor () -> Void
    @State private var pinnedIdentity: String?
    @State private var showSpeakersList = true
    @State private var optionKeyPressed = false
    @State private var localModifierMonitor: Any?
    @State private var globalModifierMonitor: Any?
    @State private var modifierPollTask: Task<Void, Never>?

    init(
        playback: PlaybackSyncController,
        mediaRemoteController: MediaRemoteController,
        mediaTargetPreferenceStore: MediaTargetPreferenceStore,
        mediaTransportActions: MediaTransportActionController,
        openChooser: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void,
        openDiagnostics: @escaping @MainActor () -> Void,
        restartMediaRemoteHelper: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.playback = playback
        self.mediaRemoteController = mediaRemoteController
        self.mediaTargetPreferenceStore = mediaTargetPreferenceStore
        self.mediaTransportActions = mediaTransportActions
        self.openChooser = openChooser
        self.openSettings = openSettings
        self.openDiagnostics = openDiagnostics
        self.restartMediaRemoteHelper = restartMediaRemoteHelper
        self.quit = quit
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                header
                nowPlayingCard
                sonosTile
                alternateTargetsSection
            }
            .padding(12)
        }
        .frame(width: 360)
        .frame(maxHeight: 460)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            StatusHUD.shared.setVolumeOverlaySuppressed(true)
            pinnedIdentity = mediaTargetPreferenceStore.pinnedTargetIdentity
            playback.appear()
            mediaRemoteController.refreshSnapshot()
            startModifierMonitor()
        }
        .onDisappear {
            StatusHUD.shared.setVolumeOverlaySuppressed(false)
            stopModifierMonitor()
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

    private var header: some View {
        HStack(spacing: 8) {
            helperDot

            Text("Keyway")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))

            Text(mediaRemoteController.health.badgeTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                openChooser()
            } label: {
                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .background(.white.opacity(0.08), in: Circle())
            .accessibilityIdentifier("open-media-target-chooser")
            .accessibilityLabel("Open Media Target Chooser")

            Menu {
                Button("Settings...", action: openSettings)
                Button("Restart MediaRemote Helper", action: restartMediaRemoteHelper)
                Button("Diagnostics", action: openDiagnostics)
                Divider()
                Button("Quit Keyway", action: quit)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .background(.white.opacity(0.08), in: Circle())
            .accessibilityIdentifier("keyway-utility-menu")
            .accessibilityLabel("Keyway Utilities")
        }
        .frame(height: 28)
        .padding(.horizontal, 2)
    }

    private var nowPlayingCard: some View {
        let status = mediaTransportActions.currentRouteStatus()
        return card(cornerRadius: 15, padding: 10) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    targetIcon(status.target, size: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(status.kind.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.72))
                            statusPill(status.subtitle)
                        }
                        Text(status.target?.appName ?? "No media target")
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text(status.target?.detailText ?? "Waiting for Now Playing")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    transportButton(.previous)
                    transportButton(.playPause, emphasized: true)
                    transportButton(.next)
                    Spacer()
                    Button {
                        openChooser()
                    } label: {
                        Text("Change")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(.white.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.70))
                    .accessibilityIdentifier("change-media-target")
                    .accessibilityLabel("Change Media Target")
                }
            }
        }
    }

    private var sonosTile: some View {
        let row = selectedOutputRow
        let hasOutput = row != nil
        let roomName = playback.selectedRoomName ?? row?.coordinator.roomName ?? "Fallback room"
        let statusText = sonosStatusText(row: row)

        return card(cornerRadius: 15, padding: 10) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: hasOutput ? "hifispeaker.2.fill" : "hifispeaker.slash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(hasOutput ? .white : .white.opacity(0.42))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sonos")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                        Text(roomName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.56))
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                showSpeakersList.toggle()
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .rotationEffect(.degrees(showSpeakersList ? 180 : 0))
                                .frame(width: 28, height: 28)
                                .background(.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("toggle-sonos-controls")
                        .accessibilityLabel(showSpeakersList ? "Hide Sonos controls" : "Show Sonos controls")
                    }
                }

                MenuBarVolumeControl(playback: playback)
                    .padding(.horizontal, -3)

                if showSpeakersList {
                    Divider()
                        .background(.white.opacity(0.12))
                        .padding(.vertical, 2)

                    ScrollView(.vertical, showsIndicators: false) {
                        MenuBarOutputSection(
                            playback: playback,
                            groupEditing: optionKeyPressed,
                            openSpotifySettings: openSettings
                        )
                    }
                    .frame(maxHeight: 118)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var alternateTargetsSection: some View {
        let targets = alternateTargets
        if !targets.isEmpty {
            card(cornerRadius: 14, padding: 8) {
                VStack(spacing: 4) {
                    ForEach(targets.prefix(2)) { target in
                        mediaTargetRow(target)
                    }
                }
            }
        }
    }

    private var selectedOutputRow: PlaybackOutputRow? {
        if let selectedRoomName = playback.selectedRoomName,
           let selected = playback.outputRows.first(where: { $0.contains(roomName: selectedRoomName) }) {
            return selected
        }

        return playback.outputRows.first
    }

    private var sortedTargets: [MediaRemoteTarget] {
        let activeTargetID = mediaRemoteController.activeTargetID
        return mediaRemoteController.targets.sorted { lhs, rhs in
            if lhs.id == activeTargetID {
                return true
            }
            if rhs.id == activeTargetID {
                return false
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    private var alternateTargets: [MediaRemoteTarget] {
        let primaryTargetID = mediaTransportActions.currentRouteStatus().target?.id
        return sortedTargets.filter { target in
            guard let primaryTargetID else {
                return true
            }
            return target.id != primaryTargetID
        }
    }

    private func mediaTargetRow(_ target: MediaRemoteTarget) -> some View {
        let pinned = target.matchesRoutingIdentity(pinnedIdentity)

        return HStack(spacing: 9) {
            targetIcon(target, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(target.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(target.detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                mediaTargetPreferenceStore.togglePinnedTarget(target)
                pinnedIdentity = mediaTargetPreferenceStore.pinnedTargetIdentity
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? Color.white : Color.white.opacity(0.54))
            .background(.white.opacity(pinned ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityLabel(pinned ? "Unpin \(target.appName)" : "Pin \(target.appName)")
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(.white.opacity(target.id == mediaRemoteController.activeTargetID ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func transportButton(_ command: MediaRemoteTransportCommand, emphasized: Bool = false) -> some View {
        Button {
            mediaTransportActions.route(command: command)
        } label: {
            Image(systemName: command.symbolName)
                .font(.system(size: emphasized ? 13 : 11, weight: .semibold))
                .frame(width: emphasized ? 32 : 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
        .background(.white.opacity(emphasized ? 0.18 : 0.10), in: Circle())
        .accessibilityIdentifier("transport-\(command.rawValue)")
        .accessibilityLabel(command.displayName)
    }

    private func targetIcon(_ target: MediaRemoteTarget?, size: CGFloat) -> some View {
        Group {
            if let target {
                Image(nsImage: target.appIcon)
                    .resizable()
            } else {
                Image(systemName: "play.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.23)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(width: size, height: size)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private func sonosStatusText(row: PlaybackOutputRow?) -> String {
        if playback.isRefreshingOutputs {
            return "Searching for speakers"
        }
        guard row != nil else {
            return "Unavailable or offline"
        }
        if playback.volumeState.outputFixed {
            return "Fixed output"
        }
        if playback.volumeState.hasStatus {
            return playback.volumeState.muted ? "Muted" : "Volume \(playback.volumeState.roundedValue)%"
        }
        return "Volume unavailable"
    }

    private func statusPill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.58))
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(.white.opacity(0.08), in: Capsule())
    }

    private var helperDot: some View {
        Circle()
            .fill(mediaRemoteController.health.isHealthy ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .accessibilityIdentifier("helper-status")
    }

    private func card<Content: View>(
        cornerRadius: CGFloat,
        padding: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}
