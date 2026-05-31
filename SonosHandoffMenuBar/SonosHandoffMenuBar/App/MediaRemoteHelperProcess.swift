import Foundation
import os

enum MediaRemoteHelperRole: String {
    case snapshot
    case command
}

@MainActor
final class MediaRemoteHelperProcess {
    private static let maxOutputBufferBytes = 1_048_576

    private let role: MediaRemoteHelperRole
    private let logger: Logger
    private var process: Process?
    private var stoppedProcesses: [Process] = []
    private var inputPipe: Pipe?
    private var outputBuffer = Data()

    init(role: MediaRemoteHelperRole, logger: Logger) {
        self.role = role
        self.logger = logger
    }

    var isRunning: Bool {
        process != nil && inputPipe != nil
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

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, dylib.path]
        process.environment = environment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { terminatedProcess in
            Task { @MainActor in
                onTermination(terminatedProcess, terminatedProcess.terminationStatus)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleOutput(data, onLine: onLine, onFailure: onFailure)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.error("MediaRemoteHelper role=\(self.role.rawValue, privacy: .public) stderr=\(message, privacy: .public)")
            }
        }

        try process.run()
        self.process = process
        self.inputPipe = inputPipe
    }

    func stop() {
        if let process {
            stoppedProcesses.append(process)
        }
        inputPipe = nil
        process?.terminate()
        process = nil
        outputBuffer.removeAll()
    }

    @discardableResult
    func send(_ request: [String: String]) -> Bool {
        guard let inputPipe else {
            return false
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [])
            inputPipe.fileHandleForWriting.write(data + Data([0x0A]))
            return true
        } catch {
            logger.error("MediaRemoteHelper role=\(self.role.rawValue, privacy: .public) write_failed=\(error.localizedDescription, privacy: .public)")
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
            process = nil
            inputPipe = nil
        }
        stoppedProcesses.removeAll { $0 === candidate }
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

        let newline = Data([0x0A])
        while let range = outputBuffer.range(of: newline) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex ..< range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex ..< range.upperBound)
            guard !line.isEmpty else {
                continue
            }
            guard line.count <= Self.maxOutputBufferBytes else {
                logger.error("MediaRemoteHelper role=\(self.role.rawValue, privacy: .public) oversized_line=true")
                onFailure("MediaRemote \(role.rawValue) helper produced an oversized response line.")
                stop()
                return
            }
            onLine(line)
        }
    }
}
