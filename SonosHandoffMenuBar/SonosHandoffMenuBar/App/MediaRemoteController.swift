import Combine
import Foundation
import os
import SonosHandoffCore

@MainActor
final class MediaRemoteController: ObservableObject {
    private static let ignoredBundleIdentifiers: Set<String> = ["com.fpieringer.Keyway"]
    private static let relaunchDelayNanoseconds: [UInt64] = [
        250_000_000,
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000,
    ]
    private static let snapshotPollInterval: TimeInterval = 1
    private static let pingInterval: TimeInterval = 1
    private static let pongFreshnessInterval: TimeInterval = 2.5
    static let helperRecoveryGraceInterval: TimeInterval = 5
    private static let snapshotRefreshTimeoutNanoseconds: UInt64 = 6_000_000_000
    private static let commandResultTimeoutNanoseconds: UInt64 = 350_000_000
    private static let routeShieldResultTimeoutNanoseconds: UInt64 = 1_000_000_000
    private static let terminationDeadlineNanoseconds: UInt64 = 2_000_000_000

    @Published private(set) var health: MediaRemoteHelperHealth = .stopped
    @Published private(set) var helperGeneration: UInt = 0
    @Published private(set) var targets: [MediaRemoteTarget] = []
    @Published private(set) var activeTargetID: String?
    @Published private(set) var isRefreshingSnapshot = false
    @Published private(set) var helperDegradedSince: Date?

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "MediaRemote")
    private let decoder = JSONDecoder()
    private lazy var snapshotHelper = MediaRemoteHelperProcess(role: .snapshot, logger: logger)
    private lazy var commandHelper = MediaRemoteHelperProcess(role: .command, logger: logger)
    private var refreshTimer: Timer?
    private var pingTimer: Timer?
    private var recoveryTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?
    private var helperRecoveryGraceTask: Task<Void, Never>?
    private var notificationDebounce: Task<Void, Never>?
    private var commandRequestStartedAt: [String: TimeInterval] = [:]
    private var commandResultHandlers: [String: (MediaRemoteCommandResultEvent) -> Void] = [:]
    private var commandRequestTimeouts: [String: Task<Void, Never>] = [:]
    private var routeShieldResultHandlers: [String: (Bool) -> Void] = [:]
    private var commandCacheRefreshRequestIDs: Set<String> = []
    private var commandCacheRefreshTargetSignatures: [String: String] = [:]
    private var commandCacheTargetSignature = ""
    private var refreshGate = MediaRemoteSnapshotRefreshGate()
    private var pendingRefreshRequested = false
    private var snapshotRefreshTimeout: Task<Void, Never>?
    private var restartAttempts = 0
    private var helperPairState = MediaRemoteHelperPairState()
    private var supervisorState = MediaRemoteHelperSupervisorState()
    private var pendingPingRolesByRequestID: [String: (role: MediaRemoteHelperRole, sentAt: Date)] = [:]
    private var lastPongAtByRole: [MediaRemoteHelperRole: Date] = [:]

    var isHelperPairReady: Bool {
        helperPairState.isReady
            && health.state == .running
            && snapshotHelper.isRunning
            && commandHelper.isRunning
    }

    func start() {
        guard !supervisorState.shouldRun else {
            return
        }
        supervisorState.start()
        launchPendingHelperPair()
    }

    private func launchPendingHelperPair() {
        let hasOwnedProcesses = snapshotHelper.hasOwnedProcesses || commandHelper.hasOwnedProcesses
        guard supervisorState.canLaunch(hasOwnedProcesses: hasOwnedProcesses) else {
            return
        }
        supervisorState.didLaunch()
        cancelTerminationDeadline()
        health = MediaRemoteHelperHealth(
            state: .starting,
            message: "Starting /usr/bin/perl MediaRemote helper",
            pid: nil,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: targets.count
        )

        do {
            let resources = try helperResources()
            helperPairState.reset()
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
            let readinessStartedAt = Date()
            helperDegradedSince = readinessStartedAt
            scheduleHelperRecoveryGrace(
                since: readinessStartedAt,
                message: "MediaRemote snapshot and command helpers did not both become ready."
            )
        } catch {
            recoverHelperPair(message: "Could not start MediaRemote helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        supervisorState.stop()
        cancelRecoveryTask()
        cancelTerminationDeadline()
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopPingTimer()
        cancelHelperRecoveryGrace()
        stopHelperPair()
        helperPairState.reset()
        clearAllTargets()
        clearCommandState()
        clearPingState()
        refreshGate.reset()
        snapshotRefreshTimeout?.cancel()
        snapshotRefreshTimeout = nil
        pendingRefreshRequested = false
        helperDegradedSince = nil
        health = .stopped
    }

    func restart() {
        stop()
        restartAttempts = 0
        supervisorState.start()
        launchPendingHelperPair()
    }

    @discardableResult
    func refreshSnapshot() -> Bool {
        guard helperPairState.isReady,
              snapshotHelper.isRunning,
              commandHelper.isRunning
        else {
            return false
        }
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
            recoverHelperPair(message: "Could not write refresh request to MediaRemote snapshot helper.")
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
        guard helperPairState.isReady,
              health.state == .running,
              commandHelper.isRunning
        else {
            probeHelperLiveness()
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
            recoverHelperPair(message: "Could not write command request to MediaRemote command helper.")
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

    @discardableResult
    func setRouteShield(
        info: [String: Any]?,
        onResult: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard helperPairState.isReady,
              health.state == .running,
              commandHelper.isRunning
        else {
            return false
        }

        let requestID = UUID().uuidString
        var request: [String: Any] = [
            "type": "setRouteShield",
            "requestID": requestID,
            "enabled": info != nil,
            "bundleIdentifier": AppIdentity.bundleIdentifier,
        ]
        if let info {
            request["info"] = info
        }
        routeShieldResultHandlers[requestID] = onResult
        let sent = commandHelper.send(request)
        guard sent else {
            routeShieldResultHandlers.removeValue(forKey: requestID)
            recoverHelperPair(message: "Could not write route-shield request to MediaRemote command helper.")
            return false
        }
        armRouteShieldResultTimeout(requestID: requestID)
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
                logger.info("MediaRemoteHelper role=\(role.rawValue, privacy: .public) ready pid=\(ready.pid ?? -1, privacy: .public)")
                guard helperPairState.markReady(role) else {
                    return
                }
                guard snapshotHelper.isRunning, commandHelper.isRunning else {
                    recoverHelperPair(message: "MediaRemote helper exited before its pair became ready.")
                    return
                }
                restartAttempts = 0
                cancelRecoveryTask()
                clearHelperDegraded()
                helperGeneration += 1
                health = MediaRemoteHelperHealth(
                    state: .running,
                    message: "Connected through \(ready.host ?? "/usr/bin/perl")",
                    pid: ready.pid,
                    lastSnapshotAt: health.lastSnapshotAt,
                    targetCount: targets.count
                )
                startRefreshTimer()
                startPingTimer()
                warmCommandClientCache(reason: "helper_pair_ready")
                refreshSnapshot()
            case "pong":
                let pong = try decoder.decode(MediaRemotePongEvent.self, from: line)
                handlePong(pong, role: role)
            case "snapshot":
                let snapshot = try decoder.decode(MediaRemoteSnapshotEvent.self, from: line)
                guard helperPairState.isReady else {
                    logger.info("MediaRemoteHelper snapshot_ignored reason=helper_pair_not_ready")
                    return
                }
                guard refreshGate.finish(requestID: snapshot.requestID) else {
                    logger.info("MediaRemoteHelper stale_snapshot_ignored requestID=\(snapshot.requestID ?? "", privacy: .public)")
                    return
                }
                snapshotRefreshTimeout?.cancel()
                snapshotRefreshTimeout = nil
                targets = snapshot.targets.filter { !Self.isIgnoredTarget($0) }
                let rawActiveTargetID = snapshot.activeTargetID.flatMap { $0.isEmpty ? nil : $0 }
                activeTargetID = targets.contains { $0.id == rawActiveTargetID }
                    ? rawActiveTargetID
                    : nil
                isRefreshingSnapshot = false
                health = MediaRemoteHelperHealth(
                    state: .running,
                    message: "MediaRemote snapshot loaded",
                    pid: health.pid,
                    lastSnapshotAt: Date(),
                    targetCount: targets.count
                )
                warmCommandClientCacheIfNeeded(targets: targets, reason: "snapshot_targets")
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
            case "routeShieldResult":
                guard role == .command else {
                    recoverHelperPair(message: "MediaRemote snapshot helper emitted a route-shield result.")
                    return
                }
                let result = try decoder.decode(MediaRemoteRouteShieldResultEvent.self, from: line)
                guard let requestID = result.requestID,
                      let resultHandler = routeShieldResultHandlers.removeValue(forKey: requestID)
                else {
                    logger.info("MediaRemoteHelper stale_route_shield_result_ignored requestID=\(result.requestID ?? "", privacy: .public)")
                    return
                }
                commandRequestTimeouts.removeValue(forKey: requestID)?.cancel()
                if result.ok {
                    logger.info("MediaRemoteHelper routeShield=\(result.enabled ? "enabled" : "disabled", privacy: .public) message=\(result.message, privacy: .public)")
                } else {
                    logger.error("MediaRemoteHelper routeShield=failed enabled=\(result.enabled, privacy: .public) message=\(result.message, privacy: .public)")
                }
                resultHandler(result.ok)
            case "now_playing_changed":
                debouncedRefresh()
            case "fatal", "error":
                let error = try decoder.decode(MediaRemoteErrorEvent.self, from: line)
                if let requestID = error.requestID {
                    commandRequestTimeouts.removeValue(forKey: requestID)?.cancel()
                    commandRequestStartedAt[requestID] = nil
                    commandResultHandlers[requestID] = nil
                    commandCacheRefreshRequestIDs.remove(requestID)
                    commandCacheRefreshTargetSignatures[requestID] = nil
                }
                recoverHelperPair(message: error.message)
            default:
                logger.info("MediaRemoteHelper ignored event=\(envelope.type, privacy: .public)")
            }
        } catch {
            logger.error("MediaRemoteHelper role=\(role.rawValue, privacy: .public) parse_error=\(error.localizedDescription, privacy: .public)")
            recoverHelperPair(message: "MediaRemote \(role.rawValue) helper emitted invalid JSON.")
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
            self.recoverHelperPair(message: "MediaRemote snapshot helper timed out.")
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
        if !snapshotHelper.hasOwnedProcesses, !commandHelper.hasOwnedProcesses {
            cancelTerminationDeadline()
        }

        if stopped {
            logger.info("MediaRemoteHelper stopped_termination role=\(role.rawValue, privacy: .public) status=\(status, privacy: .public)")
            launchPendingHelperPair()
            return
        }

        guard supervisorState.shouldRun else {
            return
        }

        recoverHelperPair(message: "MediaRemote \(role.rawValue) helper exited with status \(status).")
    }

    private func handleHelperFailure(_ message: String, role: MediaRemoteHelperRole) {
        logger.error("MediaRemoteHelper role=\(role.rawValue, privacy: .public) failure=\(message, privacy: .public)")
        recoverHelperPair(message: message)
    }

    private func recoverHelperPair(message: String) {
        guard supervisorState.shouldRun else {
            return
        }
        stopHelperPair()
        helperPairState.reset()
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopPingTimer()
        beginHelperRecovery(message: message)
        scheduleRelaunch()
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
            pid: nil,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: targets.count
        )
    }

    private func beginHelperRecovery(message: String) {
        logger.error("MediaRemoteHelper recovering=\(message, privacy: .public)")
        let degradedSince = helperDegradedSince ?? Date()
        helperDegradedSince = degradedSince
        clearMediaRemoteTargets()
        isRefreshingSnapshot = false
        refreshGate.reset()
        snapshotRefreshTimeout?.cancel()
        snapshotRefreshTimeout = nil
        pendingRefreshRequested = false
        clearCommandState()
        clearPingState()
        health = MediaRemoteHelperHealth(
            state: .starting,
            message: "\(message) Retrying helper.",
            pid: nil,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: targets.count
        )
        scheduleHelperRecoveryGrace(since: degradedSince, message: message)
    }

    private func scheduleRelaunch() {
        guard supervisorState.shouldRun, recoveryTask == nil else {
            return
        }

        let delay = Self.relaunchDelayNanoseconds[min(restartAttempts, Self.relaunchDelayNanoseconds.count - 1)]
        restartAttempts += 1
        recoveryTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(nanoseconds: delay)) != nil else {
                return
            }
            guard let self else {
                return
            }
            self.recoveryTask = nil
            self.supervisorState.requestRelaunch()
            self.launchPendingHelperPair()
        }
    }

    private func cancelRecoveryTask() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func stopHelperPair() {
        snapshotHelper.stop()
        commandHelper.stop()
        guard snapshotHelper.hasOwnedProcesses || commandHelper.hasOwnedProcesses else {
            return
        }
        armTerminationDeadline()
    }

    private func armTerminationDeadline() {
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(nanoseconds: Self.terminationDeadlineNanoseconds)) != nil,
                  let self,
                  self.snapshotHelper.hasOwnedProcesses || self.commandHelper.hasOwnedProcesses
            else {
                return
            }
            self.terminationDeadlineTask = nil
            self.logger.error("MediaRemoteHelper termination_deadline_exceeded=true")
            self.snapshotHelper.forceTerminateStoppedProcesses()
            self.commandHelper.forceTerminateStoppedProcesses()
        }
    }

    private func cancelTerminationDeadline() {
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = nil
    }

    private func clearMediaRemoteTargets() {
        targets = []
        activeTargetID = nil
    }

    private func clearAllTargets() {
        targets = []
        activeTargetID = nil
    }

    private func clearCommandState() {
        commandRequestTimeouts.values.forEach { $0.cancel() }
        commandRequestTimeouts.removeAll()
        commandRequestStartedAt.removeAll()
        commandResultHandlers.removeAll()
        let routeShieldResultHandlers = self.routeShieldResultHandlers.values
        self.routeShieldResultHandlers.removeAll()
        routeShieldResultHandlers.forEach { $0(false) }
        commandCacheRefreshRequestIDs.removeAll()
        commandCacheRefreshTargetSignatures.removeAll()
        commandCacheTargetSignature = ""
    }

    @discardableResult
    func probeHelperLiveness() -> Bool {
        let snapshotPingSent = ping(role: .snapshot)
        let commandPingSent = ping(role: .command)
        return snapshotPingSent || commandPingSent
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        sendPingSweep()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendPingSweep()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPingSweep() {
        let now = Date()
        pendingPingRolesByRequestID = pendingPingRolesByRequestID.filter {
            now.timeIntervalSince($0.value.sentAt) <= Self.pingInterval * 3
        }
        guard ping(role: .snapshot) else {
            return
        }
        ping(role: .command)
        updatePingLiveness()
    }

    @discardableResult
    private func ping(role: MediaRemoteHelperRole) -> Bool {
        let helper = role == .snapshot ? snapshotHelper : commandHelper
        guard helper.isRunning else {
            return false
        }

        let requestID = "ping-\(role.rawValue)-\(UUID().uuidString)"
        let sent = helper.send([
            "type": "ping",
            "requestID": requestID,
        ])
        guard sent else {
            recoverHelperPair(message: "Could not write ping request to MediaRemote \(role.rawValue) helper.")
            return false
        }
        pendingPingRolesByRequestID[requestID] = (role: role, sentAt: Date())
        return true
    }

    private func handlePong(_ pong: MediaRemotePongEvent, role: MediaRemoteHelperRole) {
        guard let requestID = pong.requestID,
              let pending = pendingPingRolesByRequestID.removeValue(forKey: requestID),
              pending.role == role
        else {
            logger.info("MediaRemoteHelper stale_pong_ignored role=\(role.rawValue, privacy: .public) requestID=\(pong.requestID ?? "", privacy: .public)")
            return
        }

        lastPongAtByRole[role] = Date()
        logger.info("MediaRemoteHelper pong role=\(role.rawValue, privacy: .public) pid=\(pong.pid ?? -1, privacy: .public) requestID=\(requestID, privacy: .public)")
        updatePingLiveness()
    }

    private func updatePingLiveness(now: Date = Date()) {
        guard health.state == .running,
              snapshotHelper.isRunning,
              commandHelper.isRunning
        else {
            return
        }

        let roles: [MediaRemoteHelperRole] = [.snapshot, .command]
        let pingLive = roles.allSatisfy { role in
            guard let lastPongAt = lastPongAtByRole[role] else {
                return false
            }
            return now.timeIntervalSince(lastPongAt) <= Self.pongFreshnessInterval
        }
        if pingLive {
            if helperDegradedSince != nil {
                clearHelperDegraded()
            }
            return
        }

        guard helperDegradedSince == nil else {
            return
        }

        helperDegradedSince = now
        scheduleHelperRecoveryGrace(since: now, message: "MediaRemote helper stopped answering pings.")
    }

    private func scheduleHelperRecoveryGrace(since: Date, message: String) {
        helperRecoveryGraceTask?.cancel()
        let elapsed = Date().timeIntervalSince(since)
        let remainingNanoseconds = elapsed >= Self.helperRecoveryGraceInterval
            ? UInt64(0)
            : UInt64((Self.helperRecoveryGraceInterval - elapsed) * 1_000_000_000)
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
            self.stopHelperPair()
            self.helperPairState.reset()
            self.stopPingTimer()
            self.clearPingState()
            self.markFailed(message)
            self.scheduleRelaunch()
        }
    }

    private func clearHelperDegraded() {
        helperDegradedSince = nil
        cancelHelperRecoveryGrace()
    }

    private func cancelHelperRecoveryGrace() {
        helperRecoveryGraceTask?.cancel()
        helperRecoveryGraceTask = nil
    }

    private func clearPingState() {
        pendingPingRolesByRequestID.removeAll()
        lastPongAtByRole.removeAll()
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
            recoverHelperPair(message: "Could not write cache request to MediaRemote command helper.")
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

    private func armRouteShieldResultTimeout(requestID: String) {
        commandRequestTimeouts[requestID]?.cancel()
        commandRequestTimeouts[requestID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.routeShieldResultTimeoutNanoseconds)
            guard let self,
                  let resultHandler = self.routeShieldResultHandlers.removeValue(forKey: requestID)
            else {
                return
            }

            self.commandRequestTimeouts[requestID] = nil
            self.logger.error("MediaRemoteHelper route_shield_timeout requestID=\(requestID, privacy: .public)")
            resultHandler(false)
        }
    }

    private static func isIgnoredTarget(_ target: MediaRemoteTarget) -> Bool {
        ignoredBundleIdentifiers.contains(target.bundleIdentifier)
            || ignoredBundleIdentifiers.contains(target.parentBundleIdentifier)
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
