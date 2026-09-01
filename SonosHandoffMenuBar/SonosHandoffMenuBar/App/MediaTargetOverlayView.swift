import AppKit
import SwiftUI

struct MediaTargetOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var model: MediaTargetOverlayModel
    @State private var animatedRouteConfirmationSequence: Int?
    let onChoose: (MediaRemoteTarget) -> Void
    let onFocus: (MediaRemoteTarget) -> Void
    let onSelect: (Int) -> Void
    let onSonosVolume: (MediaAudioVolumeDirection) -> Void
    let onSonosMute: () -> Void
    let onSpotifyVolume: (MediaAudioVolumeDirection) -> Void
    let onBrowserVolume: (MediaAudioVolumeDirection) -> Void
    let onBrowserMute: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            commandHeader
            Divider().opacity(0.42)
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
        .task(id: model.routeConfirmationSequence) {
            guard let sequence = model.routeConfirmationSequence else {
                animatedRouteConfirmationSequence = nil
                return
            }
            animatedRouteConfirmationSequence = nil
            guard !accessibilityReduceMotion else {
                animatedRouteConfirmationSequence = sequence
                return
            }
            DispatchQueue.main.async {
                guard model.routeConfirmationSequence == sequence else {
                    return
                }
                withAnimation(.spring(response: 0.46, dampingFraction: 0.68)) {
                    animatedRouteConfirmationSequence = sequence
                }
            }
        }
    }

    private var commandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
            Text("Media Targets")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
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
        Group {
            if model.rows.count > 6 {
                ScrollViewReader { proxy in
                    ScrollView {
                        targetRows
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: targetListHeight)
                    .task(id: model.routeConfirmationSequence) {
                        guard
                            let sequence = model.routeConfirmationSequence,
                            let targetID = model.selectedTarget?.id
                        else {
                            return
                        }
                        DispatchQueue.main.async {
                            guard model.routeConfirmationSequence == sequence else {
                                return
                            }
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
            } else {
                targetRows
            }
        }
    }

    private var targetRows: some View {
        LazyVStack(spacing: 3) {
            if model.rows.isEmpty {
                emptyTargetRow
            } else {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    targetRow(index: index, row: row)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, model.expanded ? 0 : 8)
    }

    private var targetListHeight: CGFloat {
        let visibleRows = min(model.rows.count, 6)
        let topPad: CGFloat = 14
        let bottomPad: CGFloat = model.expanded ? 0 : 8
        return topPad
            + CGFloat(max(1, visibleRows)) * 52
            + CGFloat(max(0, visibleRows - 1)) * 3
            + bottomPad
    }

    private var emptyTargetRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(emptyTitleText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(emptyDetailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 11)
        .frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
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
        let routeConfirmationAnimated = model.routeConfirmationSequence == animatedRouteConfirmationSequence
        let suspect = row.reachability.isSuspect
        let playbackTransition: (
            fromTitle: String,
            fromSymbol: String,
            toTitle: String,
            toSymbol: String
        )?
        if confirming && model.command == .play {
            playbackTransition = ("Paused", "pause.fill", "Playing", "play.fill")
        } else if confirming && model.command == .pause {
            playbackTransition = ("Playing", "play.fill", "Paused", "pause.fill")
        } else {
            playbackTransition = nil
        }
        let playbackTitle = playbackTransition?.toTitle
            ?? (target.isCurrentlyPlaying ? "Playing" : "Paused")
        let playbackSymbol = playbackTransition?.toSymbol
            ?? (target.isCurrentlyPlaying ? "play.fill" : "pause.fill")

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
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(confirming ? Color.white : Color.primary.opacity(0.64))
                    .frame(width: 23, height: 23)
                    .background(
                        confirming
                            ? Color.accentColor.opacity(
                                routeConfirmationAnimated || accessibilityReduceMotion ? 0.88 : 0.22
                            )
                            : Color.primary.opacity(selected ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )

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

                        if let routeSourceLabel = target.routeSourceLabel {
                            Text(routeSourceLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(
                                    Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                                .lineLimit(1)
                        }

                        if suspect {
                            Text("not responding")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(target.detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(suspect ? 0.58 : 1)

                Spacer()

                if let transition = playbackTransition {
                    VStack(alignment: .trailing, spacing: 1) {
                        Label(transition.toTitle, systemImage: transition.toSymbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.accentColor)

                        Text("was \(transition.fromTitle)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 92, alignment: .trailing)
                    .scaleEffect(
                        routeConfirmationAnimated || accessibilityReduceMotion ? 1 : 0.72,
                        anchor: .trailing
                    )
                    .offset(x: routeConfirmationAnimated || accessibilityReduceMotion ? 0 : 12)
                    .opacity(routeConfirmationAnimated || accessibilityReduceMotion ? 1 : 0)
                    .animation(
                        .spring(response: 0.38, dampingFraction: 0.62)
                            .delay(accessibilityReduceMotion ? 0 : 0.04),
                        value: routeConfirmationAnimated
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(transition.toTitle), was \(transition.fromTitle)")
                    .accessibilityIdentifier("mediaTargetOverlay.playbackTransition.\(target.id)")
                } else {
                    Label(playbackTitle, systemImage: playbackSymbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(playbackTitle == "Playing" ? Color.primary : Color.secondary)
                        .accessibilityIdentifier("mediaTargetOverlay.playbackState.\(target.id)")
                }

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
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Color.primary.opacity(0.12) : Color.clear)

                    if confirming {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(0.24),
                                        Color.accentColor.opacity(0.08),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .opacity(routeConfirmationAnimated || accessibilityReduceMotion ? 1 : 0)

                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.86), lineWidth: 1.5)
                            .shadow(color: Color.accentColor.opacity(0.34), radius: 10)
                            .opacity(routeConfirmationAnimated || accessibilityReduceMotion ? 1 : 0)

                        if !accessibilityReduceMotion {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.clear)
                                .overlay {
                                    LinearGradient(
                                        colors: [
                                            Color.clear,
                                            Color.white.opacity(0.22),
                                            Color.accentColor.opacity(0.78),
                                            Color.white.opacity(0.58),
                                            Color.clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: 180)
                                    .rotationEffect(.degrees(-10))
                                    .offset(x: routeConfirmationAnimated ? 430 : -430)
                                    .blendMode(.screen)
                                    .animation(
                                        .easeInOut(duration: 0.52),
                                        value: routeConfirmationAnimated
                                    )
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .scaleEffect(confirming && !accessibilityReduceMotion && !routeConfirmationAnimated ? 0.96 : 1)
        .offset(y: confirming && !accessibilityReduceMotion && !routeConfirmationAnimated ? 4 : 0)
        .animation(
            .spring(response: 0.46, dampingFraction: 0.68),
            value: routeConfirmationAnimated
        )
        .disabled(routeConfirmation)
        .allowsHitTesting(!routeConfirmation)
        .id(target.id)
        .accessibilityIdentifier("mediaTargetOverlay.target.\(target.id)")
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
                    HStack(spacing: 6) {
                        iconButton(
                            "speaker.wave.1.fill",
                            identifier: "mediaTargetOverlay.browserVolumeDown",
                            enabled: model.audioSnapshot.browser.isEnabled
                        ) {
                            onBrowserVolume(.down)
                        }
                        iconButton(
                            model.audioSnapshot.browser.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            identifier: "mediaTargetOverlay.browserMute",
                            enabled: model.audioSnapshot.browser.isEnabled && !model.audioSnapshot.browser.isPending,
                            pending: model.audioSnapshot.browser.isPending
                        ) {
                            onBrowserMute()
                        }
                        iconButton(
                            "speaker.wave.3.fill",
                            identifier: "mediaTargetOverlay.browserVolumeUp",
                            enabled: model.audioSnapshot.browser.isEnabled
                        ) {
                            onBrowserVolume(.up)
                        }
                    }
                }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
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
        pending: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(pending ? Color.secondary.opacity(0.72) : enabled ? Color.primary : Color.secondary.opacity(0.55))
        .background(
            Color.primary.opacity(pending ? 0.11 : enabled ? 0.08 : 0.04),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerHint("↑↓", "Select")
            footerHint("Enter", "Route")
            footerHint("⌘click / ⌘↵", "Open")
            footerHint("Esc", "Close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .frame(height: 20)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
