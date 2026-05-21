import AppKit
import SwiftUI

@MainActor
final class MediaTargetOverlayModel: ObservableObject {
    @Published var command: MediaRemoteTransportCommand?
    @Published var targets: [MediaRemoteTarget] = []
    @Published var selectedIndex = 0
    @Published var pinnedIdentity: String?
    @Published var expanded = false
    @Published var audioSnapshot = MediaAudioControlSnapshot(
        sonos: .disabled(title: "Sonos", detail: "Checking output"),
        spotify: .disabled(title: "Spotify", detail: "Checking active device"),
        browser: .disabled(title: "Browser", detail: "Select a browser media target")
    )

    var selectedTarget: MediaRemoteTarget? {
        guard targets.indices.contains(selectedIndex) else {
            return nil
        }
        return targets[selectedIndex]
    }

    func update(
        command: MediaRemoteTransportCommand?,
        targets: [MediaRemoteTarget],
        pinnedIdentity: String?
    ) {
        self.command = command
        self.targets = targets
        self.pinnedIdentity = pinnedIdentity
        selectedIndex = 0
        expanded = false
    }

    func moveSelection(by delta: Int) {
        guard !targets.isEmpty else {
            return
        }
        selectedIndex = (selectedIndex + delta + targets.count) % targets.count
    }

    func select(index: Int) {
        guard targets.indices.contains(index) else {
            return
        }
        selectedIndex = index
    }

}

@MainActor
final class MediaTargetOverlayController {
    private let model = MediaTargetOverlayModel()
    private let audioController: MediaAudioControlController
    private var panel: MediaTargetOverlayPanel?
    private var onChoose: ((MediaRemoteTarget, MediaRemoteTransportCommand?) -> Void)?
    private var onPinToggle: ((MediaRemoteTarget) -> Void)?

    init(audioController: MediaAudioControlController) {
        self.audioController = audioController
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(
        command: MediaRemoteTransportCommand?,
        targets: [MediaRemoteTarget],
        pinnedIdentity: String?,
        onChoose: @escaping (MediaRemoteTarget, MediaRemoteTransportCommand?) -> Void,
        onPinToggle: @escaping (MediaRemoteTarget) -> Void
    ) {
        self.onChoose = onChoose
        self.onPinToggle = onPinToggle
        model.update(command: command, targets: targets, pinnedIdentity: pinnedIdentity)
        refreshAudioSnapshot()

        let panel = ensurePanel()
        resizeAndPosition(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> MediaTargetOverlayPanel {
        if let panel {
            return panel
        }

        let panel = MediaTargetOverlayPanel(
            contentRect: NSRect(origin: .zero, size: panelSize()),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        panel.contentView = NSHostingView(rootView: MediaTargetOverlayView(
            model: model,
            onChoose: { [weak self] target in
                self?.choose(target)
            },
            onSelect: { [weak self] index in
                self?.model.select(index: index)
                self?.refreshAudioSnapshot()
            },
            onPinToggle: { [weak self] target in
                self?.togglePin(target)
            },
            onSonosVolume: { [weak self] direction in
                self?.audioController.adjustSonosVolume(direction: direction)
                self?.refreshAudioSnapshot(delay: 0.35)
            },
            onSonosMute: { [weak self] in
                self?.audioController.toggleSonosMute()
                self?.refreshAudioSnapshot(delay: 0.35)
            },
            onSpotifyVolume: { [weak self] direction in
                self?.audioController.adjustSpotifyVolume(direction: direction)
                self?.refreshAudioSnapshot(delay: 0.35)
            }
        ))
        self.panel = panel
        return panel
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if model.expanded, modifiers.contains(.command), keyCode == 126 {
            adjustSelectedExpandedVolume(direction: .up)
            return true
        }
        if model.expanded, modifiers.contains(.command), keyCode == 125 {
            adjustSelectedExpandedVolume(direction: .down)
            return true
        }

        switch keyCode {
        case 126:
            model.moveSelection(by: -1)
            refreshAudioSnapshot()
            return true
        case 125:
            model.moveSelection(by: 1)
            refreshAudioSnapshot()
            return true
        case 36, 76:
            if let target = model.selectedTarget {
                choose(target)
            }
            return true
        case 53:
            close()
            return true
        case 48:
            model.expanded.toggle()
            resizeAndPosition(ensurePanel())
            refreshAudioSnapshot()
            return true
        default:
            break
        }

        if characters == "p", let target = model.selectedTarget {
            togglePin(target)
            return true
        }

        if let number = Int(characters), (1 ... 9).contains(number) {
            let index = number - 1
            guard model.targets.indices.contains(index) else {
                return true
            }
            if model.expanded {
                model.select(index: index)
                refreshAudioSnapshot()
                return true
            }
            choose(model.targets[index])
            return true
        }

        return false
    }

    private func choose(_ target: MediaRemoteTarget) {
        close()
        onChoose?(target, model.command)
    }

    private func togglePin(_ target: MediaRemoteTarget) {
        onPinToggle?(target)
        if target.matchesRoutingIdentity(model.pinnedIdentity) {
            model.pinnedIdentity = nil
        } else {
            model.pinnedIdentity = target.routingIdentity
        }
    }

    private func adjustSelectedExpandedVolume(direction: MediaAudioVolumeDirection) {
        guard let target = model.selectedTarget else {
            return
        }

        if target.isSpotify {
            audioController.adjustSpotifyVolume(direction: direction)
        } else if target.isBrowserLike {
            StatusHUD.shared.finish(
                title: "Browser Volume Disabled",
                message: "Keyway does not install a browser extension.",
                dismissAfter: 2.2
            )
        } else {
            StatusHUD.shared.finish(
                title: "Volume Unsupported",
                message: "\(target.appName) does not expose a Keyway volume backend.",
                dismissAfter: 2.2
            )
        }
        refreshAudioSnapshot(delay: 0.35)
    }

    private func refreshAudioSnapshot(delay: TimeInterval = 0) {
        let selectedTarget = model.selectedTarget
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self else { return }
            let snapshot = await audioController.snapshot(for: selectedTarget)
            model.audioSnapshot = snapshot
        }
    }

    private func resizeAndPosition(_ panel: NSPanel) {
        let size = panelSize()
        panel.setContentSize(size)
        guard let screen = screenContainingMouse() else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func panelSize() -> NSSize {
        let visibleRows = min(model.targets.count, 6)
        let rowHeight: CGFloat = 55
        let topPad: CGFloat = 14
        let bottomPad: CGFloat = model.expanded ? 0 : 16
        let listHeight = topPad + CGFloat(max(1, visibleRows)) * rowHeight + bottomPad
        let expandedHeight: CGFloat = model.expanded ? 120 : 0
        let footerHeight: CGFloat = 44
        let height = min(600, listHeight + expandedHeight + footerHeight)

        return NSSize(width: 680, height: height)
    }

    private func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
private final class MediaTargetOverlayPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

}

private struct MediaTargetOverlayView: View {
    @ObservedObject var model: MediaTargetOverlayModel
    let onChoose: (MediaRemoteTarget) -> Void
    let onSelect: (Int) -> Void
    let onPinToggle: (MediaRemoteTarget) -> Void
    let onSonosVolume: (MediaAudioVolumeDirection) -> Void
    let onSonosMute: () -> Void
    let onSpotifyVolume: (MediaAudioVolumeDirection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            targetList
            if model.expanded {
                expandedSectionDivider
                expandedControls
            }
            Divider().opacity(0.42)
            footer
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.94))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(width: 680)
        .accessibilityIdentifier("mediaTargetOverlay")
    }

    private var expandedSectionDivider: some View {
        HStack(spacing: 8) {
            VStack { Divider().opacity(0.42) }
            Text("Volume")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            VStack { Divider().opacity(0.42) }
        }
        .padding(.horizontal, 20)
        .frame(height: 10)
    }

    private var targetList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                    targetRow(index: index, target: target)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, model.expanded ? 0 : 16)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("mediaTargetOverlay.targetList")
    }

