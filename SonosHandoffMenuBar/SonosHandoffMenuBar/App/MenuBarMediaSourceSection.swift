import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarMediaSourceSection: View {
    private static let accentColor = Color(nsColor: .controlAccentColor)
    private static let routeButtonHeight: CGFloat = 22

    @ObservedObject var mediaRemoteController: MediaRemoteController
    @ObservedObject var mediaSourceStore: MediaSourceStore
    @ObservedObject var mediaAudioControlController: MediaAudioControlController
    @ObservedObject var playback: PlaybackSyncController
    let mediaTransportActions: MediaTransportActionController
    let progressTick: UInt64
    @State private var sessionTargets: [MediaRemoteTarget] = []
    @State private var sessionHasOpened = false
    @State private var spotifyPosition: (targetID: String, elapsedTime: Double, sampledAt: Double)?

    private var freshTargets: [MediaRemoteTarget] {
        sortedTargets(mediaSourceStore.rows.map(\.target))
    }

    private var displayTargets: [MediaRemoteTarget] {
        let _ = progressTick
        guard sessionHasOpened else {
            return openingTargets
        }
        let latestTargets = freshTargets
        let latestTargetsByID = Dictionary(uniqueKeysWithValues: latestTargets.map { ($0.id, $0) })
        var usedTargetIDs: Set<String> = []
        let resolvedTargets = sessionTargets.compactMap { sessionTarget in
            if let latestTarget = latestTargetsByID[sessionTarget.id] {
                usedTargetIDs.insert(latestTarget.id)
                return liveSessionTarget(sessionTarget, latestTarget: latestTarget)
            }
            if ChromiumBrowserExtensionTransport.isTarget(sessionTarget), !latestTargets.isEmpty {
                return nil
            }
            if mediaRemoteController.isRefreshingSnapshot {
                return sessionTarget
            }
            return nil
        }
        return resolvedTargets + latestTargets.filter { !usedTargetIDs.contains($0.id) }
    }

    private var openingTargets: [MediaRemoteTarget] {
        freshTargets
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
        .onAppear {
            openTargetSession()
        }
        .onDisappear {
            sessionTargets = []
            sessionHasOpened = false
        }
        .task(id: progressTick) {
            await refreshSpotifyPosition(displayTargets)
        }
        .onReceive(mediaSourceStore.$rows) { rows in
            let sortedTargets = sortedTargets(rows.map(\.target))
            hydrateEmptySessionIfNeeded(with: sortedTargets)
        }
    }

    private func openTargetSession() {
        sessionTargets = openingTargets
        sessionHasOpened = true
    }

    private func hydrateEmptySessionIfNeeded(with targets: [MediaRemoteTarget]) {
        guard sessionHasOpened, sessionTargets.isEmpty, !targets.isEmpty else {
            return
        }
        sessionTargets = targets
    }

    private func refreshSpotifyPosition(_ targets: [MediaRemoteTarget]) async {
        guard let target = targets.first(where: \.isSpotify) else {
            spotifyPosition = nil
            return
        }
        guard let elapsedTime = await MediaDesktopTransportAdapter.spotifyPlayerPosition(), !Task.isCancelled else {
            return
        }
        spotifyPosition = (target.id, elapsedTime, Date().timeIntervalSince1970)
    }

    private func liveSessionTarget(
        _ sessionTarget: MediaRemoteTarget,
        latestTarget: MediaRemoteTarget?
    ) -> MediaRemoteTarget {
        guard let latestTarget else {
            return sessionTarget
        }
        return MediaRemoteTarget(
            id: sessionTarget.id,
            bundleIdentifier: sessionTarget.bundleIdentifier,
            parentBundleIdentifier: sessionTarget.parentBundleIdentifier,
            displayName: sessionTarget.displayName,
            pid: latestTarget.pid,
            title: latestTarget.title.isEmpty ? sessionTarget.title : latestTarget.title,
            artist: latestTarget.title.isEmpty ? sessionTarget.artist : latestTarget.artist,
            album: latestTarget.title.isEmpty ? sessionTarget.album : latestTarget.album,
            playbackRate: latestTarget.playbackRate,
            mediaType: sessionTarget.mediaType,
            artworkBase64: latestTarget.artworkBase64
                ?? (latestTarget.title.isEmpty || latestTarget.title == sessionTarget.title ? sessionTarget.artworkBase64 : nil),
            duration: latestTarget.duration ?? sessionTarget.duration,
            elapsedTime: latestTarget.elapsedTime ?? sessionTarget.elapsedTime,
            elapsedTimestamp: latestTarget.elapsedTimestamp ?? sessionTarget.elapsedTimestamp,
            supportedCommands: latestTarget.supportedCommands ?? sessionTarget.supportedCommands,
            muted: latestTarget.muted ?? sessionTarget.muted,
            browserFamily: sessionTarget.browserFamily,
            browserDisplayName: sessionTarget.browserDisplayName,
            browserBundleIdentifier: sessionTarget.browserBundleIdentifier
        )
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text("No media sources")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("Start Spotify, browser media, or QuickTime playback.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
            }

            if !mediaRemoteController.health.isHealthy {
                Text(transportDiagnosticText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

            if !playback.outputRows.isEmpty || playback.headphoneOutput != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let output = playback.headphoneOutput {
                            spotifyHeadphoneRouteButton(output)
                        }
                        ForEach(playback.outputRows) { row in
                            idleSpotifyConnectButton(row)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 34)
        .accessibilityIdentifier("source-row-empty")
    }

    private func sourceRow(_ target: MediaRemoteTarget) -> some View {
        let suspect = sourceReachability(target).isSuspect

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                sourceIdentityButton(target, suspect: suspect)

                HStack(spacing: 7) {
                    sourceTransportButton(.previous, target: target)
                    sourceTransportButton(target.isCurrentlyPlaying ? .pause : .play, target: target, emphasized: true)
                    sourceTransportButton(.next, target: target)
                    if ChromiumBrowserExtensionTransport.isTarget(target) {
                        browserMuteButton(target)
                    }
                }
            }

            if let duration = target.duration, duration > 0 {
                progressBar(target, duration: duration, tick: progressTick)
            }

            if target.isSpotify {
                spotifyRouteRow(for: target)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("source-row-\(target.id)")
    }

    private func sourceIdentityButton(_ target: MediaRemoteTarget, suspect: Bool) -> some View {
        Button {
            mediaTransportActions.focus(target: target)
        } label: {
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
                        if suspect {
                            Text("not responding")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.46))
                                .lineLimit(1)
                        }
                    }
                    Text(target.detailText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                .opacity(suspect ? 0.58 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(target.appName)")
        .accessibilityIdentifier("source-\(target.id)-open")
        .accessibilityLabel(
            "\(target.appName), \(target.detailText)\(suspect ? ", not responding" : "")"
        )
        .accessibilityHint("Opens the app or browser tab")
    }

    private var transportDiagnosticText: String {
        "Helper \(mediaRemoteController.health.badgeTitle.lowercased())"
    }

    private func sourceReachability(_ target: MediaRemoteTarget) -> MediaSourceReachability {
        mediaSourceStore.rows.first(where: { $0.id == target.id })?.reachability ?? .live
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

    private func browserMuteButton(_ target: MediaRemoteTarget) -> some View {
        let state = mediaAudioControlController.browserMuteState(for: target)
        let disabled = state == nil || state?.isPending == true || sourceReachability(target).isSuspect
        let muted = state?.muted == true

        return Button {
            mediaAudioControlController.toggleBrowserMute(target: target)
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
                .overlay {
                    if state?.isPending == true {
                        Circle()
                            .stroke(.white.opacity(0.34), lineWidth: 1)
                            .frame(width: 18, height: 18)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(disabled ? 0.24 : muted ? 0.82 : 0.50))
        .disabled(disabled)
        .help(state?.isPending == true ? "Mute pending" : muted ? "Unmute tab" : "Mute tab")
        .accessibilityIdentifier("source-\(target.id)-browser-mute")
        .accessibilityLabel(muted ? "Unmute \(target.appName)" : "Mute \(target.appName)")
    }

    private func spotifyRouteRow(for target: MediaRemoteTarget) -> some View {
        Group {
            if playback.outputRows.isEmpty, playback.headphoneOutput == nil {
                Text(playback.isRefreshingOutputs ? "Searching for speakers" : "No Spotify Connect speakers")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let output = playback.headphoneOutput {
                            spotifyHeadphoneRouteButton(output)
                        }
                        ForEach(playback.outputRows) { row in
                            spotifyRouteButton(row, source: target)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("source-\(target.id)-spotify-routes")
    }

    private func spotifyHeadphoneRouteButton(_ output: MacAudioOutputDevice) -> some View {
        let selected = playback.isSpotifyPlayingOnMac
        let loading = playback.macTransferOutputID == output.id
        let disabled = playback.loadingRoomName != nil
            || playback.groupLoadingRoomName != nil
            || playback.volumeState.isBusy
            || playback.macTransferOutputID != nil

        return Button {
            playback.transferSpotifyPlaybackToMac(output: output)
        } label: {
            HStack(spacing: 4) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.50)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : output.name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(selected ? "\(output.name) connected" : "Send to \(output.name)")
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
        .help("Play Spotify on this Mac through \(output.name)")
        .accessibilityIdentifier("spotify-output-mac-\(output.id)")
        .accessibilityLabel(selected ? "\(output.name), selected Spotify output" : "Send Spotify to \(output.name)")
    }

    private func spotifyRouteButton(_ row: PlaybackOutputRow, source: MediaRemoteTarget) -> some View {
        let selected = playback.hasActiveSpotifyConnection(to: row)
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

    private func idleSpotifyConnectButton(_ row: PlaybackOutputRow) -> some View {
        let selected = playback.hasActiveSpotifyConnection(to: row)
        let loading = row.coordinator.roomName == playback.loadingRoomName
        let disabled = playback.loadingRoomName != nil
            || playback.groupLoadingRoomName != nil
            || playback.volumeState.isBusy

        return Button {
            playback.connectSpotify(to: row)
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
                Text(selected ? "\(row.displayName) connected" : "Connect to \(row.displayName)")
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
        .help("Connect Spotify to \(row.displayName)")
        .accessibilityIdentifier("source-empty-connect-spotify-to-\(row.coordinator.roomName)")
        .accessibilityLabel("Connect Spotify to \(row.displayName)")
    }

    private func supports(_ command: MediaRemoteTransportCommand, target: MediaRemoteTarget) -> Bool {
        if ChromiumBrowserExtensionTransport.isTarget(target) {
            return ChromiumBrowserExtensionTransport.supports(command: command, target: target)
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

    private func progressBar(_ target: MediaRemoteTarget, duration: Double, tick: UInt64) -> some View {
        let _ = tick
        var target = target
        if let spotifyPosition, spotifyPosition.targetID == target.id {
            target.elapsedTime = spotifyPosition.elapsedTime
            target.elapsedTimestamp = spotifyPosition.sampledAt
        }
        let elapsed = min(duration, max(0, target.currentElapsedTime ?? 0))

        return HStack(spacing: 7) {
            Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .frame(height: 3)
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: geo.size.width * elapsed / duration, height: 3)
                }
                .frame(maxHeight: .infinity)
            }
            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.48))
        .frame(height: 11)
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
