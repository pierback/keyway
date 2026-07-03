import Combine
import Foundation

enum MediaSourceReachability: Equatable, Sendable {
    case live
    case suspect(reason: String, since: Date)
    case gone
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

    init(target: MediaRemoteTarget) {
        self.target = target
        self.reachability = .live
        self.capabilities = MediaSourceCapabilities(target: target)
        self.audioState = MediaSourceAudioState(target: target)
    }

    // Phase 3b landmine: once reachability becomes real per-row state, this must
    // carry `self.reachability` (and any other stateful field) forward instead of
    // resetting to `SourceRow(target:)`'s default `.live` -- today every field is a
    // pure derivation of `target` so this is a no-op, but it stops being one the
    // moment reachability is no longer always `.live`.
    func updated(target: MediaRemoteTarget) -> SourceRow {
        SourceRow(target: target)
    }
}

@MainActor
final class MediaSourceStore: ObservableObject {
    @Published private(set) var rows: [SourceRow] = []

    private var targetsSubscription: AnyCancellable?

    var targets: [MediaRemoteTarget] {
        rows.map(\.target)
    }

    init(mediaRemoteController: MediaRemoteController) {
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
    }

    private func replaceRows(with targets: [MediaRemoteTarget]) {
        let previousRowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        rows = targets.map { target in
            previousRowsByID[target.id]?.updated(target: target) ?? SourceRow(target: target)
        }
    }
}
