import Testing
@testable import SonosHandoffCore

struct DNSSDNameTests {
    @Test
    func unescapesDecimalEscapedRoomNames() {
        #expect(DNSSDName.unescaped("Living\\032Room") == "Living Room")
        #expect(DNSSDName.unescaped("Kitchen\\032Port\\040Left\\041") == "Kitchen Port(Left)")
        #expect(DNSSDName.unescaped("Caf\\195\\169") == "Café")
    }

    @Test
    func leavesNonDecimalEscapesReadable() {
        #expect(DNSSDName.unescaped("Port") == "Port")
        #expect(DNSSDName.unescaped("Room\\x") == "Roomx")
    }
}
