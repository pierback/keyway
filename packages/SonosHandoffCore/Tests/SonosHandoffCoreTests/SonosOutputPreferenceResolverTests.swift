import Testing
@testable import SonosHandoffCore

struct SonosOutputPreferenceResolverTests {
    private let resolver = SonosOutputPreferenceResolver()

    @Test
    func preferredRoomNamesFallBackToPort() {
        #expect(resolver.preferredRoomNames() == ["Port"])
    }

    @Test
    func preferredRoomNamePreservesSelectedRoomBeforeFallback() {
        #expect(resolver.preferredRoomName(selectedRoomName: " Kitchen\n") == "Kitchen")
    }
}
