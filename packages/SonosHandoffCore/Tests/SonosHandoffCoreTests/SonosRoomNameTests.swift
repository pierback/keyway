import Testing
@testable import SonosHandoffCore

struct SonosRoomNameTests {
    @Test
    func normalizedTrimsWhitespaceAndDropsEmptyNames() {
        #expect(SonosRoomName.normalized(" Port\n") == "Port")
        #expect(SonosRoomName.normalized("   ") == nil)
        #expect(SonosRoomName.normalized(nil) == nil)
    }

    @Test
    func matchesIgnoresCaseAndOuterWhitespace() {
        #expect(SonosRoomName.matches(" port ", "PORT"))
        #expect(SonosRoomName.matches("Kitchen", " kitchen\n"))
    }

    @Test
    func optionalMatchesTreatsTwoMissingNamesAsEqual() {
        #expect(SonosRoomName.matches(nil, nil))
        #expect(SonosRoomName.matches(" ", nil))
        #expect(!SonosRoomName.matches("Port", nil))
    }
}
