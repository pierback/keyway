import Combine
import Foundation
import os

@MainActor
final class MediaRemoteController: ObservableObject {
    private static let ignoredBundleIdentifiers: Set<String> = ["com.fpieringer.Keyway"]
    private static let maxImmediateRestartAttempts = 2
    private static let immediateRestartDelayNanoseconds: UInt64 = 250_000_000
    private static let snapshotPollInterval: TimeInterval = 1
    private static let periodicRecoveryInterval: TimeInterval = 60
    private static let snapshotRefreshTimeoutNanoseconds: UInt64 = 6_000_000_000
    private static let commandResultTimeoutNanoseconds: UInt64 = 350_000_000

    @Published private(set) var health: MediaRemoteHelperHealth = .stopped
    @Published private(set) var targets: [MediaRemoteTarget] = []
    @Published private(set) var activeTargetID: String?
    @Published private(set) var isRefreshingSnapshot = false

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "MediaRemote")
    private let chromiumBrowserExtensionController: ChromiumBrowserExtensionController
    private let decoder = JSONDecoder()
    private lazy var snapshotHelper = MediaRemoteHelperProcess(role: .snapshot, logger: logger)
    private lazy var commandHelper = MediaRemoteHelperProcess(role: .command, logger: logger)
    private var chromiumTargetsSubscription: AnyCancellable?
    private var mediaRemoteTargets: [MediaRemoteTarget] = []
    private var refreshTimer: Timer?
    private var recoveryTimer: Timer?
    private var notificationDebounce: Task<Void, Never>?
    private var commandRequestStartedAt: [String: TimeInterval] = [:]
    private var commandResultHandlers: [String: (MediaRemoteCommandResultEvent) -> Void] = [:]
    private var commandRequestTimeouts: [String: Task<Void, Never>] = [:]
    private var commandCacheRefreshRequestIDs: Set<String> = []
    private var commandCacheRefreshTargetSignatures: [String: String] = [:]
    private var commandCacheTargetSignature = ""
    private var refreshGate = MediaRemoteSnapshotRefreshGate()
    private var pendingRefreshRequested = false
    private var snapshotRefreshTimeout: Task<Void, Never>?
    private var restartAttempts = 0
    private var expectedTermination = false

    var activeTarget: MediaRemoteTarget? {
        guard let activeTargetID else {
            return nil
        }
        return targets.first { $0.id == activeTargetID }
    }

    var canRouteCommands: Bool {
        (health.state == .running && snapshotHelper.isRunning && commandHelper.isRunning)
            || chromiumBrowserExtensionController.hasRoutableTargets
    }

    init(chromiumBrowserExtensionController: ChromiumBrowserExtensionController = ChromiumBrowserExtensionController()) {
        self.chromiumBrowserExtensionController = chromiumBrowserExtensionController
        chromiumTargetsSubscription = chromiumBrowserExtensionController.$targets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.mergeVisibleTargets()
                }
            }
    }

    func hasFreshSnapshot(maxAge: TimeInterval) -> Bool {
        guard let lastSnapshotAt = health.lastSnapshotAt else {
            return false
        }
        return Date().timeIntervalSince(lastSnapshotAt) <= maxAge
    }

    func start() {
        guard !snapshotHelper.isRunning, !commandHelper.isRunning else {
            return
        }

        health = MediaRemoteHelperHealth(
            state: .starting,
            message: "Starting /usr/bin/perl MediaRemote helper",
            pid: nil,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: targets.count
        )

        do {
            let resources = try helperResources()
            expectedTermination = false
            cancelRecoveryTimer()
            try commandHelper.start(
                script: resources.script,
                dylib: resources.dylib,
                onLine: { [weak self] line in
                    self?.handleLine(line, role: .command)
                },
                onFailure: { [weak self] message in
                    self?.handleHelperFailure(message, role: .command)
                },
                onTermination: { [weak self] process, status in
                    self?.handleTermination(process, status: status, role: .command)
                }
            )
            try snapshotHelper.start(
                script: resources.script,
                dylib: resources.dylib,
                onLine: { [weak self] line in
                    self?.handleLine(line, role: .snapshot)
                },
                onFailure: { [weak self] message in
                    self?.handleHelperFailure(message, role: .snapshot)
                },
                onTermination: { [weak self] process, status in
                    self?.handleTermination(process, status: status, role: .snapshot)
                }
            )
            startRefreshTimer()
        } catch {
            snapshotHelper.stop()
            commandHelper.stop()
            markFailed("Could not start MediaRemote helper: \(error.localizedDescription)")
            schedulePeriodicRecovery()
        }
    }

    func stop() {
        expectedTermination = true
        cancelRecoveryTimer()
        refreshTimer?.invalidate()
        refreshTimer = nil
        snapshotHelper.stop()
        commandHelper.stop()
        clearAllTargets()
        clearCommandState()
        refreshGate.reset()
        snapshotRefreshTimeout?.cancel()
        snapshotRefreshTimeout = nil
        pendingRefreshRequested = false
        health = .stopped
    }

    func restart() {
        stop()
        restartAttempts = 0
        start()
    }

    @discardableResult
    func refreshSnapshot() -> Bool {
        guard let requestID = refreshGate.begin() else {
            pendingRefreshRequested = true
            logger.info("MediaRemoteHelper refresh_coalesced reason=in_flight")
            return false
        }
        isRefreshingSnapshot = true
        let sent = snapshotHelper.send([
            "type": "refresh",
            "requestID": requestID,
        ])
        guard sent else {
            refreshGate.finish(requestID: requestID)
            isRefreshingSnapshot = false
            pendingRefreshRequested = false
            markFailed("Could not write refresh request to MediaRemote snapshot helper.")
            return false
        }
        armSnapshotRefreshTimeout(requestID: requestID)
        return true
    }

    private func debouncedRefresh() {
        notificationDebounce?.cancel()
        notificationDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            refreshSnapshot()
        }
    }

    func submit(
        command: MediaRemoteTransportCommand,
        targetID: String,
        onResult: ((MediaRemoteCommandResultEvent) -> Void)? = nil
    ) -> Bool {
        guard canRouteCommands else {
            markFailed("MediaRemote helper is not ready.")
            return false
        }

        let requestID = UUID().uuidString
        let startedAt = ProcessInfo.processInfo.systemUptime
        logger.info("MediaRemoteHelper send_request requestID=\(requestID, privacy: .public) command=\(command.rawValue, privacy: .public) target=\(targetID, privacy: .public)")
        let sent = commandHelper.send([
            "type": "sendCommand",
            "requestID": requestID,
            "targetID": targetID,
            "command": command.rawValue,
        ])
        guard sent else {
            markFailed("Could not write command request to MediaRemote command helper.")
            return false
        }

        commandRequestStartedAt[requestID] = startedAt
        commandResultHandlers[requestID] = onResult
        armCommandResultTimeout(
            requestID: requestID,
            command: command,
            targetID: targetID
        )
        return true
    }

    private func helperResources() throws -> (script: URL, dylib: URL) {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw MediaRemoteControllerError.missingBundleResources
        }

        let directory = resourceURL.appendingPathComponent("MediaRemoteHelper", isDirectory: true)
        let script = directory.appendingPathComponent("keyway-mediaremote-helper.pl", isDirectory: false)
        let dylib = directory.appendingPathComponent("libkeyway_mediaremote.dylib", isDirectory: false)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw MediaRemoteControllerError.missingHelperScript(script.path)
        }
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw MediaRemoteControllerError.missingHelperDylib(dylib.path)
        }
        return (script, dylib)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.snapshotPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
    }

    private func handleLine(_ line: Data, role: MediaRemoteHelperRole) {
        do {
            let envelope = try decoder.decode(MediaRemoteEnvelope.self, from: line)
            switch envelope.type {
            case "ready":
                let ready = try decoder.decode(MediaRemoteReadyEvent.self, from: line)
                guard role == .snapshot else {
                    logger.info("MediaRemoteHelper command_ready pid=\(ready.pid ?? -1, privacy: .public)")
                    warmCommandClientCache(reason: "command_ready")
                    return
                }
                restartAttempts = 0
                cancelRecoveryTimer()
                health = MediaRemoteHelperHealth(
                    state: .running,
                    message: "Connected through \(ready.host ?? "/usr/bin/perl")",
                    pid: ready.pid,
                    lastSnapshotAt: health.lastSnapshotAt,
                    targetCount: targets.count
                )
                refreshSnapshot()
            case "pong":
                break
            case "snapshot":
                let snapshot = try decoder.decode(MediaRemoteSnapshotEvent.self, from: line)
                guard refreshGate.finish(requestID: snapshot.requestID) else {
                    logger.info("MediaRemoteHelper stale_snapshot_ignored requestID=\(snapshot.requestID ?? "", privacy: .public)")
                    return
                }
                snapshotRefreshTimeout?.cancel()
                snapshotRefreshTimeout = nil
                mediaRemoteTargets = snapshot.targets.filter { !Self.isIgnoredTarget($0) }
                let visibleTargets = chromiumBrowserExtensionController.targetsIncludingBrowserExtensionTargets(mediaRemoteTargets)
                targets = visibleTargets
                activeTargetID = visibleTargets.contains { $0.id == snapshot.activeTargetID }
                    ? Self.nilIfEmpty(snapshot.activeTargetID)
                    : nil
                ShortcutRuntimeStatus.shared.updateMediaTargets(
                    visibleTargets,
                    activeTargetID: activeTargetID,
                    rawTargetCount: snapshot.targets.count,
                    rawActiveTargetID: Self.nilIfEmpty(snapshot.activeTargetID)
                )
                isRefreshingSnapshot = false
                health = MediaRemoteHelperHealth(
                    state: .running,
                    message: "MediaRemote snapshot loaded",
                    pid: health.pid,
                    lastSnapshotAt: Date(),
                    targetCount: visibleTargets.count
                )
                warmCommandClientCacheIfNeeded(targets: visibleTargets, reason: "snapshot_targets")
                drainPendingRefreshIfNeeded()
            case "commandResult":
                let result = try decoder.decode(MediaRemoteCommandResultEvent.self, from: line)
                let elapsedMilliseconds = commandElapsedMilliseconds(requestID: result.requestID)
                let resultHandler = commandResultHandler(requestID: result.requestID)
                if result.ok {
                    logger.info("MediaRemoteHelper command=\(result.command, privacy: .public) target=\(result.targetID, privacy: .public) ok=true elapsedMs=\(elapsedMilliseconds, privacy: .public) message=\(result.message, privacy: .public)")
                    refreshSnapshot()
                } else {
                    logger.error("MediaRemoteHelper command=\(result.command, privacy: .public) target=\(result.targetID, privacy: .public) ok=false elapsedMs=\(elapsedMilliseconds, privacy: .public) message=\(result.message, privacy: .public)")
                    refreshSnapshot()
                }
                resultHandler?(result)
            case "clientCache":
                let result = try decoder.decode(MediaRemoteClientCacheEvent.self, from: line)
                let cacheRefresh = finishCommandCacheRefresh(requestID: result.requestID)
                if result.ok {
                    markCommandCacheReady(targetSignature: cacheRefresh.targetSignature, targetCount: result.targetCount)
                    logger.info("MediaRemoteHelper command_cache_ready targetCount=\(result.targetCount, privacy: .public) elapsedMs=\(cacheRefresh.elapsedMilliseconds, privacy: .public) message=\(result.message, privacy: .public)")
                } else {
                    commandCacheTargetSignature = ""
                    logger.info("MediaRemoteHelper command_cache_empty targetCount=\(result.targetCount, privacy: .public) elapsedMs=\(cacheRefresh.elapsedMilliseconds, privacy: .public) message=\(result.message, privacy: .public)")
                }
            case "now_playing_changed":
                debouncedRefresh()
            case "fatal", "error":
                let error = try decoder.decode(MediaRemoteErrorEvent.self, from: line)
                if error.requestID == nil {
                    refreshGate.reset()
                    snapshotRefreshTimeout?.cancel()
                    snapshotRefreshTimeout = nil
                    isRefreshingSnapshot = false
                } else if refreshGate.finish(requestID: error.requestID) {
                    snapshotRefreshTimeout?.cancel()
                    snapshotRefreshTimeout = nil
                    isRefreshingSnapshot = false
                }
                if let requestID = error.requestID {
                    commandRequestTimeouts.removeValue(forKey: requestID)?.cancel()
                    commandRequestStartedAt[requestID] = nil
                    commandResultHandlers[requestID] = nil
                    commandCacheRefreshRequestIDs.remove(requestID)
                    commandCacheRefreshTargetSignatures[requestID] = nil
                }
                markFailed(error.message)
            default:
                logger.info("MediaRemoteHelper ignored event=\(envelope.type, privacy: .public)")
            }
        } catch {
            logger.error("MediaRemoteHelper parse_error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func drainPendingRefreshIfNeeded() {
        guard pendingRefreshRequested, !refreshGate.isRefreshing else {
            return
        }

        pendingRefreshRequested = false
        logger.info("MediaRemoteHelper refresh_followup reason=coalesced")
        refreshSnapshot()
    }

    private func mergeVisibleTargets() {
        let visibleTargets = chromiumBrowserExtensionController.targetsIncludingBrowserExtensionTargets(mediaRemoteTargets)
        targets = visibleTargets
        if let activeTargetID, !visibleTargets.contains(where: { $0.id == activeTargetID }) {
            self.activeTargetID = nil
        }
        ShortcutRuntimeStatus.shared.updateMediaTargets(
            visibleTargets,
            activeTargetID: activeTargetID,
            rawTargetCount: mediaRemoteTargets.count,
            rawActiveTargetID: activeTargetID
        )
        health = MediaRemoteHelperHealth(
            state: health.state,
            message: health.message,
            pid: health.pid,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: visibleTargets.count
        )
    }

    private func armSnapshotRefreshTimeout(requestID: String) {
        snapshotRefreshTimeout?.cancel()
        snapshotRefreshTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.snapshotRefreshTimeoutNanoseconds)
            guard let self,
                  self.refreshGate.finish(requestID: requestID)
            else {
                return
            }

            self.snapshotRefreshTimeout = nil
            self.isRefreshingSnapshot = false
            self.logger.error("MediaRemoteHelper refresh_timeout requestID=\(requestID, privacy: .public)")
            self.drainPendingRefreshIfNeeded()
        }
    }

    private func handleTermination(_ terminatedProcess: Process, status: Int32, role: MediaRemoteHelperRole) {
        let helper = role == .snapshot ? snapshotHelper : commandHelper
        let owned = helper.owns(terminatedProcess)
        let stopped = helper.ownsStopped(terminatedProcess)
        guard owned || stopped else {
            logger.info("MediaRemoteHelper ignored_stale_termination role=\(role.rawValue, privacy: .public) status=\(status, privacy: .public)")
            return
        }
        helper.retire(terminatedProcess)

        if stopped {
            if expectedTermination {
                expectedTermination = false
            }
            logger.info("MediaRemoteHelper stopped_termination role=\(role.rawValue, privacy: .public) status=\(status, privacy: .public)")
            return
        }

        if !expectedTermination, !snapshotHelper.isRunning, !commandHelper.isRunning {
            logger.info("MediaRemoteHelper ignored_unowned_termination role=\(role.rawValue, privacy: .public) status=\(status, privacy: .public)")
            return
        }

        snapshotHelper.stop()
        commandHelper.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        clearCommandState()
        refreshGate.reset()
        snapshotRefreshTimeout?.cancel()
        snapshotRefreshTimeout = nil
        pendingRefreshRequested = false

        guard !expectedTermination else {
            expectedTermination = false
            return
        }

        markFailed("MediaRemote \(role.rawValue) helper exited with status \(status).")
        guard restartAttempts < Self.maxImmediateRestartAttempts else {
            schedulePeriodicRecovery()
            return
        }

        restartAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.immediateRestartDelayNanoseconds)
            self?.start()
        }
    }

    private func handleHelperFailure(_ message: String, role: MediaRemoteHelperRole) {
        logger.error("MediaRemoteHelper role=\(role.rawValue, privacy: .public) failure=\(message, privacy: .public)")
        snapshotHelper.stop()
        commandHelper.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        clearCommandState()
        refreshGate.reset()
        snapshotRefreshTimeout?.cancel()
        snapshotRefreshTimeout = nil
        pendingRefreshRequested = false
        markFailed(message)

        guard restartAttempts < Self.maxImmediateRestartAttempts else {
            schedulePeriodicRecovery()
            return
        }

        restartAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.immediateRestartDelayNanoseconds)
            self?.start()
        }
    }

    private func markFailed(_ message: String) {
        logger.error("MediaRemoteHelper failed=\(message, privacy: .public)")
        clearMediaRemoteTargets()
        isRefreshingSnapshot = false
        refreshGate.reset()
        snapshotRefreshTimeout?.cancel()
        snapshotRefreshTimeout = nil
        pendingRefreshRequested = false
        clearCommandState()
        health = MediaRemoteHelperHealth(
            state: .failed,
            message: message,
            pid: health.pid,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: targets.count
        )
    }

    private func schedulePeriodicRecovery() {
        guard recoveryTimer == nil else {
            return
        }

        health = MediaRemoteHelperHealth(
            state: .failed,
            message: "\(health.message) Keyway will retry the helper every \(Int(Self.periodicRecoveryInterval)) seconds.",
            pid: health.pid,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: targets.count
        )
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: Self.periodicRecoveryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.snapshotHelper.isRunning, !self.commandHelper.isRunning else {
                    return
                }
                self.restartAttempts = 0
                self.start()
            }
        }
    }

    private func cancelRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    private func clearMediaRemoteTargets() {
        mediaRemoteTargets = []
        mergeVisibleTargets()
    }

    private func clearAllTargets() {
        mediaRemoteTargets = []
        targets = []
        activeTargetID = nil
        ShortcutRuntimeStatus.shared.updateMediaTargets([], activeTargetID: nil, rawTargetCount: 0)
    }

    private func clearCommandState() {
        commandRequestTimeouts.values.forEach { $0.cancel() }
        commandRequestTimeouts.removeAll()
        commandRequestStartedAt.removeAll()
        commandResultHandlers.removeAll()
        commandCacheRefreshRequestIDs.removeAll()
        commandCacheRefreshTargetSignatures.removeAll()
        commandCacheTargetSignature = ""
    }

    private func warmCommandClientCacheIfNeeded(targets: [MediaRemoteTarget], reason: String) {
        let signature = targets.map(\.id).joined(separator: "|")
        guard signature != commandCacheTargetSignature else {
            return
        }
        warmCommandClientCache(reason: reason, targetSignature: signature)
    }

    @discardableResult
    private func warmCommandClientCache(reason: String, targetSignature: String? = nil) -> Bool {
        guard commandHelper.isRunning,
              commandRequestStartedAt.isEmpty,
              commandCacheRefreshRequestIDs.isEmpty
        else {
            return false
        }

        let requestID = UUID().uuidString
        let sent = commandHelper.send([
            "type": "refreshClientCache",
            "requestID": requestID,
        ])
        guard sent else {
            return false
        }

        commandCacheRefreshRequestIDs.insert(requestID)
        commandCacheRefreshTargetSignatures[requestID] = targetSignature
        commandRequestStartedAt[requestID] = ProcessInfo.processInfo.systemUptime
        armCommandCacheRefreshTimeout(requestID: requestID)
        logger.info("MediaRemoteHelper command_cache_refresh reason=\(reason, privacy: .public) requestID=\(requestID, privacy: .public)")
        return true
    }

    private func armCommandCacheRefreshTimeout(requestID: String) {
        commandRequestTimeouts[requestID]?.cancel()
        commandRequestTimeouts[requestID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.commandResultTimeoutNanoseconds)
            guard let self,
                  self.commandCacheRefreshRequestIDs.remove(requestID) != nil
            else {
                return
            }

            self.commandRequestTimeouts[requestID] = nil
            let elapsedMilliseconds = self.finishCommandRequestTiming(requestID: requestID)
            self.commandCacheTargetSignature = ""
            self.commandCacheRefreshTargetSignatures[requestID] = nil
            self.logger.error("MediaRemoteHelper command_cache_timeout requestID=\(requestID, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
        }
    }

    private func armCommandResultTimeout(
        requestID: String,
        command: MediaRemoteTransportCommand,
        targetID: String
    ) {
        commandRequestTimeouts[requestID]?.cancel()
        commandRequestTimeouts[requestID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.commandResultTimeoutNanoseconds)
            guard let self,
                  let startedAt = self.commandRequestStartedAt.removeValue(forKey: requestID)
            else {
                return
            }

            self.commandRequestTimeouts[requestID] = nil
            let resultHandler = self.commandResultHandlers.removeValue(forKey: requestID)
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            self.logger.error("MediaRemoteHelper command_timeout requestID=\(requestID, privacy: .public) command=\(command.rawValue, privacy: .public) target=\(targetID, privacy: .public) elapsedMs=\(Int((elapsed * 1000).rounded()), privacy: .public)")
            resultHandler?(MediaRemoteCommandResultEvent(
                type: "commandResult",
                requestID: requestID,
                targetID: targetID,
                command: command.rawValue,
                ok: false,
                message: "MediaRemote command timed out",
                backend: nil
            ))
            self.warmCommandClientCacheIfNeeded(targets: self.targets, reason: "command_timeout")
        }
    }

    private static func isIgnoredTarget(_ target: MediaRemoteTarget) -> Bool {
        ignoredBundleIdentifiers.contains(target.bundleIdentifier)
            || ignoredBundleIdentifiers.contains(target.parentBundleIdentifier)
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func commandElapsedMilliseconds(requestID: String?) -> Int {
        guard let requestID else {
            return -1
        }
        commandRequestTimeouts.removeValue(forKey: requestID)?.cancel()
        return finishCommandRequestTiming(requestID: requestID)
    }

    private func finishCommandCacheRefresh(requestID: String?) -> (elapsedMilliseconds: Int, targetSignature: String?) {
        guard let requestID else {
            return (-1, nil)
        }
        commandRequestTimeouts.removeValue(forKey: requestID)?.cancel()
        commandCacheRefreshRequestIDs.remove(requestID)
        let targetSignature = commandCacheRefreshTargetSignatures.removeValue(forKey: requestID)
        return (finishCommandRequestTiming(requestID: requestID), targetSignature)
    }

    private func markCommandCacheReady(targetSignature: String?, targetCount: Int) {
        guard targetCount > 0,
              let targetSignature
        else {
            commandCacheTargetSignature = ""
            return
        }
        commandCacheTargetSignature = targetSignature
    }

    private func finishCommandRequestTiming(requestID: String) -> Int {
        guard let startedAt = commandRequestStartedAt.removeValue(forKey: requestID) else {
            return -1
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        return Int((elapsed * 1000).rounded())
    }

    private func commandResultHandler(requestID: String?) -> ((MediaRemoteCommandResultEvent) -> Void)? {
        guard let requestID else {
            return nil
        }
        return commandResultHandlers.removeValue(forKey: requestID)
    }
}
