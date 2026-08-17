import Testing
@testable import SonosHandoffCore

struct ChromiumBrowserSetupPolicyTests {
    @Test
    func installConsentKeepsTheRequiredDataUseDisclosureAndAffirmativeAction() {
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("media metadata"))
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("page titles and URLs"))
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("playback state"))
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("does not send this data off your Mac"))
        #expect(ChromiumBrowserSetupPolicy.dataUseDisclosure.contains("only if you agree"))
        #expect(
            ChromiumBrowserSetupPolicy.consentActionTitle(
                browserDisplayName: "Google Chrome",
                hasConnectedProfile: false
            ) == "Install in Google Chrome"
        )
        #expect(
            ChromiumBrowserSetupPolicy.consentActionTitle(
                browserDisplayName: "Google Chrome",
                hasConnectedProfile: true
            ) == "Install in another Google Chrome profile"
        )
    }
}
