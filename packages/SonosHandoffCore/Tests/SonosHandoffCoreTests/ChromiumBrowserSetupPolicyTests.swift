import Testing
@testable import SonosHandoffCore

struct ChromiumBrowserSetupPolicyTests {
    @Test
    func developerModeSetupKeepsTheRequiredDataUseDisclosureAndAffirmativeAction() {
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("media info"))
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("page titles/URLs"))
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("playback state"))
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("does not send this data off your Mac"))
        #expect(
            ChromiumBrowserSetupPolicy.setupActionTitle(hasConnectedProfile: false) == "Connect"
        )
        #expect(
            ChromiumBrowserSetupPolicy.setupActionTitle(hasConnectedProfile: true) == "Add Profile"
        )
    }
}
