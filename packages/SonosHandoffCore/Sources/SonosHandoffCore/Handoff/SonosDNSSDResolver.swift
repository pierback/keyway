import Foundation

struct SonosResolvedDevice: Sendable {
    let id: String
    let roomName: String
    let host: String
}

final class SonosDNSSDResolver: @unchecked Sendable {
    private static let browseTimeoutSeconds: TimeInterval = 3.0
    private static let targetBrowseTimeoutSeconds: TimeInterval = 5.0
    private static let hostResolveTimeoutSeconds: TimeInterval = 2.0
    private static let targetHostResolveTimeoutSeconds: TimeInterval = 5.0

    private let commandRunner: any SonosDiscoveryCommandRunning

    init(commandRunner: any SonosDiscoveryCommandRunning = SonosShellDiscoveryCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func discoverInstances() async throws -> [String] {
        let commandRunner = commandRunner
        let browse = try await Task.detached(priority: .userInitiated) {
            try commandRunner.run(Self.browseCommand(timeoutSeconds: Self.browseTimeoutSeconds))
        }.value
        return SonosDNSSDRecordParser.instances(fromBrowseOutput: browse.output)
    }

    func resolveDevice(instance: String) async -> SonosResolvedDevice? {
        let commandRunner = commandRunner
        return await Task.detached(priority: .userInitiated) {
            try? Self.resolvedDevice(
                instance: instance,
                commandRunner: commandRunner,
                timeoutSeconds: Self.hostResolveTimeoutSeconds
            )
        }.value
    }

    func resolveDevice(named roomName: String) async throws -> SonosResolvedDevice {
        let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandRunner = commandRunner
        return try await Task.detached(priority: .userInitiated) {
            let instance = try Self.discoverInstance(
                named: roomName,
                commandRunner: commandRunner
            )
            return try Self.resolvedDevice(
                instance: instance,
                commandRunner: commandRunner,
                timeoutSeconds: Self.targetHostResolveTimeoutSeconds
            )
        }.value
    }

    private static func discoverInstance(
        named roomName: String,
        commandRunner: any SonosDiscoveryCommandRunning
    ) throws -> String {
        let browse = try commandRunner.run(
            browseCommand(
                timeoutSeconds: targetBrowseTimeoutSeconds,
                stopWhen: { output in
                    output
                        .split(separator: "\n")
                        .contains {
                            SonosDNSSDRecordParser.instance(
                                fromBrowseLine: String($0),
                                matchingRoomName: roomName
                            ) != nil
                        }
                }
            )
        )

        guard let instance = browse.output
            .split(separator: "\n")
            .compactMap({ line -> String? in
                SonosDNSSDRecordParser.instance(fromBrowseLine: String(line), matchingRoomName: roomName)
            })
            .first
        else {
            throw ConnectHandoffError(.targetNotVisible, "Sonos target not found: \(roomName)")
        }

        return instance
    }

    private static func resolvedDevice(
        instance: String,
        commandRunner: any SonosDiscoveryCommandRunning,
        timeoutSeconds: TimeInterval
    ) throws -> SonosResolvedDevice {
        guard let roomName = SonosDNSSDRecordParser.roomName(fromInstance: instance) else {
            throw ConnectHandoffError(.targetNotVisible, "Could not read Sonos room name for \(instance)")
        }

        let host = try resolveHost(instance: instance, commandRunner: commandRunner, timeoutSeconds: timeoutSeconds)
        return SonosResolvedDevice(
            id: SonosDNSSDRecordParser.speakerID(fromInstance: instance) ?? "\(roomName)@\(host)",
            roomName: roomName,
            host: host
        )
    }

    private static func resolveHost(
        instance: String,
        commandRunner: any SonosDiscoveryCommandRunning,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        let resolve = try commandRunner.run(resolveCommand(instance: instance, timeoutSeconds: timeoutSeconds))
        guard let host = SonosDNSSDRecordParser.host(fromResolveOutput: resolve.output) else {
            throw ConnectHandoffError(.targetNotVisible, "Could not resolve host for \(instance)")
        }

        return host
    }

    private static func browseCommand(
        timeoutSeconds: TimeInterval,
        stopWhen: (@Sendable (String) -> Bool)? = nil
    ) -> SonosDiscoveryCommand {
        SonosDiscoveryCommand(
            executable: "/usr/bin/dns-sd",
            arguments: ["-B", "_sonos._tcp", "local."],
            timeoutSeconds: timeoutSeconds,
            stopWhen: stopWhen
        )
    }

    private static func resolveCommand(instance: String, timeoutSeconds: TimeInterval) -> SonosDiscoveryCommand {
        SonosDiscoveryCommand(
            executable: "/usr/bin/dns-sd",
            arguments: ["-L", instance, "_sonos._tcp", "local."],
            timeoutSeconds: timeoutSeconds,
            stopWhen: SonosDNSSDRecordParser.resolveOutputContainsHost
        )
    }
}
