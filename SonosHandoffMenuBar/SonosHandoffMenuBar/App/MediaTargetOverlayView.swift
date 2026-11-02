import AppKit
import SwiftUI

struct MediaTargetOverlayView: View {
    static let width: CGFloat = 600
    static let headerHeight: CGFloat = 66
    static let rowHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 8
    static let volumePanelHeight: CGFloat = 92
    static let footerHeight: CGFloat = 40
    static let maxVisibleRows = 6

    static func height(rowCount: Int, expanded: Bool) -> CGFloat {
        let visibleRows = CGFloat(max(1, min(rowCount, maxVisibleRows)))
        return headerHeight + 1
            + listPadding * 2 + visibleRows * rowHeight + (visibleRows - 1) * rowSpacing
            + (expanded ? volumePanelHeight : 0)
            + 1 + footerHeight
    }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var model: MediaTargetOverlayModel
    let onChoose: (MediaRemoteTarget) -> Void
    let onFocus: (MediaRemoteTarget) -> Void
    let onSelect: (Int) -> Void
    let onVolume: (MediaAudioVolumeDirection) -> Void
    let onMute: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            commandHeader
            Divider()
            targetList
            if model.expanded {
                volumePanel
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .keywayGlass(cornerRadius: 22)
        .animation(accessibilityReduceMotion ? nil : .snappy(duration: 0.28), value: model.routeConfirmationSequence)
    }

