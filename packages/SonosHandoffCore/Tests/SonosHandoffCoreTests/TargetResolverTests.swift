import Testing
@testable import SonosHandoffCore

struct TargetResolverTests {
    @Test
    func resolveFindsAliasCaseInsensitively() {
        let resolver = TargetResolver()
        let config = AppConfig(targets: [
            SavedTarget(alias: "Office", spotifyDeviceName: "Office Speaker"),
        ])

        let target = resolver.resolve(alias: "office", in: config)

        #expect(target?.spotifyDeviceName == "Office Speaker")
    }
}
