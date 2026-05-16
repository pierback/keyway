import Foundation

struct SonosDiscoveryCommand: Sendable {
    let executable: String
    let arguments: [String]
    let timeoutSeconds: TimeInterval
    let stopWhen: (@Sendable (String) -> Bool)?

    init(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        stopWhen: (@Sendable (String) -> Bool)? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.stopWhen = stopWhen
    }
}

struct SonosDiscoveryCommandResult {
    let output: String
    let status: Int32
}

protocol SonosDiscoveryCommandRunning: Sendable {
    func run(_ command: SonosDiscoveryCommand) throws -> SonosDiscoveryCommandResult
}

struct SonosShellDiscoveryCommandRunner: SonosDiscoveryCommandRunning {
    func run(_ command: SonosDiscoveryCommand) throws -> SonosDiscoveryCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputBuffer = SonosDiscoveryCommandOutputBuffer(stopWhen: command.stopWhen)
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            outputBuffer.append(data)
        }

        try process.run()
        let deadline = Date().addingTimeInterval(command.timeoutSeconds)
        while process.isRunning, Date() < deadline {
            if outputBuffer.shouldStop {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        outputHandle.readabilityHandler = nil

        let remainingData = outputHandle.readDataToEndOfFile()
        outputBuffer.append(remainingData)

        return SonosDiscoveryCommandResult(output: outputBuffer.output, status: process.terminationStatus)
    }
}

final class SonosDiscoveryCommandOutputBuffer: @unchecked Sendable {
    static let outputBytesMax = 64 * 1024

    private let lock = NSLock()
    private let stopWhen: (@Sendable (String) -> Bool)?
    private var outputData = Data()
    private var matchedStopCondition = false

    init(stopWhen: (@Sendable (String) -> Bool)?) {
        self.stopWhen = stopWhen
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return matchedStopCondition
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        outputData.append(data)
        if outputData.count > Self.outputBytesMax {
            outputData = Data(outputData.suffix(Self.outputBytesMax))
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        matchedStopCondition = matchedStopCondition || (stopWhen?(output) ?? false)
        lock.unlock()
    }
}
