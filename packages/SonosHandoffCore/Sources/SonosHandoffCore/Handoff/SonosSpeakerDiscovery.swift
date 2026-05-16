import Foundation

final class SonosSpeakerDiscovery: @unchecked Sendable {
    private static let defaultHostResolutionConcurrencyMax = 4

    private let resolver: SonosDNSSDResolver
    private let hostResolutionConcurrencyMax: Int

    init(
        commandRunner: any SonosDiscoveryCommandRunning = SonosShellDiscoveryCommandRunner(),
        resolver: SonosDNSSDResolver? = nil,
        hostResolutionConcurrencyMax: Int = SonosSpeakerDiscovery.defaultHostResolutionConcurrencyMax
    ) {
        self.resolver = resolver ?? SonosDNSSDResolver(commandRunner: commandRunner)
        self.hostResolutionConcurrencyMax = max(1, hostResolutionConcurrencyMax)
    }

    func discoverSpeakers() async throws -> [SonosSpeaker] {
        let instances = try await resolver.discoverInstances()
        return await resolveSpeakers(instances: instances)
    }

    private func resolveSpeakers(instances: [String]) async -> [SonosSpeaker] {
        guard !instances.isEmpty else {
            return []
        }

        let resolver = resolver
        let concurrencyMax = min(hostResolutionConcurrencyMax, instances.count)
        return await withTaskGroup(of: SonosSpeaker?.self) { group in
            var iterator = instances.makeIterator()

            func submitNext() -> Bool {
                guard let instance = iterator.next() else {
                    return false
                }

                group.addTask(priority: .userInitiated) {
                    await resolver.resolveDevice(instance: instance).map(Self.speaker)
                }
                return true
            }

            for _ in 0 ..< concurrencyMax {
                _ = submitNext()
            }

            var speakers: [SonosSpeaker] = []
            while let speaker = await group.next() {
                if let speaker {
                    speakers.append(speaker)
                }
                _ = submitNext()
            }

            return Self.normalizedSpeakers(speakers)
        }
    }

    private static func speaker(from device: SonosResolvedDevice) -> SonosSpeaker {
        SonosSpeaker(id: device.id, roomName: device.roomName, host: device.host)
    }

    private static func normalizedSpeakers(_ speakers: [SonosSpeaker]) -> [SonosSpeaker] {
        speakers
            .uniqued { $0.id }
            .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }
}
