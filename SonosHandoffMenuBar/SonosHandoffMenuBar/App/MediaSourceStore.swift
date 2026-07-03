import Combine
import Foundation

enum MediaSourceReachability: Equatable, Sendable {
    case live
    case suspect(reason: String, since: Date)
    case gone

    var isSuspect: Bool {
        switch self {
        case .suspect:
            return true
        case .live, .gone:
            return false
        }
    }
}

struct MediaSourceCapabilities: Equatable, Sendable {
    let supportedCommands: [MediaRemoteTransportCommand]?

    init(target: MediaRemoteTarget) {
        self.supportedCommands = target.supportedCommands
    }
}

struct MediaSourceAudioState: Equatable, Sendable {
    let playbackRate: String
    let duration: Double?
    let elapsedTime: Double?
    let elapsedTimestamp: Double?

    init(target: MediaRemoteTarget) {
        self.playbackRate = target.playbackRate
        self.duration = target.duration
        self.elapsedTime = target.elapsedTime
        self.elapsedTimestamp = target.elapsedTimestamp
    }
}

struct SourceRow: Equatable, Identifiable, Sendable {
    let target: MediaRemoteTarget
    let reachability: MediaSourceReachability
    let capabilities: MediaSourceCapabilities
    let audioState: MediaSourceAudioState

    var id: String { target.id }

    init(target: MediaRemoteTarget, reachability: MediaSourceReachability = .live) {
        self.target = target
        self.reachability = reachability
        self.capabilities = MediaSourceCapabilities(target: target)
        self.audioState = MediaSourceAudioState(target: target)
    }

    func updated(target: MediaRemoteTarget) -> SourceRow {
        SourceRow(target: target, reachability: reachability)
    }
}

@MainActor
final class MediaSourceStore: ObservableObject {
    private static let commandFailedCooldownNanoseconds: UInt64 = 10_000_000_000

    @Published private(set) var rows: [SourceRow] = []

    private var targetsSubscription: AnyCancellable?
    private var chromiumSilentSubscription: AnyCancellable?
    private var chromiumSilentSuspectSinceByID: [String: Date] = [:]
    private var commandFailedSinceByID: [String: Date] = [:]

    var targets: [MediaRemoteTarget] {
        rows.map(\.target)
    }

    init(
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    ) {
        replaceRows(with: mediaRemoteController.targets)
        // Deliberately synchronous, not `.receive(on: .main)` + `Task { @MainActor }`:
        // both hops defer via a fresh main-queue/executor turn even when already on
        // the main thread, leaving a real window where `mediaRemoteController.targets`
        // has changed but `rows` hasn't caught up -- observable by event-time readers
        // (media-key/command-center callbacks interleave with queued blocks). All
        // `targets` mutations on MediaRemoteController are @MainActor, so this
        // publisher's emissions are always already on the main thread; `assumeIsolated`
        // cannot trap here and keeps this update inside the controller's own willSet,
        // matching the pre-extraction semantics exactly (event-time reads always fresh).
        targetsSubscription = mediaRemoteController.$targets
            .sink { [weak self] targets in
                MainActor.assumeIsolated {
                    self?.replaceRows(with: targets)
                }
            }

        chromiumSilentSubscription = chromiumBrowserExtensionController.$suspectTargetIDs
            .sink { [weak self] suspectTargetIDs in
                MainActor.assumeIsolated {
                    self?.replaceChromiumSilentSuspects(suspectTargetIDs)
                }
            }
    }

    func recordCommandResult(_ result: MediaRemoteCommandResultEvent) {
        guard !result.targetID.isEmpty else {
            return
        }
        if result.ok {
            clearCommandFailed(targetID: result.targetID)
        } else if !result.unsupported {
            markCommandFailed(targetID: result.targetID)
        }
    }

    func markCommandFailed(targetID: String, now: Date = Date()) {
        commandFailedSinceByID[targetID] = now
        replaceRows(with: targets)
        scheduleCommandFailedCooldown(targetID: targetID, since: now)
    }

    func clearCommandFailed(targetID: String) {
        guard commandFailedSinceByID.removeValue(forKey: targetID) != nil else {
            return
        }
        replaceRows(with: targets)
    }

    private func replaceRows(with targets: [MediaRemoteTarget]) {
        let previousRowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        rows = targets.map { target in
            let row = previousRowsByID[target.id]?.updated(target: target) ?? SourceRow(target: target)
            return row.withReachability(reachability(for: target.id))
        }
    }

    private func replaceChromiumSilentSuspects(_ suspectTargetIDs: Set<String>) {
        let now = Date()
        chromiumSilentSuspectSinceByID = Dictionary(
            uniqueKeysWithValues: suspectTargetIDs.map { targetID in
                (targetID, chromiumSilentSuspectSinceByID[targetID] ?? now)
            }
        )
        replaceRows(with: targets)
    }

    private func reachability(for targetID: String) -> MediaSourceReachability {
        if let since = commandFailedSinceByID[targetID] {
            return .suspect(reason: "command_failed", since: since)
        }
        if let since = chromiumSilentSuspectSinceByID[targetID] {
            return .suspect(reason: "no_recent_snapshot", since: since)
        }
        return .live
    }

    private func scheduleCommandFailedCooldown(targetID: String, since: Date) {
        Task { @MainActor [weak self] in
            guard (try? await Task.sleep(nanoseconds: Self.commandFailedCooldownNanoseconds)) != nil else {
                return
            }
            guard let self,
                  self.commandFailedSinceByID[targetID] == since
            else {
                return
            }
            self.commandFailedSinceByID.removeValue(forKey: targetID)
            self.replaceRows(with: self.targets)
        }
    }
}

private extension SourceRow {
    func withReachability(_ reachability: MediaSourceReachability) -> SourceRow {
        SourceRow(target: target, reachability: reachability)
    }
}
