import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
final class KeywayStatusItemController: NSObject, NSPopoverDelegate {
    private let playback: PlaybackSyncController
    private let mediaRemoteController: MediaRemoteController
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let mediaSourceStore: MediaSourceStore
    private let mediaAudioControlController: MediaAudioControlController
    private let mediaTransportActionController: MediaTransportActionController
    private let isRuntimeStarted: @MainActor () -> Bool
    private let isSonosEnabled: @MainActor () -> Bool
    private let presentPermissionOnboarding: @MainActor () -> Void
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var popover: NSPopover = makePopover()
    private var popoverLocalDismissMonitor: Any?
    private var popoverGlobalDismissMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?
    private var postPopoverCloseAction: (@MainActor () -> Void)?
    private var isStarted = false

    init(
        playback: PlaybackSyncController,
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        mediaSourceStore: MediaSourceStore,
        mediaAudioControlController: MediaAudioControlController,
        mediaTransportActionController: MediaTransportActionController,
        isRuntimeStarted: @escaping @MainActor () -> Bool,
        isSonosEnabled: @escaping @MainActor () -> Bool,
        presentPermissionOnboarding: @escaping @MainActor () -> Void
    ) {
        self.playback = playback
        self.mediaRemoteController = mediaRemoteController
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.mediaSourceStore = mediaSourceStore
        self.mediaAudioControlController = mediaAudioControlController
        self.mediaTransportActionController = mediaTransportActionController
        self.isRuntimeStarted = isRuntimeStarted
        self.isSonosEnabled = isSonosEnabled
        self.presentPermissionOnboarding = presentPermissionOnboarding
        super.init()
    }

