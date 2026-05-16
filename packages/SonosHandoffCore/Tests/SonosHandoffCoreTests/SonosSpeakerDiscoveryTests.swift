import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosSpeakerDiscoveryTests {
    @Test
    func discoversSortedUniqueSpeakersAndDropsUnresolvedInstances() async throws {
        let runner = FakeSonosDiscoveryCommandRunner(
            browseOutput: """
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_B@Bedroom
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_C@Missing
            """,
            hostByInstance: [
                "RINCON_A@Kitchen": "kitchen.local",
                "RINCON_B@Bedroom": "bedroom.local",
            ]
        )
        let discovery = SonosSpeakerDiscovery(commandRunner: runner, hostResolutionConcurrencyMax: 2)

        let speakers = try await discovery.discoverSpeakers()

        #expect(speakers.map(\.roomName) == ["Bedroom", "Kitchen"])
        #expect(speakers.map(\.host) == ["bedroom.local", "kitchen.local"])
        #expect(speakers.map(\.id) == ["RINCON_B", "RINCON_A"])
    }

    @Test
    func boundsConcurrentHostResolution() async throws {
        let runner = FakeSonosDiscoveryCommandRunner(
            browseOutput: """
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_B@Bedroom
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_C@Office
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_D@Port
            """,
            hostByInstance: [
                "RINCON_A@Kitchen": "kitchen.local",
                "RINCON_B@Bedroom": "bedroom.local",
                "RINCON_C@Office": "office.local",
                "RINCON_D@Port": "port.local",
            ],
            resolveDelay: 0.02
        )
        let discovery = SonosSpeakerDiscovery(commandRunner: runner, hostResolutionConcurrencyMax: 2)

        let speakers = try await discovery.discoverSpeakers()

        #expect(speakers.count == 4)
        #expect(runner.maxActiveResolveCount <= 2)
    }
}

private final class FakeSonosDiscoveryCommandRunner: SonosDiscoveryCommandRunning, @unchecked Sendable {
    private let browseOutput: String
    private let hostByInstance: [String: String]
    private let resolveDelay: TimeInterval
    private let lock = NSLock()
    private var activeResolveCount = 0
    private var recordedMaxActiveResolveCount = 0

    init(
        browseOutput: String,
        hostByInstance: [String: String],
        resolveDelay: TimeInterval = 0
    ) {
        self.browseOutput = browseOutput
        self.hostByInstance = hostByInstance
        self.resolveDelay = resolveDelay
    }

    var maxActiveResolveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaxActiveResolveCount
    }

    func run(_ command: SonosDiscoveryCommand) throws -> SonosDiscoveryCommandResult {
        if command.arguments.first == "-B" {
            return SonosDiscoveryCommandResult(output: browseOutput, status: 0)
        }

        guard command.arguments.first == "-L", command.arguments.count >= 2 else {
            return SonosDiscoveryCommandResult(output: "", status: 1)
        }

        let instance = command.arguments[1]
        beginResolve()
        Thread.sleep(forTimeInterval: resolveDelay)
        endResolve()

        guard let host = hostByInstance[instance] else {
            return SonosDiscoveryCommandResult(output: "", status: 1)
        }

        return SonosDiscoveryCommandResult(output: "location=http://\(host):1400/xml/device_description.xml", status: 0)
    }

    private func beginResolve() {
        lock.lock()
        activeResolveCount += 1
        recordedMaxActiveResolveCount = max(recordedMaxActiveResolveCount, activeResolveCount)
        lock.unlock()
    }

    private func endResolve() {
        lock.lock()
        activeResolveCount -= 1
        lock.unlock()
    }
}
