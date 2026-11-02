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
    private let checkForUpdates: @MainActor () -> Void
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var popover: NSPopover = makePopover()
    private var popoverLocalDismissMonitor: Any?
    private var popoverGlobalDismissMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?
    private var mediaKeysPausedObserver: NSObjectProtocol?
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
        presentPermissionOnboarding: @escaping @MainActor () -> Void,
        checkForUpdates: @escaping @MainActor () -> Void
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
        self.checkForUpdates = checkForUpdates
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
        applyMediaKeysPausedAppearance()
        mediaKeysPausedObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMediaKeysPausedAppearance() }
        }
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
        playback.stop()
        stopPopoverDismissMonitors()
        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
        }
        appDeactivationObserver = nil
        if let mediaKeysPausedObserver {
            NotificationCenter.default.removeObserver(mediaKeysPausedObserver)
        }
        mediaKeysPausedObserver = nil
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

    /// Settings → Shortcuts "Open Keyway menu": behaves like a left click on the status item.
    func togglePopoverFromShortcut() {
        guard isRuntimeStarted() else {
            presentPermissionOnboarding()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        togglePopover(relativeTo: statusItem.button!)
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

    @objc private func checkForUpdatesFromMenu(_ sender: Any?) {
        checkForUpdates()
    }

    @objc private func toggleMediaKeysPaused(_ sender: Any?) {
        UserDefaults.standard.set(
            !UserDefaults.standard.bool(forKey: AppRuntime.mediaKeysPausedKey),
            forKey: AppRuntime.mediaKeysPausedKey
        )
        NotificationCenter.default.post(name: .sonosHandoffRefreshHotkeys, object: nil)
    }

    private func applyMediaKeysPausedAppearance() {
        let paused = UserDefaults.standard.bool(forKey: AppRuntime.mediaKeysPausedKey)
        statusItem.button?.appearsDisabled = paused
        statusItem.button?.toolTip = paused ? "Keyway — media keys paused" : "Keyway"
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
        menu.addItem(menuItem("Check for Updates...", action: #selector(checkForUpdatesFromMenu(_:))))
        if isRuntimeStarted() {
            let pauseItem = menuItem("Pause Media Keys", action: #selector(toggleMediaKeysPaused(_:)))
            pauseItem.state = UserDefaults.standard.bool(forKey: AppRuntime.mediaKeysPausedKey) ? .on : .off
            menu.addItem(pauseItem)
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
        hostingController.sizingOptions = [.preferredContentSize]
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

    func popoverDidClose(_ notification: Notification) {
        stopPopoverDismissMonitors()
        let action = postPopoverCloseAction
        postPopoverCloseAction = nil
        action?()
    }
}

@MainActor
private struct KeywayControlCenterPopoverView: View {
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
            VStack(alignment: .leading, spacing: 14) {
                if let problem = headerStatusTitle {
                    problemBanner(problem)
                }
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
                Divider()
                footer
            }
            .padding(12)
        }
        .focusEffectDisabled()
        .frame(width: 340)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
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

    private func problemBanner(_ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(isBrowserOnlyRoutingAvailable ? "Browser tabs still work." : "Media keys can't reach apps right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Restart", action: restartMediaRemoteHelper)
                .controlSize(.small)
                .accessibilityIdentifier("restart-media-helper")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("helper-status")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: openChooser) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Open Chooser")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-media-target-chooser")
            .accessibilityLabel("Open Media Target Chooser")

            Spacer(minLength: 0)

            Menu {
                Button("Settings...", action: openSettings)
                Divider()
                Button("Quit Keyway", action: quit)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("keyway-utility-menu")
            .accessibilityLabel("Keyway Utilities")
        }
        .padding(.horizontal, 4)
    }

    private var sonosSetupTile: some View {
        HStack(spacing: 10) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Sonos speakers")
                    .font(.system(size: 13, weight: .medium))
                Text("Allow Local Network access to find them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Set Up", action: openSonosSetup)
                .controlSize(.small)
                .accessibilityIdentifier("setup-sonos")
        }
        .padding(.horizontal, 4)
    }

    private var sonosTile: some View {
        MenuBarOutputSection(
            playback: playback,
            groupEditing: optionKeyPressed
        )
    }

    private var headerStatusTitle: String? {
        switch mediaRemoteController.health.state {
        case .failed, .stopped:
            return isBrowserOnlyRoutingAvailable ? "App media is unavailable" : "Media helper \(mediaRemoteController.health.badgeTitle.lowercased())"
        case .starting, .running:
            return nil
        }
    }

    private var isBrowserOnlyRoutingAvailable: Bool {
        chromiumBrowserExtensionController.hasRoutableTargets
    }
}
