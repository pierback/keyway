import Darwin
import Foundation
import os

enum MediaRemoteHelperRole: String, Hashable {
    case snapshot
    case command
}

struct MediaRemoteHelperPairState {
    private var readyRoles: Set<MediaRemoteHelperRole> = []

    var isReady: Bool {
        readyRoles == [.snapshot, .command]
    }

    mutating func markReady(_ role: MediaRemoteHelperRole) -> Bool {
        let inserted = readyRoles.insert(role).inserted
        return inserted && isReady
    }

    mutating func reset() {
        readyRoles.removeAll()
    }
}

struct MediaRemoteHelperSupervisorState {
    private(set) var shouldRun = false
    private(set) var relaunchPending = false

    mutating func start() {
        shouldRun = true
        relaunchPending = true
    }

    mutating func stop() {
        shouldRun = false
        relaunchPending = false
    }

    mutating func requestRelaunch() {
        guard shouldRun else {
            return
        }
        relaunchPending = true
    }

    func canLaunch(hasOwnedProcesses: Bool) -> Bool {
        shouldRun && relaunchPending && !hasOwnedProcesses
    }

    mutating func didLaunch() {
        precondition(shouldRun && relaunchPending)
        relaunchPending = false
    }
}

@MainActor
final class MediaRemoteHelperProcess {
    private static let maxOutputBufferBytes = 1_048_576

    private let role: MediaRemoteHelperRole
    private let logger: Logger
    private var activeRunID: UUID?
    private var process: Process?
    private var stoppedProcesses: [Process] = []
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()

    init(role: MediaRemoteHelperRole, logger: Logger) {
        self.role = role
        self.logger = logger
    }

    var isRunning: Bool {
        process?.isRunning == true && inputPipe != nil
    }

    var hasOwnedProcesses: Bool {
        process != nil || !stoppedProcesses.isEmpty
    }

    func start(
        script: URL,
        dylib: URL,
        onLine: @escaping @MainActor @Sendable (Data) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onTermination: @escaping @MainActor @Sendable (Process, Int32) -> Void
    ) throws {
        guard process == nil else {
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let runID = UUID()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, dylib.path]
        process.environment = environment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self,
                      self.activeRunID == runID || self.ownsStopped(terminatedProcess)
                else {
                    return
                }
                onTermination(terminatedProcess, terminatedProcess.terminationStatus)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.activeRunID == runID else {
                    return
                }
                self.handleOutput(data, onLine: onLine, onFailure: onFailure)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.activeRunID == runID else { return }
                self.logger.error("MediaRemoteHelper role=\(self.role.rawValue, privacy: .public) stderr=\(message, privacy: .public)")
            }
        }

        self.activeRunID = runID
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            activeRunID = nil
            self.process = nil
            self.inputPipe = nil
            self.outputPipe = nil
            self.errorPipe = nil
            outputBuffer.removeAll()
            throw error
        }
    }

    func stop() {
        let process = self.process
        if let process, process.isRunning {
            stoppedProcesses.append(process)
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        activeRunID = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        self.process = nil
        outputBuffer.removeAll()
    }

    @discardableResult
    func send(_ request: [String: Any]) -> Bool {
        guard let inputPipe, process?.isRunning == true else {
            if process != nil || self.inputPipe != nil || outputPipe != nil || errorPipe != nil {
                stop()
            }
            return false
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [])
            try inputPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
            return true
        } catch {
            logger.error("MediaRemoteHelper role=\(self.role.rawValue, privacy: .public) write_failed=\(error.localizedDescription, privacy: .public)")
            stop()
            return false
        }
    }

    func owns(_ candidate: Process) -> Bool {
        process === candidate
    }

    func ownsStopped(_ candidate: Process) -> Bool {
        stoppedProcesses.contains { $0 === candidate }
    }

    func retire(_ candidate: Process) {
        if process === candidate {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            activeRunID = nil
            process = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
            outputBuffer.removeAll()
        }
        stoppedProcesses.removeAll { $0 === candidate }
    }

    func forceTerminateStoppedProcesses() {
        for process in stoppedProcesses where process.isRunning {
            let result = Darwin.kill(process.processIdentifier, SIGKILL)
            precondition(
                result == 0 || errno == ESRCH,
                "Could not force-terminate MediaRemote \(role.rawValue) helper"
            )
        }
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["KEYWAY_MEDIAREMOTE_ROLE"] = role.rawValue
        if role == .command {
            environment["KEYWAY_MEDIAREMOTE_DISABLE_NOTIFICATIONS"] = "1"
        }
        return environment
    }

    private func handleOutput(
        _ data: Data,
        onLine: @MainActor @Sendable (Data) -> Void,
        onFailure: @MainActor @Sendable (String) -> Void
    ) {
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maxOutputBufferBytes else {
            logger.error("MediaRemoteHelper role=\(self.role.rawValue, privacy: .public) oversized_response=true")
            onFailure("MediaRemote \(role.rawValue) helper produced an oversized response.")
            stop()
            return
        }

        guard let runID = activeRunID else {
            return
        }
        var lineStart = outputBuffer.startIndex
        var consumedEnd = outputBuffer.startIndex
        var lines: [Data] = []
        for index in outputBuffer.indices where outputBuffer[index] == 0x0A {
            lines.append(outputBuffer.subdata(in: lineStart ..< index))
            consumedEnd = outputBuffer.index(after: index)
            lineStart = consumedEnd
        }
        guard consumedEnd != outputBuffer.startIndex else {
            return
        }
        outputBuffer.removeSubrange(outputBuffer.startIndex ..< consumedEnd)

        for line in lines where !line.isEmpty {
            guard line.count <= Self.maxOutputBufferBytes else {
                logger.error("MediaRemoteHelper role=\(self.role.rawValue, privacy: .public) oversized_line=true")
                onFailure("MediaRemote \(role.rawValue) helper produced an oversized response line.")
                stop()
                return
            }
            guard activeRunID == runID else {
                return
            }
            onLine(line)
            guard activeRunID == runID else {
                return
            }
        }
    }
}
