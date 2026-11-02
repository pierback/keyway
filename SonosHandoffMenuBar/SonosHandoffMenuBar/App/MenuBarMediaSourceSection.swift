import AppKit
import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarMediaSourceSection: View {
    private static let accentColor = Color(nsColor: .controlAccentColor)

    @ObservedObject var mediaRemoteController: MediaRemoteController
    @ObservedObject var mediaSourceStore: MediaSourceStore
    @ObservedObject var mediaAudioControlController: MediaAudioControlController
    @ObservedObject var playback: PlaybackSyncController
    let mediaTransportActions: MediaTransportActionController
    let progressTick: UInt64
    @State private var sessionTargets: [MediaRemoteTarget] = []
    @State private var sessionHasOpened = false
    @State private var spotifyPosition: (targetID: String, elapsedTime: Double, sampledAt: Double)?
    @State private var pendingPlaying: [String: Bool] = [:]

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

        VStack(alignment: .leading, spacing: 12) {
            if let primary = displayTargets.first {
                primaryCard(primary)
                if displayTargets.count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Other Sources")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)
                        ForEach(displayTargets.dropFirst()) { target in
                            sourceRow(target)
                        }
                    }
                }
            } else {
                emptyRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            for row in rows where pendingPlaying[row.id] == row.target.isCurrentlyPlaying {
                pendingPlaying[row.id] = nil
            }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("No media sources")
                        .font(.system(size: 13, weight: .medium))
                    Text("Start Spotify, browser media, or QuickTime playback.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !mediaRemoteController.health.isHealthy {
                Text(transportDiagnosticText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !playback.outputRows.isEmpty || playback.headphoneOutput != nil {
                Menu {
                    if let output = playback.headphoneOutput {
                        Button(output.name) {
                            playback.transferSpotifyPlaybackToMac(output: output)
                        }
                    }
                    ForEach(playback.outputRows) { row in
                        idleSpotifyConnectButton(row)
                    }
                } label: {
                    outputMenuLabel("Play Spotify on…", loading: playback.loadingRoomName != nil || playback.macTransferOutputID != nil)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(outputTransferBlocked)
                .accessibilityIdentifier("source-empty-spotify-output")
            }
        }
        .padding(12)
        .keywayGlass(cornerRadius: 16)
        .accessibilityIdentifier("source-row-empty")
    }

    private func primaryCard(_ target: MediaRemoteTarget) -> some View {
        let suspect = sourceReachability(target).isSuspect

        return VStack(alignment: .leading, spacing: 12) {
            sourceIdentityButton(target, suspect: suspect, artworkSize: 56, primary: true)

            if let duration = target.duration, duration > 0 {
                progressBar(target, duration: duration, tick: progressTick)
            }

            HStack(spacing: 6) {
                if target.isSpotify {
                    spotifyOutputMenu(for: target)
                }
                Spacer(minLength: 0)
                if ChromiumBrowserExtensionTransport.isTarget(target) {
                    browserMuteButton(target)
                }
                sourceTransportButton(.previous, target: target)
                sourceTransportButton(pendingPlaying[target.id] ?? target.isCurrentlyPlaying ? .pause : .play, target: target, emphasized: true)
                sourceTransportButton(.next, target: target)
            }
        }
        .padding(12)
        .keywayGlass(cornerRadius: 16)
        .accessibilityIdentifier("source-row-\(target.id)")
    }

    private func sourceRow(_ target: MediaRemoteTarget) -> some View {
        let suspect = sourceReachability(target).isSuspect

        return HStack(spacing: 8) {
            sourceIdentityButton(target, suspect: suspect, artworkSize: 28, primary: false)
            if ChromiumBrowserExtensionTransport.isTarget(target) {
                browserMuteButton(target)
            }
            sourceTransportButton(pendingPlaying[target.id] ?? target.isCurrentlyPlaying ? .pause : .play, target: target)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .accessibilityIdentifier("source-row-\(target.id)")
    }

    private func sourceIdentityButton(_ target: MediaRemoteTarget, suspect: Bool, artworkSize: CGFloat, primary: Bool) -> some View {
        Button {
            mediaTransportActions.focus(target: target)
        } label: {
            HStack(spacing: primary ? 12 : 10) {
                artworkView(target, size: artworkSize)

                VStack(alignment: .leading, spacing: primary ? 2 : 1) {
                    if primary {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(pendingPlaying[target.id] ?? target.isCurrentlyPlaying ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text((target.browserDisplayName ?? target.appName).uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            if target.routeSourceLabel == "Extension required" {
                                Text("· Extension required")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                            if suspect {
                                Text("not responding")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Text(target.title.isEmpty ? target.appName : target.title)
                        .font(.system(size: primary ? 15 : 13, weight: primary ? .semibold : .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(primary ? target.artist : [target.browserDisplayName ?? target.appName, target.title.isEmpty ? "" : target.artist].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: primary ? 12 : 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if suspect, !primary {
                            Text("not responding")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
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
        let size: CGFloat = emphasized ? 36 : 28

        return Button {
            if command == .play || command == .pause {
                pendingPlaying[target.id] = command == .play
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    pendingPlaying[target.id] = nil
                }
            }
            mediaTransportActions.route(command: command, to: target)
        } label: {
            Image(systemName: command.symbolName)
                .font(.system(size: emphasized ? 14 : 12, weight: .semibold))
                .foregroundStyle(emphasized ? Color.white : Color.primary)
                .frame(width: size, height: size)
                .background(emphasized ? Color.accentColor : Color.primary.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
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
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(muted ? 0.16 : 0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(state?.isPending == true ? "Mute pending" : muted ? "Unmute tab" : "Mute tab")
        .accessibilityIdentifier("source-\(target.id)-browser-mute")
        .accessibilityLabel(muted ? "Unmute \(target.appName)" : "Mute \(target.appName)")
    }

    private var outputTransferBlocked: Bool {
        playback.loadingRoomName != nil
            || playback.groupLoadingRoomName != nil
            || playback.volumeState.isBusy
            || playback.macTransferOutputID != nil
    }

    private func spotifyOutputMenu(for target: MediaRemoteTarget) -> some View {
        let activeRow = playback.outputRows.first { playback.hasActiveSpotifyConnection(to: $0) }
        let title = playback.isSpotifyPlayingOnMac
            ? playback.headphoneOutput?.name ?? "This Mac"
            : activeRow?.displayName ?? "Choose speaker"

        return Menu {
            if playback.outputRows.isEmpty, playback.headphoneOutput == nil {
                Text(playback.isRefreshingOutputs ? "Searching for speakers" : "No Spotify Connect speakers")
            }
            if let output = playback.headphoneOutput {
                Toggle(output.name, isOn: Binding(
                    get: { playback.isSpotifyPlayingOnMac },
                    set: { _ in playback.transferSpotifyPlaybackToMac(output: output) }
                ))
            }
            ForEach(playback.outputRows) { row in
                Toggle(row.displayName, isOn: Binding(
                    get: { playback.hasActiveSpotifyConnection(to: row) },
                    set: { _ in playback.transferSpotifyPlayback(source: target, to: row) }
                ))
            }
        } label: {
            outputMenuLabel(title, loading: playback.loadingRoomName != nil || playback.macTransferOutputID != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(outputTransferBlocked)
        .help("Choose where Spotify plays")
        .accessibilityIdentifier("source-\(target.id)-spotify-output")
        .accessibilityLabel("Spotify playing on \(title)")
    }

    private func outputMenuLabel(_ title: String, loading: Bool) -> some View {
        HStack(spacing: 6) {
            if loading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(loading ? "Sending…" : title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func idleSpotifyConnectButton(_ row: PlaybackOutputRow) -> some View {
        Toggle(row.displayName, isOn: Binding(
            get: { playback.hasActiveSpotifyConnection(to: row) },
            set: { _ in playback.connectSpotify(to: row) }
        ))
        .accessibilityIdentifier("source-empty-connect-spotify-to-\(row.coordinator.roomName)")
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
        Image(nsImage: target.artworkImage ?? target.appIcon)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 8 : 6, style: .continuous))
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
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 3)
                    Capsule()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: geo.size.width * elapsed / duration, height: 3)
                }
                .frame(maxHeight: .infinity)
            }
            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 11)
    }
}
