import Testing
@testable import SonosHandoffCore

struct SonosGroupSuggestionNotificationIdentifierTests {
    @Test
    func buildsSuggestionAndFailureIdentifiers() {
        #expect(
            SonosGroupSuggestionNotificationIdentifier.suggestionID("RINCON_OFFICE|Kitchen")
                == "group-suggestion-RINCON_OFFICE"
        )
        #expect(
            SonosGroupSuggestionNotificationIdentifier.failureID("RINCON_OFFICE|Kitchen")
                == "group-suggestion-failure-RINCON_OFFICE"
        )
    }

    @Test
    func buildsAllNotificationIdentifiersForSpeakerScopedCancellation() {
        #expect(
            SonosGroupSuggestionNotificationIdentifier.allIDs("RINCON_OFFICE|Kitchen")
                == [
                    "group-suggestion-RINCON_OFFICE",
                    "group-suggestion-failure-RINCON_OFFICE",
                ]
        )
        #expect(
            SonosGroupSuggestionNotificationIdentifier.allIDs([
                "RINCON_OFFICE|Kitchen",
                "RINCON_OFFICE|Port",
            ])
            == [
                "group-suggestion-RINCON_OFFICE",
                "group-suggestion-failure-RINCON_OFFICE",
            ]
        )
    }

}
