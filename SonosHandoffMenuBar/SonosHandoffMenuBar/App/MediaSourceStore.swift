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

    private var mediaRemoteTargetsSubscription: AnyCancellable?
    private var activeTargetSubscription: AnyCancellable?
    private var chromiumTargetsSubscription: AnyCancellable?
    private var helperDegradedSubscription: AnyCancellable?
    private var chromiumSilentSubscription: AnyCancellable?
    private var chromiumSilentSuspectSinceByID: [String: Date] = [:]
    private var commandFailedSinceByID: [String: Date] = [:]
    private var helperDegradedSince: Date?
    private var helperRecoveryGraceTask: Task<Void, Never>?
    private var latestMediaRemoteTargets: [MediaRemoteTarget] = []
    private var latestChromiumTargets: [MediaRemoteTarget] = []
    private var activeTargetID: String?
    private var retainedMediaRemoteTargets: [MediaRemoteTarget] = []
    private let now: () -> Date
    private let targetsChanged: ([MediaRemoteTarget], String?, Int) -> Void

    init(
        mediaRemoteController: MediaRemoteController,
        chromiumBrowserExtensionController: ChromiumBrowserExtensionController,
        now: @escaping () -> Date = Date.init,
        targetsChanged: @escaping ([MediaRemoteTarget], String?, Int) -> Void = { _, _, _ in }
    ) {
        self.now = now
        self.targetsChanged = targetsChanged
        latestMediaRemoteTargets = mediaRemoteController.targets
        latestChromiumTargets = chromiumBrowserExtensionController.targets
        activeTargetID = mediaRemoteController.activeTargetID
        rememberMediaRemoteTargets(from: latestMediaRemoteTargets)
        rebuildRows()

        mediaRemoteTargetsSubscription = mediaRemoteController.$targets
            .sink { [weak self] targets in
                MainActor.assumeIsolated {
                    self?.replaceMediaRemoteTargets(targets)
                }
            }

        activeTargetSubscription = mediaRemoteController.$activeTargetID
            .sink { [weak self] activeTargetID in
                MainActor.assumeIsolated {
                    self?.replaceActiveTargetID(activeTargetID)
                }
            }

        chromiumTargetsSubscription = chromiumBrowserExtensionController.$targets
            .sink { [weak self] targets in
                MainActor.assumeIsolated {
                    self?.replaceChromiumTargets(targets)
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

    private func replaceMediaRemoteTargets(_ targets: [MediaRemoteTarget]) {
        latestMediaRemoteTargets = targets
        rememberMediaRemoteTargets(from: targets)
        rebuildRows()
    }

    private func replaceActiveTargetID(_ activeTargetID: String?) {
        self.activeTargetID = activeTargetID
        publishTargets()
    }

    private func replaceChromiumTargets(_ targets: [MediaRemoteTarget]) {
        latestChromiumTargets = targets
        rebuildRows()
    }

    private func rebuildRows() {
        let updatedRows = rowTargets().map { target in
            SourceRow(target: target, reachability: reachability(for: target))
        }
        guard updatedRows != rows else {
            publishTargets()
            return
        }
        rows = updatedRows
        publishTargets()
    }

    private func publishTargets() {
        let targets = rows.map(\.target)
        let visibleActiveTargetID = activeTargetID.flatMap { activeTargetID in
            targets.contains { $0.id == activeTargetID } ? activeTargetID : nil
        }
        targetsChanged(targets, visibleActiveTargetID, latestMediaRemoteTargets.count)
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
            rememberMediaRemoteTargets(from: latestMediaRemoteTargets)
        }
        rebuildRows()
    }

    private func rowTargets() -> [MediaRemoteTarget] {
        let currentTargets = mergedTargets(
            mediaRemoteTargets: latestMediaRemoteTargets,
            chromiumTargets: latestChromiumTargets
        )
        guard let helperDegradedSince,
              now().timeIntervalSince(helperDegradedSince) <= MediaRemoteController.helperRecoveryGraceInterval
        else {
            return currentTargets
        }

        let knownTargetIDs = Set(currentTargets.map(\.id))
        let retainedTargets = retainedMediaRemoteTargets.filter { target in
            !knownTargetIDs.contains(target.id)
        }
        return currentTargets + retainedTargets
    }

    private func mergedTargets(
        mediaRemoteTargets: [MediaRemoteTarget],
        chromiumTargets: [MediaRemoteTarget]
    ) -> [MediaRemoteTarget] {
        let visibleMediaRemoteTargets = mediaRemoteTargets.filter { target in
            !chromiumTargets.contains {
                ChromiumBrowserExtensionTransport.shadowsLegacyTarget(extensionTarget: $0, legacyTarget: target)
            }
        }
        return visibleMediaRemoteTargets + chromiumTargets.filter { chromiumTarget in
            !visibleMediaRemoteTargets.contains { $0.id == chromiumTarget.id }
        }
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