    private var commandHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: model.command?.symbolName ?? "music.note.list")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.command?.displayName ?? "Media Sources")
                    .font(.system(size: 16, weight: .semibold))
                Text(headerDetailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: Self.headerHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mediaTargetOverlay.header")
    }

    private var headerDetailText: String {
        let count = model.rows.count == 1 ? "1 source" : "\(model.rows.count) sources"
        return model.command == nil ? "Choose a source · \(count)" : "Choose where it goes · \(count)"
    }

    private var targetList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.rowSpacing) {
                    if model.rows.isEmpty {
                        emptyTargetRow
                    } else {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            targetRow(index: index, row: row)
                        }
                    }
                }
                .padding(Self.listPadding)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(model.rows.count <= Self.maxVisibleRows)
            .onChange(of: model.selectedIndex) {
                guard let targetID = model.selectedTarget?.id else {
                    return
                }
                proxy.scrollTo(targetID)
            }
        }
    }

    private var emptyTargetRow: some View {
        HStack(spacing: 12) {
            switch model.emptyState {
            case .discovering:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
            case .confirmedEmpty:
                Image(systemName: "play.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(emptyTitleText)
                    .font(.system(size: 14, weight: .semibold))
                Text(emptyDetailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .accessibilityIdentifier("mediaTargetOverlay.empty")
    }

    private var emptyDetailText: String {
        switch model.emptyState {
        case .discovering:
            return "Start Spotify, browser media, or QuickTime playback."
        case .confirmedEmpty(let detail):
            return detail
        }
    }

    private var emptyTitleText: String {
        switch model.emptyState {
        case .discovering:
            return "Looking for media"
        case .confirmedEmpty:
            return "No sources found"
        }
    }

    private func targetRow(index: Int, row: SourceRow) -> some View {
        let target = row.target
        let selected = index == model.selectedIndex
        let routeConfirmation = model.routeConfirmationSequence != nil
        let confirming = routeConfirmation && selected
        let suspect = row.reachability.isSuspect
        let subtitle = [
            target.browserDisplayName ?? target.appName,
            target.title.isEmpty ? "" : target.artist,
            target.routeSourceLabel == "Extension required" ? "Extension required" : "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")

        return Button {
            let modifiers = (NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
                .union(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))
            if modifiers.contains(.command) {
                onFocus(target)
            } else if model.expanded {
                onSelect(index)
            } else {
                onChoose(target)
            }
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                Image(nsImage: target.appIcon)
                    .resizable()
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title.isEmpty ? target.appName : target.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if confirming {
                    routeConfirmationLabel(target: target)
                } else {
                    playbackState(target: target, suspect: suspect)
                    if selected, !routeConfirmation, let verb = actionVerb(for: target) {
                        HStack(spacing: 6) {
                            Text(verb)
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "return")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .opacity(suspect ? 0.55 : 1)
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .background(
                selected ? Color.accentColor.opacity(confirming ? 0.32 : 0.2) : Color.clear,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(routeConfirmation)
        .allowsHitTesting(!routeConfirmation)
        .id(target.id)
        .accessibilityIdentifier("mediaTargetOverlay.target.\(target.id)")
    }

    @ViewBuilder
    private func playbackState(target: MediaRemoteTarget, suspect: Bool) -> some View {
        if suspect {
            Text("Not responding")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("mediaTargetOverlay.playbackState.\(target.id)")
        } else if target.isCurrentlyPlaying {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: !accessibilityReduceMotion)
                .accessibilityLabel("Playing")
                .accessibilityIdentifier("mediaTargetOverlay.playbackState.\(target.id)")
        } else {
            Text("Paused")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("mediaTargetOverlay.playbackState.\(target.id)")
        }
    }

    private func routeConfirmationLabel(target: MediaRemoteTarget) -> some View {
        let result: (title: String, symbol: String) = switch model.command {
        case .play: ("Playing", "play.fill")
        case .pause: ("Paused", "pause.fill")
        case .next: ("Next track", "forward.fill")
        case .previous: ("Previous track", "backward.fill")
        case .playPause, nil: target.isCurrentlyPlaying ? ("Playing", "play.fill") : ("Paused", "pause.fill")
        }
        return Label(result.title, systemImage: result.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            .accessibilityIdentifier("mediaTargetOverlay.playbackTransition.\(target.id)")
    }

    private func actionVerb(for target: MediaRemoteTarget) -> String? {
        switch model.command {
        case .playPause: target.isCurrentlyPlaying ? "Pause" : "Play"
        case .some(let command): command.displayName
        case nil: nil
        }
    }

    private var volumePanel: some View {
        let target = model.selectedTarget
        let control = target.map { $0.isSpotify ? model.audioSnapshot.spotify : $0.isBrowserLike ? model.audioSnapshot.browser : model.audioSnapshot.sonos }
            ?? model.audioSnapshot.sonos
        let supportsMute = !(target?.isSpotify ?? false)
        let muted = control.muted == true

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("VOLUME · \(control.title.uppercased())")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(control.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                volumeButton(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", identifier: "mediaTargetOverlay.mute", enabled: control.isEnabled && supportsMute && !control.isPending, action: onMute)
                volumeButton("minus", identifier: "mediaTargetOverlay.volumeDown", enabled: control.isEnabled) { onVolume(.down) }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(Color.primary.opacity(muted ? 0.3 : 0.85))
                            .frame(width: geometry.size.width * CGFloat(control.volume ?? 0) / 100)
                    }
                }
                .frame(height: 6)
                .opacity(control.volume == nil ? 0.4 : 1)

                volumeButton("plus", identifier: "mediaTargetOverlay.volumeUp", enabled: control.isEnabled) { onVolume(.up) }

                Text(control.volume.map { "\($0)%" } ?? "–")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Self.volumePanelHeight)
        .background(Color.primary.opacity(0.05))
        .accessibilityIdentifier("mediaTargetOverlay.volumePanel")
    }

    private func volumeButton(_ systemName: String, identifier: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            footerHint("↑↓", "Select")
            if model.expanded {
                footerHint("←→", "Adjust")
                footerHint("M", "Mute")
                footerHint("⇥", "Hide volume")
            } else {
                if model.rows.count > 1 {
                    footerHint("1–\(min(model.rows.count, 9))", "Jump")
                }
                footerHint("⌘↵", "Open app")
                footerHint("⇥", "Volume")
            }
            Spacer()
            footerHint("esc", "Close")
        }
        .padding(.horizontal, 18)
        .frame(height: Self.footerHeight)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

struct KeywayVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

extension View {
    @ViewBuilder
    func keywayGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(KeywayVisualEffect(material: .popover))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
        }
    }
}
