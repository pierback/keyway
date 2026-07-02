import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarMediaSourceSection: View {
    private static let accentColor = Color(nsColor: .controlAccentColor)
    private static let routeButtonHeight: CGFloat = 22
    private static let cachedTargetsGraceInterval: TimeInterval = 1.5

    @ObservedObject var mediaRemoteController: MediaRemoteController
    @ObservedObject var playback: PlaybackSyncController
    let mediaTransportActions: MediaTransportActionController
    let progressTick: UInt64
    @State private var cachedTargets: [MediaRemoteTarget] = []
    @State private var cachedTargetsUpdatedAt: Date?
    @State private var sessionTargets: [MediaRemoteTarget] = []
    @State private var sessionHasOpened = false

    private var freshTargets: [MediaRemoteTarget] {
        sortedTargets(mediaRemoteController.targets)
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
            if let replacementTarget = replacementTarget(
                for: sessionTarget,
                in: latestTargets,
                usedTargetIDs: usedTargetIDs
            ) {
                usedTargetIDs.insert(replacementTarget.id)
                return replacementTarget
            }
            if ChromiumBrowserExtensionTransport.isTarget(sessionTarget), !latestTargets.isEmpty {
                return nil
            }
            if mediaRemoteController.isRefreshingSnapshot, canShowCachedTargets {
                return sessionTarget
            }
            return nil
        }
        return resolvedTargets + latestTargets.filter { !usedTargetIDs.contains($0.id) }
    }

    private var openingTargets: [MediaRemoteTarget] {
        let targets = freshTargets
        if targets.isEmpty, mediaRemoteController.isRefreshingSnapshot, canShowCachedTargets {
            return cachedTargets
        }
        return targets
    }

    private var canShowCachedTargets: Bool {
        guard let cachedTargetsUpdatedAt else {
            return false
        }
        return Date().timeIntervalSince(cachedTargetsUpdatedAt) <= Self.cachedTargetsGraceInterval
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
        .onReceive(mediaRemoteController.$targets) { targets in
            let sortedTargets = sortedTargets(targets)
            rememberTargets(sortedTargets)
            hydrateEmptySessionIfNeeded(with: sortedTargets)
        }
    }

    private func openTargetSession() {
        rememberTargets(freshTargets)
        sessionTargets = openingTargets
        sessionHasOpened = true
    }

    private func hydrateEmptySessionIfNeeded(with targets: [MediaRemoteTarget]) {
        guard sessionHasOpened, sessionTargets.isEmpty, !targets.isEmpty else {
            return
        }
        sessionTargets = targets
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
            title: sessionTarget.title,
            artist: sessionTarget.artist,
            album: sessionTarget.album,
            playbackRate: latestTarget.playbackRate,
            mediaType: sessionTarget.mediaType,
            artworkBase64: sessionTarget.artworkBase64,
            duration: latestTarget.duration ?? sessionTarget.duration,
            elapsedTime: latestTarget.elapsedTime ?? sessionTarget.elapsedTime,
            elapsedTimestamp: latestTarget.elapsedTimestamp ?? sessionTarget.elapsedTimestamp,
            supportedCommands: latestTarget.supportedCommands ?? sessionTarget.supportedCommands,
            browserFamily: sessionTarget.browserFamily,
            browserDisplayName: sessionTarget.browserDisplayName,
            browserBundleIdentifier: sessionTarget.browserBundleIdentifier
        )
    }

    private func replacementTarget(
        for sessionTarget: MediaRemoteTarget,
        in latestTargets: [MediaRemoteTarget],
        usedTargetIDs: Set<String>
    ) -> MediaRemoteTarget? {
        guard ChromiumBrowserExtensionTransport.isTarget(sessionTarget) else {
            return nil
        }

        let matchingTargets = latestTargets.filter { latestTarget in
            guard ChromiumBrowserExtensionTransport.isTarget(latestTarget),
                  latestTarget.id != sessionTarget.id,
                  !usedTargetIDs.contains(latestTarget.id)
            else {
                return false
            }
            return latestTarget.browserBundleIdentifier == sessionTarget.browserBundleIdentifier
                && latestTarget.browserDisplayName == sessionTarget.browserDisplayName
                && latestTarget.title == sessionTarget.title
                && latestTarget.artist == sessionTarget.artist
                && latestTarget.album == sessionTarget.album
        }
        guard matchingTargets.count == 1 else {
            return nil
        }
        return matchingTargets[0]
    }

    private func rememberTargets(_ targets: [MediaRemoteTarget]) {
        if !targets.isEmpty {
            cachedTargets = targets
            cachedTargetsUpdatedAt = Date()
        }
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text("No active media sources")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(mediaRemoteController.health.badgeTitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
            }

            if !playback.outputRows.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
