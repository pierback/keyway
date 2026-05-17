import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosGroupingServiceTests {
    @Test
    func joinMultipleMembersUsesOneTopologyLookupAndConcurrentJoinRequests() async throws {
        GroupingServiceURLProtocol.reset(
            topologyResponse: Self.topologyEnvelope(
                """
                <ZoneGroups>
                  <ZoneGroup Coordinator="RINCON_KITCHEN" ID="RINCON_KITCHEN:123">
                    <ZoneGroupMember UUID="RINCON_KITCHEN" ZoneName="Kitchen" Location="http://kitchen.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                  <ZoneGroup Coordinator="RINCON_OFFICE" ID="RINCON_OFFICE:123">
                    <ZoneGroupMember UUID="RINCON_OFFICE" ZoneName="Office" Location="http://office.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                  <ZoneGroup Coordinator="RINCON_BATH" ID="RINCON_BATH:123">
                    <ZoneGroupMember UUID="RINCON_BATH" ZoneName="Bath" Location="http://bath.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                </ZoneGroups>
                """
            )
        )
        let service = Self.groupingService()

        try await service.join(
            roomNames: ["Office", "Bath"],
            toCoordinatorRoomName: "Kitchen"
        )

        let requests = GroupingServiceURLProtocol.snapshot()
        #expect(requests.filter { $0.url?.path == "/ZoneGroupTopology/Control" }.count == 1)
        let joinRequests = requests
            .filter { $0.url?.path == "/MediaRenderer/AVTransport/Control" }
        #expect(Set(joinRequests.compactMap { $0.url?.host }) == ["office.local", "bath.local"])
        #expect(joinRequests.allSatisfy { $0.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"" })
        #expect(joinRequests.allSatisfy { $0.body.contains("<CurrentURI>x-rincon:RINCON_KITCHEN</CurrentURI>") })
    }

    @Test
    func removeCoordinatorLeavesOldCoordinatorOutOfReplacementGroup() async throws {
        GroupingServiceURLProtocol.reset()
        let service = Self.groupingService()
        let currentGroup = Self.group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"])

        try await service.removeCoordinator(
            in: currentGroup,
            coordinatorRoomName: "Kitchen",
            replacementRoomName: "Port"
        )

        #expect(GroupingServiceURLProtocol.snapshot().contains { $0.url?.path == "/ZoneGroupTopology/Control" } == false)
        let avTransportRequests = GroupingServiceURLProtocol.snapshot()
            .filter { $0.url?.path == "/MediaRenderer/AVTransport/Control" }
        #expect(avTransportRequests.map { $0.url?.host } == ["port.local", "office.local"])
        #expect(avTransportRequests[0].soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"")
        #expect(avTransportRequests[1].soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        #expect(avTransportRequests[1].body.contains("<CurrentURI>x-rincon:RINCON_PORT</CurrentURI>"))
        #expect(avTransportRequests.contains { $0.url?.host == "kitchen.local" } == false)
    }

    @Test
    func prepareCoordinatorRemovalOnlyMakesReplacementStandalone() async throws {
        GroupingServiceURLProtocol.reset()
        let service = Self.groupingService()
        let currentGroup = Self.group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office"])

        try await service.prepareCoordinatorRemoval(
            in: currentGroup,
            coordinatorRoomName: "Kitchen",
            replacementRoomName: "Port"
        )

        let avTransportRequests = GroupingServiceURLProtocol.snapshot()
            .filter { $0.url?.path == "/MediaRenderer/AVTransport/Control" }
        #expect(avTransportRequests.count == 1)
        #expect(avTransportRequests[0].url?.host == "port.local")
        #expect(avTransportRequests[0].soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"")
    }

    @Test
    func finishCoordinatorRemovalRejoinsRemainingMembersToReplacement() async throws {
        GroupingServiceURLProtocol.reset()
        let service = Self.groupingService()
        let currentGroup = Self.group(coordinator: "Kitchen", members: ["Kitchen", "Port", "Office", "Bath"])

        try await service.finishCoordinatorRemoval(
            in: currentGroup,
            coordinatorRoomName: "Kitchen",
            replacementRoomName: "Port"
        )

        let avTransportRequests = GroupingServiceURLProtocol.snapshot()
            .filter { $0.url?.path == "/MediaRenderer/AVTransport/Control" }
        #expect(Set(avTransportRequests.compactMap { $0.url?.host }) == ["office.local", "bath.local"])
        #expect(avTransportRequests.allSatisfy { $0.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"" })
        #expect(avTransportRequests.allSatisfy { $0.body.contains("<CurrentURI>x-rincon:RINCON_PORT</CurrentURI>") })
        #expect(avTransportRequests.contains { $0.url?.host == "kitchen.local" } == false)
        #expect(avTransportRequests.contains { $0.url?.host == "port.local" } == false)
    }

    @Test
    func removeCoordinatorUsesEffectiveCoordinatorWhenCoordinatorIDIsMissingFromMembers() async throws {
        GroupingServiceURLProtocol.reset()
        let service = Self.groupingService()
        let currentGroup = SonosSpeakerGroup(
            id: "RINCON_MISSING:123",
            coordinatorID: "RINCON_MISSING",
            members: ["Kitchen", "Port", "Office"].map(Self.speaker)
        )

        try await service.removeCoordinator(
            in: currentGroup,
            coordinatorRoomName: "Kitchen",
            replacementRoomName: "Port"
        )

        #expect(GroupingServiceURLProtocol.snapshot().contains { $0.url?.path == "/ZoneGroupTopology/Control" } == false)
        let avTransportRequests = GroupingServiceURLProtocol.snapshot()
            .filter { $0.url?.path == "/MediaRenderer/AVTransport/Control" }
        #expect(avTransportRequests.map { $0.url?.host } == ["port.local", "office.local"])
        #expect(avTransportRequests[0].soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"")
        #expect(avTransportRequests[1].body.contains("<CurrentURI>x-rincon:RINCON_PORT</CurrentURI>"))
        #expect(avTransportRequests.contains { $0.url?.host == "kitchen.local" } == false)
    }

    @Test
    func migrateCoordinatorRejoinsEveryOtherMemberToNewCoordinator() async throws {
        GroupingServiceURLProtocol.reset(
            topologyResponse: Self.topologyEnvelope(
                """
                <ZoneGroups>
                  <ZoneGroup Coordinator="RINCON_KITCHEN" ID="RINCON_KITCHEN:123">
                    <ZoneGroupMember UUID="RINCON_KITCHEN" ZoneName="Kitchen" Location="http://kitchen.local:1400/xml/device_description.xml"/>
                    <ZoneGroupMember UUID="RINCON_PORT" ZoneName="Port" Location="http://port.local:1400/xml/device_description.xml"/>
                    <ZoneGroupMember UUID="RINCON_OFFICE" ZoneName="Office" Location="http://office.local:1400/xml/device_description.xml"/>
                    <ZoneGroupMember UUID="RINCON_BATH" ZoneName="Bath" Location="http://bath.local:1400/xml/device_description.xml"/>
                  </ZoneGroup>
                </ZoneGroups>
                """
            )
        )
        let service = Self.groupingService()

        try await service.migrateCoordinator(groupID: "RINCON_KITCHEN:123", toRoomName: "Port")

        let avTransportRequests = GroupingServiceURLProtocol.snapshot()
            .filter { $0.url?.path == "/MediaRenderer/AVTransport/Control" }
        #expect(avTransportRequests.first?.url?.host == "port.local")
        #expect(avTransportRequests.first?.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"")

        let joinRequests = avTransportRequests.dropFirst()
        #expect(Set(joinRequests.compactMap { $0.url?.host }) == ["kitchen.local", "office.local", "bath.local"])
        #expect(joinRequests.allSatisfy { $0.soapAction == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"" })
        #expect(joinRequests.allSatisfy { $0.body.contains("<CurrentURI>x-rincon:RINCON_PORT</CurrentURI>") })
    }

    private static func groupingService() -> SonosGroupingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupingServiceURLProtocol.self]
        let soapClient = SonosSOAPClient(urlSession: URLSession(configuration: configuration))
        let directory = SonosDirectory(
            zeroconfClient: SonosSpotifyZeroconfClient(urlSession: URLSession(configuration: configuration)),
            zoneGroupTopology: SonosZoneGroupTopology(soapClient: soapClient),
            resolver: SonosDNSSDResolver(commandRunner: GroupingServiceDiscoveryRunner())
        )
        return SonosGroupingService(
            directory: directory,
            avTransport: SonosAVTransport(soapClient: soapClient)
        )
    }

    private static func group(coordinator: String, members roomNames: [String]) -> SonosSpeakerGroup {
        SonosSpeakerGroup(
            id: "RINCON_\(coordinator.uppercased()):123",
            coordinatorID: "RINCON_\(coordinator.uppercased())",
            members: roomNames.map(speaker)
        )
    }

    private static func speaker(_ roomName: String) -> SonosSpeaker {
        SonosSpeaker(
            id: "RINCON_\(roomName.uppercased())",
            roomName: roomName,
            host: "\(roomName.lowercased()).local"
        )
    }

    private static func topologyEnvelope(_ topologyXML: String) -> String {
        """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"><CurrentZoneGroupState>\(topologyXML.xmlEscapedForGroupingServiceTest)</CurrentZoneGroupState></u:GetZoneGroupStateResponse></s:Body></s:Envelope>
        """
    }
}

