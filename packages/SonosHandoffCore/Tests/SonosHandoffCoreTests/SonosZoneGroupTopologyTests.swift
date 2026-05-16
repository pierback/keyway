import Foundation
import Testing
@testable import SonosHandoffCore

@Suite(.serialized)
struct SonosZoneGroupTopologyTests {
    @Test
    func parsesGroupedAndStandaloneRoomsFromTopologyXML() throws {
        let state = try SonosZoneGroupStateParser.parse(
            Self.topologyXML,
            visibleSpeakers: [
                SonosSpeaker(id: "RINCON_A", roomName: "Kitchen", host: "kitchen.local"),
                SonosSpeaker(id: "RINCON_B", roomName: "Port", host: "port.local"),
                SonosSpeaker(id: "RINCON_C", roomName: "Office", host: "office.local"),
            ]
        )

        #expect(state.groups.map(\.displayName) == ["Kitchen + Port", "Office"])
        #expect(state.groups[0].coordinatorID == "RINCON_A")
        #expect(state.groups[0].members.map(\.roomName) == ["Kitchen", "Port"])
        #expect(state.groups[0].members.map(\.host) == ["kitchen.local", "port.local"])
        #expect(state.groups[1].members.map(\.roomName) == ["Office"])
    }

    @Test
    func skipsInvisibleBondedMembers() throws {
        let state = try SonosZoneGroupStateParser.parse(
            Self.topologyXML,
            visibleSpeakers: []
        )

        #expect(state.groups[0].members.map(\.id).contains("RINCON_SUB") == false)
        #expect(state.speakers.map(\.roomName) == ["Kitchen", "Port", "Office"])
    }

    @Test
    func readsTopologyViaSOAPEnvelope() async throws {
        ZoneGroupTopologyURLProtocol.responseBody = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"><CurrentZoneGroupState>\(Self.topologyXML.xmlEscaped)</CurrentZoneGroupState></u:GetZoneGroupStateResponse></s:Body></s:Envelope>
        """
        ZoneGroupTopologyURLProtocol.requestedURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoneGroupTopologyURLProtocol.self]
        let topology = SonosZoneGroupTopology(
            soapClient: SonosSOAPClient(urlSession: URLSession(configuration: configuration))
        )

        let state = try await topology.groupState(
            host: "kitchen.local",
            visibleSpeakers: [SonosSpeaker(id: "RINCON_A", roomName: "Kitchen", host: "kitchen.local")]
        )

        #expect(state.groups.count == 2)
        #expect(state.groups[0].displayName == "Kitchen + Port")
        #expect(ZoneGroupTopologyURLProtocol.requestedURLs.map(\.path) == ["/ZoneGroupTopology/Control"])
    }

    private static let topologyXML = """
    <ZoneGroups>
      <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:123">
        <ZoneGroupMember UUID="RINCON_B" ZoneName="Port" Location="http://port.local:1400/xml/device_description.xml"/>
        <ZoneGroupMember UUID="RINCON_SUB" ZoneName="Kitchen Sub" Invisible="1" Location="http://sub.local:1400/xml/device_description.xml"/>
        <ZoneGroupMember UUID="RINCON_A" ZoneName="Kitchen" Location="http://kitchen.local:1400/xml/device_description.xml"/>
      </ZoneGroup>
      <ZoneGroup Coordinator="RINCON_C" ID="RINCON_C:456">
        <ZoneGroupMember UUID="RINCON_C" ZoneName="Office" Location="http://office.local:1400/xml/device_description.xml"/>
      </ZoneGroup>
    </ZoneGroups>
    """
}

private final class ZoneGroupTopologyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = ""
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestedURLs.append(request.url!)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
