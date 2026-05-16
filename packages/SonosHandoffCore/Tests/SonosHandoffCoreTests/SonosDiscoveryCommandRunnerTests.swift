import Foundation
import Testing
@testable import SonosHandoffCore

struct SonosDiscoveryCommandRunnerTests {
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
