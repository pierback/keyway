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
        #expect(target.deviceID == "RINCON_A")
        #expect(runner.browseCount == 1)
        #expect(runner.resolveCount == 1)
        #expect(router.requestedHosts().isEmpty)
    }

    @Test
    func fallsBackToStandaloneGroupsWhenTopologyLookupFails() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: """
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.001 Add 2 4 local. _sonos._tcp. RINCON_B@Port
            """,
            hostByInstance: [
                "RINCON_A@Kitchen": "kitchen.local",
                "RINCON_B@Port": "port.local",
            ]
        )
        let directory = Self.directory(
            runner: runner,
            router: TargetDirectoryZeroconfRouter(payloadByHost: [:]),
            topologyBody: "<s:Envelope><s:Body></s:Body></s:Envelope>"
        )

        let state = try await directory.discoverGroupState()

        #expect(state.groups.map(\.displayName) == ["Kitchen", "Port"])
        #expect(state.groups.allSatisfy { $0.members.count == 1 })
    }

    @Test
    func resolvesGroupingTargetFromVisibleTopologySpeaker() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: """
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.001 Add 2 4 local. _sonos._tcp. RINCON_B@Port
            """,
            hostByInstance: [
                "RINCON_A@Kitchen": "kitchen.local",
                "RINCON_B@Port": "port.local",
            ]
        )
        let directory = Self.directory(
            runner: runner,
            router: TargetDirectoryZeroconfRouter(payloadByHost: [:]),
            topologyBody: Self.topologyEnvelope(
                """
                <ZoneGroups>
                  <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:123">
                    <ZoneGroupMember UUID="RINCON_A" ZoneName="Kitchen" Location="http://kitchen.local:1400/xml/device_description.xml"/>
                    <ZoneGroupMember UUID="RINCON_B" ZoneName="Port" Location="http://port.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                </ZoneGroups>
                """
            )
        )

        let target = try await directory.resolveGroupingTarget(named: "Port")

        #expect(target.roomName == "Port")
        #expect(target.host == "port.local")
        #expect(target.deviceID == "RINCON_B")
        #expect(runner.resolveCount == 2)
    }

    @Test
    func resolvesGroupingTargetsFromOneTopologyPass() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: """
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.001 Add 2 4 local. _sonos._tcp. RINCON_B@Port
            10:00:00.002 Add 2 4 local. _sonos._tcp. RINCON_C@Office
            """,
            hostByInstance: [
                "RINCON_A@Kitchen": "kitchen.local",
                "RINCON_B@Port": "port.local",
                "RINCON_C@Office": "office.local",
            ]
        )
        let directory = Self.directory(
            runner: runner,
            router: TargetDirectoryZeroconfRouter(payloadByHost: [:]),
            topologyBody: Self.topologyEnvelope(
                """
                <ZoneGroups>
                  <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:123">
                    <ZoneGroupMember UUID="RINCON_A" ZoneName="Kitchen" Location="http://kitchen.local:1400/xml/device_description.xml"/>
                    <ZoneGroupMember UUID="RINCON_B" ZoneName="Port" Location="http://port.local:1400/xml/device_description.xml"/>
                    <ZoneGroupMember UUID="RINCON_C" ZoneName="Office" Location="http://office.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                </ZoneGroups>
                """
            )
        )

        let targets = try await directory.resolveGroupingTargets(named: ["Office", "Kitchen"])

        #expect(targets.map(\.roomName) == ["Office", "Kitchen"])
        #expect(targets.map(\.host) == ["office.local", "kitchen.local"])
        #expect(targets.map(\.deviceID) == ["RINCON_C", "RINCON_A"])
        #expect(TargetDirectoryTopologyURLProtocol.requestCount == 1)
        #expect(runner.resolveCount == 3)
    }

    @Test
    func keepsVisibleSpeakersMissingFromTopologyAsStandaloneGroups() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: """
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.001 Add 2 4 local. _sonos._tcp. RINCON_B@Office
            """,
            hostByInstance: [
                "RINCON_A@Kitchen": "kitchen.local",
                "RINCON_B@Office": "office.local",
            ]
        )
        let directory = Self.directory(
            runner: runner,
            router: TargetDirectoryZeroconfRouter(payloadByHost: [:]),
            topologyBody: Self.topologyEnvelope(
                """
                <ZoneGroups>
                  <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:123">
                    <ZoneGroupMember UUID="RINCON_A" ZoneName="Kitchen" Location="http://kitchen.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                </ZoneGroups>
                """
            )
        )

        let state = try await directory.discoverGroupState()

        #expect(state.groups.map(\.displayName) == ["Kitchen", "Office"])
    }

    @Test
    func resolveTargetUsesCachedTopologyHostForSpotifyMetadata() async throws {
        let runner = RecordingSonosDiscoveryCommandRunner(
            browseOutput: """
            10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_A@Kitchen
            10:00:00.001 Add 2 4 local. _sonos._tcp. RINCON_B@Port
            """,
            hostByInstance: [
                "RINCON_A@Kitchen": "kitchen.local",
                "RINCON_B@Port": "port.local",
            ]
        )
        let router = TargetDirectoryZeroconfRouter(
            payloadByHost: ["port.local": #"{"version":"1.2.3","deviceID":"RINCON_B"}"#]
        )
        let directory = Self.directory(
            runner: runner,
            router: router,
            topologyBody: Self.topologyEnvelope(
                """
                <ZoneGroups>
                  <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:123">
                    <ZoneGroupMember UUID="RINCON_A" ZoneName="Kitchen" Location="http://kitchen.local:1400/xml/device_description.xml"/>
                    <ZoneGroupMember UUID="RINCON_B" ZoneName="Port" Location="http://port.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                </ZoneGroups>
                """
            )
        )

        _ = try await directory.discoverGroupState()
        let target = try await directory.resolveTarget(named: "Port")

        #expect(target.host == "port.local")
        #expect(target.version == "1.2.3")
        #expect(target.deviceID == "RINCON_B")
        #expect(runner.resolveCount == 2)
        #expect(router.requestedHosts() == ["port.local"])
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
        router: TargetDirectoryZeroconfRouter,
        topologyBody: String? = nil
    ) -> SonosDirectory {
        TargetDirectoryZeroconfURLProtocol.router = router
        TargetDirectoryTopologyURLProtocol.reset(responseBody: topologyBody)
        let zeroconfConfiguration = URLSessionConfiguration.ephemeral
        zeroconfConfiguration.protocolClasses = [TargetDirectoryZeroconfURLProtocol.self]
        let topologyConfiguration = URLSessionConfiguration.ephemeral
        topologyConfiguration.protocolClasses = [TargetDirectoryTopologyURLProtocol.self]
        return SonosDirectory(
            zeroconfClient: SonosSpotifyZeroconfClient(urlSession: URLSession(configuration: zeroconfConfiguration)),
            zoneGroupTopology: SonosZoneGroupTopology(
                soapClient: SonosSOAPClient(urlSession: URLSession(configuration: topologyConfiguration))
            ),
            resolver: SonosDNSSDResolver(commandRunner: runner)
        )
    }

    private static func topologyEnvelope(_ topologyXML: String) -> String {
        """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"><CurrentZoneGroupState>\(topologyXML.xmlEscaped)</CurrentZoneGroupState></u:GetZoneGroupStateResponse></s:Body></s:Envelope>
        """
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

private final class TargetDirectoryTopologyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responseBody: String?
    private nonisolated(unsafe) static var recordedRequestCount = 0

    static func reset(responseBody: String?) {
        lock.withLock {
            self.responseBody = responseBody
            recordedRequestCount = 0
        }
    }

    static var requestCount: Int {
        lock.withLock {
            recordedRequestCount
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseBody = Self.currentResponseBody()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseBody == nil ? 500 : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((responseBody ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func currentResponseBody() -> String? {
        lock.withLock {
            recordedRequestCount += 1
            return responseBody
        }
    }
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

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
