import Foundation
import Testing
@testable import SonosHandoffCore

struct SonosDiscoveryCommandRunnerTests {
    @Test
    func runnerTreatsCollectionTimeoutAsSuccess() throws {
        let result = try SonosShellDiscoveryCommandRunner().run(
            SonosDiscoveryCommand(
                executable: "/bin/sleep",
                arguments: ["1"],
                timeoutSeconds: 0.01
            )
        )

        #expect(result.status == 0)
    }

    @Test
    func resolverReportsBrowseCommandFailure() async {
        let resolver = SonosDNSSDResolver(commandRunner: FailedSonosDiscoveryCommandRunner())

        do {
            _ = try await resolver.discoverInstances()
            Issue.record("Expected failed dns-sd browse to throw.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .targetNotVisible)
            #expect(error.message.contains("DNSServiceBrowse failed"))
        } catch {
            Issue.record("Expected ConnectHandoffError, got \(error).")
        }
    }

    @Test
    func outputBufferKeepsOnlyRecentBoundedOutput() {
        let buffer = SonosDiscoveryCommandOutputBuffer(stopWhen: nil)
        let oversized = String(repeating: "a", count: SonosDiscoveryCommandOutputBuffer.outputBytesMax + 12)

        buffer.append(Data(oversized.utf8))

        #expect(buffer.output.count == SonosDiscoveryCommandOutputBuffer.outputBytesMax)
        #expect(buffer.output == String(repeating: "a", count: SonosDiscoveryCommandOutputBuffer.outputBytesMax))
    }

    @Test
    func outputBufferLatchesStopCondition() {
        let buffer = SonosDiscoveryCommandOutputBuffer(stopWhen: { $0.contains("location=http://port.local:1400/") })

        buffer.append(Data("partial".utf8))
        #expect(!buffer.shouldStop)

        buffer.append(Data(" location=http://port.local:1400/xml".utf8))
        #expect(buffer.shouldStop)

        buffer.append(Data(" trailing".utf8))
        #expect(buffer.shouldStop)
    }
}

private struct FailedSonosDiscoveryCommandRunner: SonosDiscoveryCommandRunning {
    func run(_ command: SonosDiscoveryCommand) throws -> SonosDiscoveryCommandResult {
        SonosDiscoveryCommandResult(output: "DNSServiceBrowse failed -65563", status: 1)
    }
}