    func start() {
        guard !isStarted else {
            return
        }
        guard let button = statusItem.button else {
            return
        }
        isStarted = true

        button.image = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "Keyway"
        )
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Keyway"
        StatusHUD.shared.setVolumeAnchorProvider { [weak self] in
            self?.statusItemButtonScreenFrame()
        }
        startAppDeactivationObserver()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        postPopoverCloseAction = nil
        closePopover()
        stopPopoverDismissMonitors()
        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
        }
        appDeactivationObserver = nil
        NSStatusBar.system.removeStatusItem(statusItem)
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

        guard isRuntimeStarted() else {
            presentPermissionOnboarding()
            return
        }

        togglePopover(relativeTo: sender)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        postPopoverCloseAction = nil
        mediaRemoteController.refreshSnapshot()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startPopoverDismissMonitors()
    }

    private func closePopover() {
        guard popover.isShown else {
            return
        }
        stopPopoverDismissMonitors()
        popover.close()
    }

    private func showCenteredChooser() {
        mediaTransportActionController.showTargetChooser()
    }

    private func openSettings() {
        closePopover()
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items
            .first(where: {
                $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
            }),
            let settingsAction = settingsItem.action
        else {
            preconditionFailure("SwiftUI Settings command is unavailable")
        }
        precondition(
            NSApp.sendAction(settingsAction, to: settingsItem.target, from: settingsItem),
            "SwiftUI Settings command has no target"
        )
    }

    private func openChooserFromPopover() {
        if popover.isShown {
            postPopoverCloseAction = { [weak self] in
                self?.showCenteredChooser()
            }
            closePopover()
            return
        }
        showCenteredChooser()
    }

    private func openSonosSetupFromPopover() {
        closePopover()
        presentPermissionOnboarding()
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        openSettings()
    }

    @objc private func restartMediaRemoteHelper(_ sender: Any?) {
        mediaRemoteController.restart()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showUtilityMenu(from button: NSStatusBarButton, event: NSEvent?) {
        let menu = NSMenu()
        menu.addItem(menuItem("Settings...", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ","))
        if isRuntimeStarted() {
            menu.addItem(menuItem("Restart MediaRemote Helper", action: #selector(restartMediaRemoteHelper(_:))))
        }
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
        popover.contentSize = NSSize(width: 340, height: 460)
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: KeywayControlCenterPopoverView(
                playback: playback,
                mediaRemoteController: mediaRemoteController,
                chromiumBrowserExtensionController: chromiumBrowserExtensionController,
                mediaSourceStore: mediaSourceStore,
                mediaAudioControlController: mediaAudioControlController,
                mediaTransportActions: mediaTransportActionController,
                isSonosEnabled: isSonosEnabled,
                openChooser: { [weak self] in self?.openChooserFromPopover() },
                openSonosSetup: { [weak self] in self?.openSonosSetupFromPopover() },
                openSettings: { [weak self] in self?.openSettings() },
                restartMediaRemoteHelper: { [weak self] in self?.restartMediaRemoteHelper(nil) },
                quit: { NSApp.terminate(nil) }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.layer?.isOpaque = false
        popover.contentViewController = hostingController
        return popover
    }

    private func startAppDeactivationObserver() {
        guard appDeactivationObserver == nil else {
            return
        }
        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func startPopoverDismissMonitors() {
        guard popoverLocalDismissMonitor == nil, popoverGlobalDismissMonitor == nil else {
            return
        }
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        popoverLocalDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            if self?.closePopoverIfNeeded(for: event) == true {
                return nil
            }
            return event
        }

        popoverGlobalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            _ = self?.closePopoverIfNeeded(for: event)
        }
    }

    private func stopPopoverDismissMonitors() {
        if let popoverLocalDismissMonitor {
            NSEvent.removeMonitor(popoverLocalDismissMonitor)
        }
        if let popoverGlobalDismissMonitor {
            NSEvent.removeMonitor(popoverGlobalDismissMonitor)
        }
        popoverLocalDismissMonitor = nil
        popoverGlobalDismissMonitor = nil
    }

    private func closePopoverIfNeeded(for event: NSEvent) -> Bool {
        guard popover.isShown else {
            return false
        }
        let screenPoint = screenPoint(for: event)
        if statusItemButtonFrameContains(screenPoint) || popoverWindowFrameContains(screenPoint) {
            return false
        }
        closePopover()
        return true
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window = event.window else {
            return event.locationInWindow
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func statusItemButtonFrameContains(_ screenPoint: NSPoint) -> Bool {
        guard let frame = statusItemButtonScreenFrame() else {
            return false
        }
        return frame.insetBy(dx: -4, dy: -4).contains(screenPoint)
    }

    private func statusItemButtonScreenFrame() -> NSRect? {
        guard let button = statusItem.button else {
            return nil
        }
        return button.window?.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func popoverWindowFrameContains(_ screenPoint: NSPoint) -> Bool {
        guard let frame = popover.contentViewController?.view.window?.frame else {
            return false
        }
        return frame.contains(screenPoint)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else {
            return
        }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverDismissMonitors()
        let action = postPopoverCloseAction
        postPopoverCloseAction = nil
        action?()
    }
}

@MainActor
private struct KeywayControlCenterPopoverView: View {
    private enum Metrics {
        static let outerCornerRadius: CGFloat = 22
        static let cardCornerRadius: CGFloat = 15
        static let primaryIconSize: CGFloat = 34
        static let tileEyebrowFont = Font.system(size: 11, weight: .semibold)
        static let tileTitleFont = Font.system(size: 15, weight: .semibold)
        static let tileDetailFont = Font.system(size: 12, weight: .regular)
    }

    @ObservedObject private var playback: PlaybackSyncController
    @ObservedObject private var mediaRemoteController: MediaRemoteController
    @ObservedObject private var chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    @ObservedObject private var mediaSourceStore: MediaSourceStore
    @ObservedObject private var mediaAudioControlController: MediaAudioControlController

    private let mediaTransportActions: MediaTransportActionController
    private let isSonosEnabled: @MainActor () -> Bool
    private let openChooser: @MainActor () -> Void
    private let openSonosSetup: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void
    private let restartMediaRemoteHelper: @MainActor () -> Void
    private let quit: @MainActor () -> Void
    @State private var showSpeakersList = true
    @State private var optionKeyPressed = false
    @State private var localModifierMonitor: Any?
    @State private var globalModifierMonitor: Any?
    @State private var progressTick: UInt64 = 0
    @State private var modifierPollTask: Task<Void, Never>?

    init(
        playback: PlaybackSyncController,
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        mediaSourceStore: MediaSourceStore,
        mediaAudioControlController: MediaAudioControlController,
        mediaTransportActions: MediaTransportActionController,
        isSonosEnabled: @escaping @MainActor () -> Bool,
        openChooser: @escaping @MainActor () -> Void,
        openSonosSetup: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void,
        restartMediaRemoteHelper: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.playback = playback
        self.mediaRemoteController = mediaRemoteController
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        self.mediaSourceStore = mediaSourceStore
        self.mediaAudioControlController = mediaAudioControlController
        self.mediaTransportActions = mediaTransportActions
        self.isSonosEnabled = isSonosEnabled
        self.openChooser = openChooser
        self.openSonosSetup = openSonosSetup
        self.openSettings = openSettings
        self.restartMediaRemoteHelper = restartMediaRemoteHelper
        self.quit = quit
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                header
                MenuBarMediaSourceSection(
                    mediaRemoteController: mediaRemoteController,
                    mediaSourceStore: mediaSourceStore,
                    mediaAudioControlController: mediaAudioControlController,
                    playback: playback,
                    mediaTransportActions: mediaTransportActions,
                    progressTick: progressTick
                )
                if isSonosEnabled() {
                    sonosTile
                } else {
                    sonosSetupTile
                }
            }
            .padding(12)
        }
        .frame(width: 340)
        .frame(maxHeight: 460)
        .background {
            RoundedRectangle(cornerRadius: Metrics.outerCornerRadius, style: .continuous)
                .fill(.clear)
                .background {
                    KeywayPopoverMaterial()
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.outerCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metrics.outerCornerRadius, style: .continuous)
                                .fill(Color.black.opacity(0.10))
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.outerCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.outerCornerRadius, style: .continuous))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            progressTick &+= 1
        }
        .onAppear {
            if isSonosEnabled() {
                playback.appear()
            }
            mediaRemoteController.refreshSnapshot()
            startModifierMonitor()
        }
        .onDisappear {
            playback.disappear()
            showSpeakersList = true
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

            Text(headerStatusTitle)
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
            .foregroundStyle(.white.opacity(0.65))
            .background(.white.opacity(0.06), in: Circle())
            .accessibilityIdentifier("open-media-target-chooser")
            .accessibilityLabel("Open Media Target Chooser")

            Menu {
                Button("Settings...", action: openSettings)
                Button("Restart MediaRemote Helper", action: restartMediaRemoteHelper)
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
            .foregroundStyle(.white.opacity(0.65))
            .background(.white.opacity(0.06), in: Circle())
            .accessibilityIdentifier("keyway-utility-menu")
            .accessibilityLabel("Keyway Utilities")
        }
        .frame(height: 28)
        .padding(.horizontal, 2)
    }

    private var sonosSetupTile: some View {
        card(cornerRadius: Metrics.cardCornerRadius, padding: 10) {
            HStack(spacing: 9) {
                Image(systemName: "hifispeaker.2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: Metrics.primaryIconSize, height: Metrics.primaryIconSize)
                    .background(.white.opacity(0.085), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Speakers")
                        .font(Metrics.tileEyebrowFont)
                        .foregroundStyle(.white.opacity(0.62))
                    Text("Sonos is not enabled")
                        .font(Metrics.tileTitleFont)
                    Text("Allow Local Network access to discover speakers.")
                        .font(Metrics.tileDetailFont)
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Set Up", action: openSonosSetup)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("setup-sonos")
            }
        }
    }

    private var sonosTile: some View {
        let row = selectedOutputRow
        let hasOutput = row != nil
        let roomName = playback.selectedRoomName
            ?? row?.coordinator.roomName
            ?? (playback.isRefreshingOutputs ? "Searching for speakers" : "No Sonos speakers")
        let statusText = sonosStatusText(row: row)

        return card(cornerRadius: Metrics.cardCornerRadius, padding: 10) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: hasOutput ? "hifispeaker.2.fill" : "hifispeaker.slash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(hasOutput ? .white : .white.opacity(0.42))
                        .frame(width: Metrics.primaryIconSize, height: Metrics.primaryIconSize)
                        .background(.white.opacity(0.085), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Speakers")
                            .font(Metrics.tileEyebrowFont)
                            .foregroundStyle(.white.opacity(0.62))
                        Text(roomName)
                            .font(Metrics.tileTitleFont)
                            .lineLimit(1)
                        Text(statusText)
                            .font(Metrics.tileDetailFont)
                            .foregroundStyle(.white.opacity(0.56))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                showSpeakersList.toggle()
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.60))
                                .rotationEffect(.degrees(showSpeakersList ? 180 : 0))
                                .frame(width: 28, height: 28)
                                .background(.white.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("toggle-sonos-controls")
                        .accessibilityLabel(showSpeakersList ? "Hide Sonos controls" : "Show Sonos controls")
                    }
                }

                if hasOutput {
                    MenuBarVolumeControl(playback: playback)
                        .padding(.horizontal, -3)
                }

                if showSpeakersList {
                    Divider()
                        .background(.white.opacity(0.12))
                        .padding(.vertical, 2)

                    ScrollView(.vertical, showsIndicators: false) {
                        MenuBarOutputSection(
                            playback: playback,
                            groupEditing: optionKeyPressed
                        )
                    }
                    .frame(maxHeight: 118)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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

    private func sonosStatusText(row: PlaybackOutputRow?) -> String {
        if playback.isRefreshingOutputs {
            return "Looking on this network"
        }
        guard row != nil else {
            return "Unavailable on this network"
        }
        if playback.volumeState.outputFixed {
            return "Fixed output"
        }
        if playback.volumeState.hasStatus {
            return playback.volumeState.muted ? "Muted" : "Volume \(playback.volumeState.roundedValue)%"
        }
        return "Volume unavailable"
    }

    private var helperDot: some View {
        Circle()
            .fill(transportsHealthy ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .accessibilityIdentifier("helper-status")
    }

    private var transportsHealthy: Bool {
        mediaRemoteController.health.isHealthy
    }

    private var headerStatusTitle: String {
        switch mediaRemoteController.health.state {
        case .failed, .stopped:
            if isBrowserOnlyRoutingAvailable {
                return "Browser only"
            }
            return mediaRemoteController.health.badgeTitle
        case .starting, .running:
            return mediaRemoteController.health.badgeTitle
        }
    }

    private var isBrowserOnlyRoutingAvailable: Bool {
        chromiumBrowserExtensionController.hasRoutableTargets
    }

    private func card<Content: View>(
        cornerRadius: CGFloat,
        padding: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.06), .white.opacity(0.035)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 0.5)
            }
    }
}

private struct KeywayPopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = true
    }
}