    private func targetRow(index: Int, target: MediaRemoteTarget) -> some View {
        let selected = index == model.selectedIndex
        let pinned = target.matchesRoutingIdentity(model.pinnedIdentity)

        return Button {
            onChoose(target)
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 23, height: 23)
                    .background(Color.primary.opacity(selected ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Image(nsImage: target.appIcon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.appName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(target.detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if target.id == model.selectedTarget?.id {
                    Image(systemName: "return")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 52)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mediaTargetOverlay.target.\(target.id)")
        .simultaneousGesture(TapGesture().onEnded {
            onSelect(index)
        })
    }

    private var expandedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                audioRow(
                    control: model.audioSnapshot.sonos,
                    systemImage: "hifispeaker.fill",
                    trailing: {
                        HStack(spacing: 6) {
                            iconButton(
                                "speaker.wave.1.fill",
                                identifier: "mediaTargetOverlay.sonosVolumeDown",
                                enabled: model.audioSnapshot.sonos.isEnabled
                            ) {
                                onSonosVolume(.down)
                            }
                            iconButton(
                                "speaker.slash.fill",
                                identifier: "mediaTargetOverlay.sonosMute",
                                enabled: model.audioSnapshot.sonos.isEnabled
                            ) {
                                onSonosMute()
                            }
                            iconButton(
                                "speaker.wave.3.fill",
                                identifier: "mediaTargetOverlay.sonosVolumeUp",
                                enabled: model.audioSnapshot.sonos.isEnabled
                            ) {
                                onSonosVolume(.up)
                            }
                        }
                    }
                )

                audioRow(
                    control: model.audioSnapshot.spotify,
                    systemImage: "music.note",
                    trailing: {
                        HStack(spacing: 6) {
                            iconButton(
                                "speaker.wave.1.fill",
                                identifier: "mediaTargetOverlay.spotifyVolumeDown",
                                enabled: model.audioSnapshot.spotify.isEnabled
                            ) {
                                onSpotifyVolume(.down)
                            }
                            iconButton(
                                "speaker.wave.3.fill",
                                identifier: "mediaTargetOverlay.spotifyVolumeUp",
                                enabled: model.audioSnapshot.spotify.isEnabled
                            ) {
                                onSpotifyVolume(.up)
                            }
                        }
                    }
                )
            }

            audioRow(
                control: model.audioSnapshot.browser,
                systemImage: "globe",
                trailing: {
                    Text("Disabled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityIdentifier("mediaTargetOverlay.expandedControls")
    }

    private func audioRow<Trailing: View>(
        control: MediaAudioControlPresentation,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(control.isEnabled ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(control.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(control.isEnabled ? Color.primary : Color.secondary)
                Text(control.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func iconButton(
        _ systemName: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.55))
        .background(Color.primary.opacity(enabled ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerHint("↑↓", "Select")
            footerHint("Enter", "Route")
            footerHint("Esc", "Close")
            footerHint("Tab", "Controls")
            footerHint("1-9", "Quick select")
            footerHint("P", "Pin")
            if model.expanded {
                footerHint("⌘↑/⌘↓", "Volume")
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 42)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
