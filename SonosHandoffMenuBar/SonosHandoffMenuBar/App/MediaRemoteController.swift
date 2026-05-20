import Combine
import Foundation
import os

@MainActor
final class MediaRemoteController: ObservableObject {
    @Published private(set) var health: MediaRemoteHelperHealth = .stopped
    @Published private(set) var targets: [MediaRemoteTarget] = []
    @Published private(set) var activeTargetID: String?

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "MediaRemote")
    private let decoder = JSONDecoder()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = Data()
    private var refreshTimer: Timer?
    private var restartAttempts = 0
    private var expectedTermination = false

    var activeTarget: MediaRemoteTarget? {
        guard let activeTargetID else {
            return nil
        }
        return targets.first { $0.id == activeTargetID }
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
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            startRefreshTimer()
        } catch {
            markFailed("Could not start MediaRemote helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        expectedTermination = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        inputPipe = nil
        process?.terminate()
        process = nil
        health = .stopped
    }

    func restart() {
        stop()
        restartAttempts = 0
        start()
    }

    func refreshSnapshot() {
        sendRequest([
            "type": "refresh",
            "requestID": UUID().uuidString,
        ])
    }

    func send(command: MediaRemoteTransportCommand, targetID: String) {
        sendRequest([
            "type": "sendCommand",
            "requestID": UUID().uuidString,
            "targetID": targetID,
            "command": command.rawValue,
        ])
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

    private func sendRequest(_ request: [String: String]) {
        guard let inputPipe else {
            markFailed("MediaRemote helper is not connected.")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [])
            inputPipe.fileHandleForWriting.write(data + Data([0x0A]))
        } catch {
            markFailed("Could not write to MediaRemote helper: \(error.localizedDescription)")
        }
    }

    private func handleOutput(_ data: Data) {
        outputBuffer.append(data)
        let newline = Data([0x0A])
        while let range = outputBuffer.range(of: newline) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex ..< range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex ..< range.upperBound)
            guard !line.isEmpty else {
                continue
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
                health = MediaRemoteHelperHealth(
                    state: .running,
                    message: "MediaRemote snapshot loaded",
                    pid: health.pid,
                    lastSnapshotAt: Date(),
                    targetCount: snapshot.targets.count
                )
            case "commandResult":
                let result = try decoder.decode(MediaRemoteCommandResultEvent.self, from: line)
                if result.ok {
                    logger.info("MediaRemoteHelper command=\(result.command, privacy: .public) target=\(result.targetID, privacy: .public) ok=true")
                    refreshSnapshot()
                } else {
                    markFailed(result.message.nilIfEmpty ?? "MediaRemote command failed.")
                }
            case "fatal", "error":
                let error = try decoder.decode(MediaRemoteErrorEvent.self, from: line)
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

        guard !expectedTermination else {
            expectedTermination = false
            return
        }

        markFailed("MediaRemote helper exited with status \(status).")
        guard restartAttempts < 2 else {
            return
        }

        restartAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.start()
        }
    }

    private func markFailed(_ message: String) {
        logger.error("MediaRemoteHelper failed=\(message, privacy: .public)")
        health = MediaRemoteHelperHealth(
            state: .failed,
            message: message,
            pid: health.pid,
            lastSnapshotAt: health.lastSnapshotAt,
            targetCount: targets.count
        )
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
    let activeTargetID: String?
    let targets: [MediaRemoteTarget]
}

private struct MediaRemoteCommandResultEvent: Decodable {
    let type: String
    let targetID: String
    let command: String
    let ok: Bool
    let message: String
}

private struct MediaRemoteErrorEvent: Decodable {
    let type: String
    let message: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
