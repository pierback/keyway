import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarMediaSourceSection: View {
    private static let accentColor = Color(nsColor: .controlAccentColor)
    private static let routeButtonHeight: CGFloat = 22

    @ObservedObject var mediaRemoteController: MediaRemoteController
    @ObservedObject var playback: PlaybackSyncController
    let mediaTransportActions: MediaTransportActionController
    let progressTick: UInt64
    @State private var cachedTargets: [MediaRemoteTarget] = []

    private var freshTargets: [MediaRemoteTarget] {
        sortedTargets(mediaRemoteController.targets)
    }

    private var displayTargets: [MediaRemoteTarget] {
        let targets = freshTargets
        if targets.isEmpty, mediaRemoteController.isRefreshingSnapshot {
            return cachedTargets
        }
        return targets
    }

    private func sortedTargets(_ targets: [MediaRemoteTarget]) -> [MediaRemoteTarget] {
        MediaTransportCommandRules.sortedTargets(
            targets,
            preferredTargetID: mediaRemoteController.activeTargetID
        )
    }

    private var targetIDs: [String] {
        displayTargets.map(\.id)
    }

    var body: some View {
        let displayTargets = self.displayTargets

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active Sources")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                if displayTargets.isEmpty, mediaRemoteController.isRefreshingSnapshot {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.56)
                        .frame(width: 16, height: 16)
                }
            }

            if displayTargets.isEmpty {
                emptyRow
            } else {
                ForEach(displayTargets) { target in
                    let displayTarget = target
                    sourceRow(displayTarget)
                    if displayTarget.id != displayTargets.last?.id {
                        Divider()
                            .background(.white.opacity(0.08))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.06), .white.opacity(0.035)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 0.5)
        }
        .animation(MenuBarMotion.rowUpdate, value: targetIDs)
        .animation(MenuBarMotion.rowUpdate, value: playback.outputRows)
        .animation(MenuBarMotion.rowUpdate, value: playback.selectedRoomName)
        .onAppear {
            rememberTargets(freshTargets)
        }
        .onReceive(mediaRemoteController.$targets) { targets in
            rememberTargets(sortedTargets(targets))
        }
    }

    private func rememberTargets(_ targets: [MediaRemoteTarget]) {
        if !targets.isEmpty {
            cachedTargets = targets
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.38))
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(mediaRemoteController.isRefreshingSnapshot ? "Refreshing..." : "No active media sources")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Text(mediaRemoteController.health.badgeTitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 34)
        .accessibilityIdentifier("source-row-empty")
    }

    private func sourceRow(_ target: MediaRemoteTarget) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                artworkView(target, size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(target.appName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        if let label = target.routeSourceLabel {
                            sourceBadge(label)
                        }
                    }
                    Text(sourceDetail(target))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    sourceTransportButton(.previous, target: target)
                    sourceTransportButton(target.isCurrentlyPlaying ? .pause : .play, target: target, emphasized: true)
                    sourceTransportButton(.next, target: target)
                    focusButton(target)
                }
            }

            if target.duration != nil {
                progressBar(target, tick: progressTick)
            }

            if target.isSpotify {
                spotifyRouteRow(for: target)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("source-row-\(target.id)")
    }

    private func sourceDetail(_ target: MediaRemoteTarget) -> String {
        if !target.title.isEmpty, !target.artist.isEmpty {
            return "\(target.title) - \(target.artist)"
        }
        if !target.title.isEmpty {
            return target.title
        }
        if !target.artist.isEmpty {
            return target.artist
        }
        return target.isCurrentlyPlaying ? "Playing" : "Paused"
    }

    private func sourceTransportButton(
        _ command: MediaRemoteTransportCommand,
        target: MediaRemoteTarget,
        emphasized: Bool = false
    ) -> some View {
        let enabled = supports(command, target: target)

        return Button {
            mediaTransportActions.route(command: command, to: target)
        } label: {
            Image(systemName: command.symbolName)
                .font(.system(size: emphasized ? 12 : 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? (emphasized ? 0.90 : 0.65) : 0.22))
        .disabled(!enabled)
        .help(enabled ? command.displayName : "\(command.displayName) is not supported for \(target.appName)")
        .accessibilityIdentifier("source-\(target.id)-transport-\(command.rawValue)")
        .accessibilityLabel("\(command.displayName) \(target.appName)")
    }

    private func focusButton(_ target: MediaRemoteTarget) -> some View {
        Button {
            mediaTransportActions.focus(target: target)
        } label: {
            Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.62))
        .help("Focus \(target.appName)")
        .accessibilityIdentifier("source-\(target.id)-focus")
        .accessibilityLabel("Focus \(target.appName)")
    }

    private func spotifyRouteRow(for target: MediaRemoteTarget) -> some View {
        Group {
            if playback.outputRows.isEmpty {
                Text(playback.isRefreshingOutputs ? "Searching for speakers" : "No Spotify Connect speakers")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(playback.outputRows) { row in
                            spotifyRouteButton(row, source: target)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("source-\(target.id)-spotify-routes")
    }

    private func spotifyRouteButton(_ row: PlaybackOutputRow, source: MediaRemoteTarget) -> some View {
        let selected = row.contains(roomName: playback.selectedRoomName)
        let loading = row.coordinator.roomName == playback.loadingRoomName
        let disabled = playback.loadingRoomName != nil
            || playback.groupLoadingRoomName != nil
            || playback.volumeState.isBusy

        return Button {
            playback.transferSpotifyPlayback(source: source, to: row)
        } label: {
            HStack(spacing: 4) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.50)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "hifispeaker")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(selected ? "\(row.displayName) connected" : "Send to \(row.displayName)")
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(height: Self.routeButtonHeight)
            .background(selected ? Self.accentColor.opacity(0.28) : .white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(disabled ? 0.34 : 0.78))
        .disabled(disabled)
        .help("Send Spotify playback to \(row.displayName)")
        .accessibilityIdentifier("source-\(source.id)-route-spotify-to-\(row.coordinator.roomName)")
        .accessibilityLabel("Send Spotify to \(row.displayName)")
    }

    private func supports(_ command: MediaRemoteTransportCommand, target: MediaRemoteTarget) -> Bool {
        if ChromiumBrowserExtensionTransport.isTarget(target) {
            return ChromiumBrowserExtensionTransport.supports(command: command, target: target)
        }
        if target.mediaType == "desktop_automation", target.isChromiumBrowserLike {
            return command == .play || command == .pause || command == .playPause
        }
        if target.isChromiumBrowserLike {
            return false
        }
        if let supportedCommands = target.supportedCommands {
            return supportedCommands.contains(command)
        }
        return true
    }

    private func artworkView(_ target: MediaRemoteTarget, size: CGFloat) -> some View {
        Group {
            if let artworkImage = target.artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(nsImage: target.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func progressBar(_ target: MediaRemoteTarget, tick: UInt64) -> some View {
        let _ = tick
        let fraction = target.playbackFraction

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(height: 3)
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: max(0, geo.size.width * fraction), height: 3)
            }
        }
        .frame(height: 3)
    }

    private func sourceBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.54))
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(.white.opacity(0.08), in: Capsule())
    }
}
