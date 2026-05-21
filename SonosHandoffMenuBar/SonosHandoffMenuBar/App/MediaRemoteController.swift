import Combine
import Foundation
import os

@MainActor
final class MediaRemoteController: ObservableObject {
    private static let maxImmediateRestartAttempts = 2
    private static let immediateRestartDelayNanoseconds: UInt64 = 1_000_000_000
    private static let periodicRecoveryInterval: TimeInterval = 60
    private static let maxOutputBufferBytes = 1_048_576
    private static let snapshotWaitTimeoutNanoseconds: UInt64 = 1_500_000_000
    private static let commandWaitTimeoutNanoseconds: UInt64 = 5_500_000_000

    @Published private(set) var health: MediaRemoteHelperHealth = .stopped
    @Published private(set) var targets: [MediaRemoteTarget] = []
    @Published private(set) var activeTargetID: String?
    @Published private(set) var isRefreshingSnapshot = false

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "MediaRemote")
    private let decoder = JSONDecoder()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = Data()
    private var refreshTimer: Timer?
    private var recoveryTimer: Timer?
    private var notificationDebounce: Task<Void, Never>?
    private var snapshotWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var commandWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var restartAttempts = 0
    private var expectedTermination = false

    var activeTarget: MediaRemoteTarget? {
        guard let activeTargetID else {
            return nil
        }
        return targets.first { $0.id == activeTargetID }
    }

    var canRouteCommands: Bool {
        health.state == .running && inputPipe != nil && process != nil
    }

    func hasFreshSnapshot(maxAge: TimeInterval) -> Bool {
        guard let lastSnapshotAt = health.lastSnapshotAt else {
            return false
        }
        return Date().timeIntervalSince(lastSnapshotAt) <= maxAge
    }

    func start() {
        guard process == nil else {
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
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [resources.script.path, resources.dylib.path]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { [weak self] terminatedProcess in
                Task { @MainActor [weak self] in
                    self?.handleTermination(terminatedProcess, status: terminatedProcess.terminationStatus)
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.handleOutput(data)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.logger.error("MediaRemoteHelper stderr=\(message, privacy: .public)")
                }
            }

            expectedTermination = false
            cancelRecoveryTimer()
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            startRefreshTimer()
        } catch {
            markFailed("Could not start MediaRemote helper: \(error.localizedDescription)")
            schedulePeriodicRecovery()
        }
    }

    func stop() {
        expectedTermination = true
        cancelRecoveryTimer()
        refreshTimer?.invalidate()
        refreshTimer = nil
        inputPipe = nil
        process?.terminate()
        process = nil
        clearTargets()
        completeSnapshotWaiters(result: false)
        completeCommandWaiters(result: false)
        outputBuffer.removeAll()
        health = .stopped
    }

    func restart() {
        stop()
        restartAttempts = 0
        start()
    }

    @discardableResult
    func refreshSnapshot() -> Bool {
        isRefreshingSnapshot = true
        let sent = sendRequest([
            "type": "refresh",
            "requestID": UUID().uuidString,
        ])
        if !sent {
            isRefreshingSnapshot = false
        }
        return sent
    }

    func refreshSnapshotAndWait(
        timeoutNanoseconds: UInt64 = MediaRemoteController.snapshotWaitTimeoutNanoseconds
    ) async -> Bool {
        let requestID = UUID().uuidString
        isRefreshingSnapshot = true
        let sent = sendRequest([
            "type": "refresh",
            "requestID": requestID,
        ])
        guard sent else {
            isRefreshingSnapshot = false
            return false
        }

        return await withCheckedContinuation { continuation in
            snapshotWaiters[requestID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self,
                      let waiter = self.snapshotWaiters.removeValue(forKey: requestID)
                else {
                    return
                }
                self.isRefreshingSnapshot = false
                waiter.resume(returning: false)
            }
        }
    }

    private func debouncedRefresh() {
        notificationDebounce?.cancel()
        notificationDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            refreshSnapshot()
        }
    }

    func send(command: MediaRemoteTransportCommand, targetID: String) async -> Bool {
        guard canRouteCommands else {
            markFailed("MediaRemote helper is not ready.")
            return false
        }

        let requestID = UUID().uuidString
        let sent = sendRequest([
            "type": "sendCommand",
            "requestID": requestID,
            "targetID": targetID,
            "command": command.rawValue,
        ])
        guard sent else {
            return false
        }

        return await withCheckedContinuation { continuation in
            commandWaiters[requestID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.commandWaitTimeoutNanoseconds)
                guard let self,
                      let waiter = self.commandWaiters.removeValue(forKey: requestID)
                else {
                    return
                }
                waiter.resume(returning: false)
            }
        }
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
    }

    @discardableResult
    private func sendRequest(_ request: [String: String]) -> Bool {
        guard let inputPipe else {
            markFailed("MediaRemote helper is not connected.")
            return false
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [])
            inputPipe.fileHandleForWriting.write(data + Data([0x0A]))
            return true
        } catch {
            markFailed("Could not write to MediaRemote helper: \(error.localizedDescription)")
            return false
        }
    }

    private func handleOutput(_ data: Data) {
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maxOutputBufferBytes else {
            outputBuffer.removeAll()
            markFailed("MediaRemote helper produced an oversized response.")
            process?.terminate()
            return
        }

        let newline = Data([0x0A])
        while let range = outputBuffer.range(of: newline) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex ..< range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex ..< range.upperBound)
            guard !line.isEmpty else {
                continue
            }
            guard line.count <= Self.maxOutputBufferBytes else {
                markFailed("MediaRemote helper produced an oversized response.")
                process?.terminate()
                return
            }
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        do {
            let envelope = try decoder.decode(MediaRemoteEnvelope.self, from: line)
            switch envelope.type {
            case "ready":
                let ready = try decoder.decode(MediaRemoteReadyEvent.self, from: line)
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
                targets = snapshot.targets
                activeTargetID = snapshot.activeTargetID?.nilIfEmpty
                isRefreshingSnapshot = false
                health = MediaRemoteHelperHealth(
                    state: .running,
                    message: "MediaRemote snapshot loaded",
                    pid: health.pid,
                    lastSnapshotAt: Date(),
                    targetCount: snapshot.targets.count
                )
                completeSnapshotWaiter(requestID: snapshot.requestID, result: true)
            case "commandResult":
                let result = try decoder.decode(MediaRemoteCommandResultEvent.self, from: line)
                if result.ok {
                    logger.info("MediaRemoteHelper command=\(result.command, privacy: .public) target=\(result.targetID, privacy: .public) ok=true")
                    refreshSnapshot()
                } else {
                    logger.error("MediaRemoteHelper command=\(result.command, privacy: .public) target=\(result.targetID, privacy: .public) ok=false message=\(result.message, privacy: .public)")
                    refreshSnapshot()
                }
                completeCommandWaiter(requestID: result.requestID, result: result.ok)
            case "now_playing_changed":
                debouncedRefresh()
            case "fatal", "error":
                let error = try decoder.decode(MediaRemoteErrorEvent.self, from: line)
                isRefreshingSnapshot = false
                completeSnapshotWaiter(requestID: error.requestID, result: false)
                completeCommandWaiter(requestID: error.requestID, result: false)
                markFailed(error.message)
            default:
                logger.info("MediaRemoteHelper ignored event=\(envelope.type, privacy: .public)")
            }
        } catch {
            logger.error("MediaRemoteHelper parse_error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTermination(_ terminatedProcess: Process, status: Int32) {
        if let process, process !== terminatedProcess {
            logger.info("MediaRemoteHelper ignored_stale_termination status=\(status, privacy: .public)")
            return
        }

        if process == nil, !expectedTermination {
            logger.info("MediaRemoteHelper ignored_unowned_termination status=\(status, privacy: .public)")
            return
        }

        process = nil
        inputPipe = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        outputBuffer.removeAll()
        clearTargets()
        completeSnapshotWaiters(result: false)
        completeCommandWaiters(result: false)

        guard !expectedTermination else {
            expectedTermination = false
            return
        }

        markFailed("MediaRemote helper exited with status \(status).")
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
        clearTargets()
        isRefreshingSnapshot = false
        completeSnapshotWaiters(result: false)
        completeCommandWaiters(result: false)
        health = MediaRemoteHelperHealth(
            state: .failed,
            message: message,
            pid: health.pid,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: 0
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
                guard let self, self.process == nil else {
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

    private func clearTargets() {
        targets = []
        activeTargetID = nil
    }

    private func completeSnapshotWaiter(requestID: String?, result: Bool) {
        guard let requestID, !requestID.isEmpty else {
            completeSnapshotWaiters(result: result)
            return
        }
        guard let waiter = snapshotWaiters.removeValue(forKey: requestID) else {
            return
        }
        waiter.resume(returning: result)
    }

    private func completeCommandWaiter(requestID: String?, result: Bool) {
        guard let requestID, !requestID.isEmpty else {
            completeCommandWaiters(result: result)
            return
        }
        guard let waiter = commandWaiters.removeValue(forKey: requestID) else {
            return
        }
        waiter.resume(returning: result)
    }

    private func completeSnapshotWaiters(result: Bool) {
        let waiters = Array(snapshotWaiters.values)
        snapshotWaiters.removeAll()
        isRefreshingSnapshot = false
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func completeCommandWaiters(result: Bool) {
        let waiters = Array(commandWaiters.values)
        commandWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}

private enum MediaRemoteControllerError: LocalizedError {
    case missingBundleResources
    case missingHelperScript(String)
    case missingHelperDylib(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleResources:
            return "Bundle resources are unavailable."
        case .missingHelperScript(let path):
            return "Missing helper script at \(path)."
        case .missingHelperDylib(let path):
            return "Missing helper dylib at \(path)."
        }
    }
}

private struct MediaRemoteEnvelope: Decodable {
    let type: String
}

private struct MediaRemoteReadyEvent: Decodable {
    let type: String
    let host: String?
    let pid: Int?
}

private struct MediaRemoteSnapshotEvent: Decodable {
    let type: String
    let requestID: String?
    let activeTargetID: String?
    let targets: [MediaRemoteTarget]
}

private struct MediaRemoteCommandResultEvent: Decodable {
    let type: String
    let requestID: String?
    let targetID: String
    let command: String
    let ok: Bool
    let message: String
}

private struct MediaRemoteErrorEvent: Decodable {
    let type: String
    let requestID: String?
    let message: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