private struct GroupingServiceRequest: Sendable {
    let url: URL?
    let soapAction: String?
    let body: String
}

private final class GroupingServiceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var topologyResponse = ""
    private nonisolated(unsafe) static var requests: [GroupingServiceRequest] = []

    static func reset(topologyResponse: String = "") {
        lock.withLock {
            self.topologyResponse = topologyResponse
            self.requests = []
        }
    }

    static func snapshot() -> [GroupingServiceRequest] {
        lock.withLock {
            requests
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(from: request)
        Self.append(
            GroupingServiceRequest(
                url: request.url,
                soapAction: request.value(forHTTPHeaderField: "SOAPACTION"),
                body: body
            )
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/ZoneGroupTopology/Control" {
            client?.urlProtocol(self, didLoad: Data(Self.currentTopologyResponse().utf8))
        } else {
            client?.urlProtocol(self, didLoad: Data("<ok/>".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func append(_ request: GroupingServiceRequest) {
        lock.withLock {
            requests.append(request)
        }
    }

    private static func currentTopologyResponse() -> String {
        lock.withLock {
            topologyResponse
        }
    }

    private static func body(from request: URLRequest) -> String {
        if let httpBody = request.httpBody {
            return String(data: httpBody, encoding: .utf8) ?? ""
        }

        guard let bodyStream = request.httpBodyStream else {
            return ""
        }

        bodyStream.open()
        defer { bodyStream.close() }

        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }

        while bodyStream.hasBytesAvailable {
            let count = bodyStream.read(buffer, maxLength: 1024)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class GroupingServiceDiscoveryRunner: SonosDiscoveryCommandRunning {
    func run(_ command: SonosDiscoveryCommand) throws -> SonosDiscoveryCommandResult {
        if command.arguments.first == "-B" {
            return SonosDiscoveryCommandResult(
                output: """
                10:00:00.000 Add 2 4 local. _sonos._tcp. RINCON_KITCHEN@Kitchen
                10:00:00.001 Add 2 4 local. _sonos._tcp. RINCON_PORT@Port
                10:00:00.002 Add 2 4 local. _sonos._tcp. RINCON_OFFICE@Office
                10:00:00.003 Add 2 4 local. _sonos._tcp. RINCON_BATH@Bath
                """,
                status: 0
            )
        }

        if command.arguments.first == "-L",
           command.arguments.count >= 2 {
            let instance = command.arguments[1]
            let hostByInstance = [
                "RINCON_KITCHEN@Kitchen": "kitchen.local",
                "RINCON_PORT@Port": "port.local",
                "RINCON_OFFICE@Office": "office.local",
                "RINCON_BATH@Bath": "bath.local",
            ]
            if let host = hostByInstance[instance] {
                return SonosDiscoveryCommandResult(
                    output: "location=http://\(host):1400/xml/device_description.xml",
                    status: 0
                )
            }
        }

        return SonosDiscoveryCommandResult(output: "", status: 1)
    }
}

private extension String {
    var xmlEscapedForGroupingServiceTest: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
