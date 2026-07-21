import Combine
import Foundation

enum MediaSourceReachability: Equatable, Sendable {
    case live
    case suspect(reason: String, since: Date)

    var isSuspect: Bool {
        switch self {
        case .suspect:
            return true
        case .live:
            return false
        }
    }
}

struct SourceRow: Equatable, Identifiable, Sendable {
    let target: MediaRemoteTarget
    let reachability: MediaSourceReachability

    var id: String { target.id }

    init(target: MediaRemoteTarget, reachability: MediaSourceReachability = .live) {
        self.target = target
        self.reachability = reachability
    }
}

@MainActor
final class MediaSourceStore: ObservableObject {
    private static let commandFailedCooldownNanoseconds: UInt64 = 10_000_000_000

    @Published private(set) var rows: [SourceRow] = []

    private var targetsSubscription: AnyCancellable?
    private var helperDegradedSubscription: AnyCancellable?
    private var chromiumSilentSubscription: AnyCancellable?
    private var chromiumSilentSuspectSinceByID: [String: Date] = [:]
    private var commandFailedSinceByID: [String: Date] = [:]
    private var helperDegradedSince: Date?
    private var helperRecoveryGraceTask: Task<Void, Never>?
    private var latestControllerTargets: [MediaRemoteTarget] = []
    private var retainedMediaRemoteTargets: [MediaRemoteTarget] = []
    private let now: () -> Date

    init(
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        replaceControllerTargets(mediaRemoteController.targets)
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
                    self?.replaceControllerTargets(targets)
                }
            }

        helperDegradedSubscription = mediaRemoteController.$helperDegradedSince
            .sink { [weak self] degradedSince in
                MainActor.assumeIsolated {
                    self?.replaceHelperDegradedSince(degradedSince)
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
        rebuildRows()
        scheduleCommandFailedCooldown(targetID: targetID, since: now)
    }

    func clearCommandFailed(targetID: String) {
        guard commandFailedSinceByID.removeValue(forKey: targetID) != nil else {
            return
        }
        rebuildRows()
    }

    private func replaceControllerTargets(_ targets: [MediaRemoteTarget]) {
        latestControllerTargets = targets
        rememberMediaRemoteTargets(from: targets)
        rebuildRows()
    }

    private func rebuildRows() {
        let updatedRows = rowTargets().map { target in
            SourceRow(target: target, reachability: reachability(for: target))
        }
        guard updatedRows != rows else {
            return
        }
        rows = updatedRows
    }

    private func replaceChromiumSilentSuspects(_ suspectTargetIDs: Set<String>) {
        let now = now()
        chromiumSilentSuspectSinceByID = Dictionary(
            uniqueKeysWithValues: suspectTargetIDs.map { targetID in
                (targetID, chromiumSilentSuspectSinceByID[targetID] ?? now)
            }
        )
        rebuildRows()
    }

    private func replaceHelperDegradedSince(_ degradedSince: Date?) {
        helperDegradedSince = degradedSince
        if let degradedSince {
            scheduleHelperRecoveryGrace(since: degradedSince)
        } else {
            helperRecoveryGraceTask?.cancel()
            helperRecoveryGraceTask = nil
            rememberMediaRemoteTargets(from: latestControllerTargets)
        }
        rebuildRows()
    }

    private func rowTargets() -> [MediaRemoteTarget] {
        guard let helperDegradedSince,
              now().timeIntervalSince(helperDegradedSince) <= MediaRemoteController.helperRecoveryGraceInterval
        else {
            return latestControllerTargets
        }

        let knownTargetIDs = Set(latestControllerTargets.map(\.id))
        let retainedTargets = retainedMediaRemoteTargets.filter { target in
            !knownTargetIDs.contains(target.id)
        }
        return latestControllerTargets + retainedTargets
    }

    private func rememberMediaRemoteTargets(from targets: [MediaRemoteTarget]) {
        let mediaRemoteTargets = targets.filter { !ChromiumBrowserExtensionTransport.isTarget($0) }
        if helperDegradedSince == nil || !mediaRemoteTargets.isEmpty {
            retainedMediaRemoteTargets = mediaRemoteTargets
        }
    }

    private func reachability(for target: MediaRemoteTarget) -> MediaSourceReachability {
        if let since = helperDegradedSince,
           !ChromiumBrowserExtensionTransport.isTarget(target),
           now().timeIntervalSince(since) <= MediaRemoteController.helperRecoveryGraceInterval {
            return .suspect(reason: "helper_restarting", since: since)
        }
        let targetID = target.id
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
            self.rebuildRows()
        }
    }

    private func scheduleHelperRecoveryGrace(since: Date) {
        helperRecoveryGraceTask?.cancel()
        let elapsed = now().timeIntervalSince(since)
        let remainingNanoseconds = elapsed >= MediaRemoteController.helperRecoveryGraceInterval
            ? UInt64(0)
            : UInt64((MediaRemoteController.helperRecoveryGraceInterval - elapsed) * 1_000_000_000)
        helperRecoveryGraceTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(nanoseconds: remainingNanoseconds)) != nil else {
                return
            }
            guard let self,
                  self.helperDegradedSince == since
            else {
                return
            }
            self.helperRecoveryGraceTask = nil
            self.helperDegradedSince = nil
            self.retainedMediaRemoteTargets = []
            self.rebuildRows()
        }
    }
}
