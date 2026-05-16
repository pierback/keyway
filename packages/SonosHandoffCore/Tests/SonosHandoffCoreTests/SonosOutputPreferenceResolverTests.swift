import Testing
@testable import SonosHandoffCore

struct SonosOutputPreferenceResolverTests {
    private let resolver = SonosOutputPreferenceResolver()

    @Test
    func targetFindsAliasCaseInsensitivelyAndTrimsWhitespace() {
        let config = AppConfig(targets: [
            SavedTarget(alias: " Office ", spotifyDeviceName: "Office Speaker"),
        ])

        let target = resolver.target(alias: "office", in: config)

        #expect(target?.spotifyDeviceName == "Office Speaker")
    }

    @Test
    func preferredRoomNamesPreferPortAliasThenFirstTargetThenFallback() {
        let config = AppConfig(targets: [
            SavedTarget(alias: "Kitchen", spotifyDeviceName: "Kitchen"),
            SavedTarget(alias: "Port", spotifyDeviceName: "Office Port"),
        ])

        #expect(resolver.preferredRoomNames(in: config) == ["Office Port", "Kitchen", "Port"])
    }

    @Test
    func preferredRoomNamesRemoveDuplicateRoomNamesUsingSharedRoomPolicy() {
        let config = AppConfig(targets: [
            SavedTarget(alias: "Port", spotifyDeviceName: " Port\n"),
            SavedTarget(alias: "Fallback", spotifyDeviceName: "Kitchen"),
        ])

        #expect(resolver.preferredRoomNames(in: config) == ["Port"])
    }

    @Test
    func preferredRoomNamesFallBackToPortWhenConfigIsMissingOrEmpty() {
        #expect(resolver.preferredRoomNames(in: nil) == ["Port"])
        #expect(resolver.preferredRoomNames(in: AppConfig()) == ["Port"])
    }

    @Test
    func preferredRoomNamePreservesSelectedRoomBeforeConfigFallbacks() {
        let config = AppConfig(targets: [
            SavedTarget(alias: "Port", spotifyDeviceName: "Port"),
        ])

        #expect(resolver.preferredRoomName(selectedRoomName: " Kitchen\n", config: config) == "Kitchen")
    }
}
