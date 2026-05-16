import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosDirectoryTests {
    @Test
    func resolvesTargetThroughSharedDNSSDResolverAndCachesMetadata() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: "10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Port",
            hostByInstance: ["RINCON_A@Port": "port.local"]
        )
        let router = TargetDirectoryZeroconfRouter(
            payloadByHost: ["port.local": #"{"version":"1.2.3","deviceID":"RINCON_A"}"#]
        )
        let directory = Self.directory(runner: runner, router: router)

        let first = try await directory.resolveTarget(named: " port ")
        let second = try await directory.resolveTarget(named: "Port")

        #expect(first.roomName == "Port")
        #expect(first.host == "port.local")
        #expect(first.version == "1.2.3")
        #expect(first.deviceID == "RINCON_A")
        #expect(second.host == "port.local")
        #expect(runner.browseCount == 1)
        #expect(runner.resolveCount == 1)
        #expect(router.requestedHosts() == ["port.local"])
    }

    @Test
    func skipsZeroconfMetadataWhenOnlyHostResolutionIsNeeded() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: "10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Port",
            hostByInstance: ["RINCON_A@Port": "port.local"]
        )
        let router = TargetDirectoryZeroconfRouter(payloadByHost: [:])
        let directory = Self.directory(runner: runner, router: router)

        let target = try await directory.resolveTarget(named: "Port", needsSpotifyMetadata: false)

        #expect(target.roomName == "Port")
        #expect(target.host == "port.local")
        #expect(target.version == nil)
        #expect(target.deviceID == nil)
        #expect(runner.browseCount == 1)
        #expect(runner.resolveCount == 1)
        #expect(router.requestedHosts().isEmpty)
    }

    @Test
    func failsWhenRequestedRoomIsNotVisible() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: "10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen",
            hostByInstance: ["RINCON_A@Kitchen": "kitchen.local"]
        )
        let router = TargetDirectoryZeroconfRouter(payloadByHost: [:])
        let directory = Self.directory(runner: runner, router: router)

        do {
            _ = try await directory.resolveTarget(named: "Port")
            Issue.record("Expected invisible target resolution to fail.")
        } catch let error as ConnectHandoffError {
            #expect(error.code == .targetNotVisible)
            #expect(error.message.contains("Port"))
        } catch {
            Issue.record("Expected ConnectHandoffError, got \(error).")
        }

        #expect(runner.browseCount == 1)
        #expect(runner.resolveCount == 0)
        #expect(router.requestedHosts().isEmpty)
    }

    private static func directory(
        runner: RecordingSonosDiscoveryCommandRunner,
        router: TargetDirectoryZeroconfRouter
    ) -> SonosDirectory {
        TargetDirectoryZeroconfURLProtocol.router = router
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TargetDirectoryZeroconfURLProtocol.self]
        return SonosDirectory(
            zeroconfClient: SonosSpotifyZeroconfClient(urlSession: URLSession(configuration: configuration)),
            resolver: SonosDNSSDResolver(commandRunner: runner)
        )
    }
}

private final class RecordingSonosDiscoveryCommandRunner: SonosDiscoveryCommandRunning, @unchecked Sendable {
    private let browseOutput: String
    private let hostByInstance: [String: String]
    private let lock = NSLock()
    private var recordedBrowseCount = 0
    private var recordedResolveCount = 0

    init(browseOutput: String, hostByInstance: [String: String]) {
        self.browseOutput = browseOutput
        self.hostByInstance = hostByInstance
    }

    var browseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedBrowseCount
    }

    var resolveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedResolveCount
    }

    func run(_ command: SonosDiscoveryCommand) throws -> SonosDiscoveryCommandResult {
        if command.arguments.first == "-B" {
            lock.lock()
            recordedBrowseCount += 1
            lock.unlock()
            return SonosDiscoveryCommandResult(output: browseOutput, status: 0)
        }

        guard command.arguments.first == "-L", command.arguments.count >= 2 else {
            return SonosDiscoveryCommandResult(output: "", status: 1)
        }

        lock.lock()
        recordedResolveCount += 1
        lock.unlock()

        let instance = command.arguments[1]
        guard let host = hostByInstance[instance] else {
            return SonosDiscoveryCommandResult(output: "", status: 1)
        }

        return SonosDiscoveryCommandResult(output: "location=http://\(host):1400/xml/device_description.xml", status: 0)
    }
}

private final class TargetDirectoryZeroconfURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var router = TargetDirectoryZeroconfRouter(payloadByHost: [:])

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseBody = Self.router.response(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseBody == nil ? 404 : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((responseBody ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TargetDirectoryZeroconfRouter: @unchecked Sendable {
    private let lock = NSLock()
    private let payloadByHost: [String: String]
    private var hosts: [String] = []

    init(payloadByHost: [String: String]) {
        self.payloadByHost = payloadByHost
    }

    func requestedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    func response(for request: URLRequest) -> String? {
        let host = request.url?.host ?? ""
        lock.lock()
        hosts.append(host)
        lock.unlock()
        return payloadByHost[host]
    }
}
