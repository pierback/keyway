import Testing
@testable import SonosHandoffCore

struct SonosDNSSDRecordParserTests {
    @Test
    func parsesSortedUniqueSonosBrowseInstances() {
        let output = """
        10:00:00.000  Add     3  14 local. _sonos._tcp. RINCON_222@Port
        noise without service marker
        10:00:00.100  Add     3  14 local. _sonos._tcp. RINCON_111@Kitchen
        10:00:00.200  Add     3  14 local. _sonos._tcp. RINCON_222@Port
        """

        #expect(SonosDNSSDRecordParser.instances(fromBrowseOutput: output) == [
            "RINCON_111@Kitchen",
            "RINCON_222@Port",
        ])
    }

    @Test
    func matchesDecodedRoomNamesCaseInsensitively() {
        let line = "10:00:00.000 Add local. _sonos._tcp. RINCON_333@Living\\032Room"

        #expect(SonosDNSSDRecordParser.instance(fromBrowseLine: line, matchingRoomName: "living room") == "RINCON_333@Living\\032Room")
        #expect(SonosDNSSDRecordParser.instance(fromBrowseLine: line, matchingRoomName: " living room\n") == "RINCON_333@Living\\032Room")
        #expect(SonosDNSSDRecordParser.roomName(fromInstance: "RINCON_333@Living\\032Room") == "Living Room")
        #expect(SonosDNSSDRecordParser.speakerID(fromInstance: "RINCON_333@Living\\032Room") == "RINCON_333")
    }

    @Test
    func rejectsBrowseLinesWithoutReadableRoomName() {
        #expect(SonosDNSSDRecordParser.instance(fromBrowseLine: "local. _sonos._tcp. RINCON_444@") == nil)
        #expect(SonosDNSSDRecordParser.instance(fromBrowseLine: "local. _spotify-connect._tcp. RINCON_444@Port") == nil)
    }

    @Test
    func parsesResolveHost() {
        let output = "hostname = Port.local. location=http://192.168.1.44:1400/xml/device_description.xml"

        #expect(SonosDNSSDRecordParser.host(fromResolveOutput: output) == "192.168.1.44")
        #expect(SonosDNSSDRecordParser.resolveOutputContainsHost(output))
        #expect(!SonosDNSSDRecordParser.resolveOutputContainsHost("no location"))
    }
}
