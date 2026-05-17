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

    @Test
    func recognizesOnlyActiveSuggestionIdentifiers() {
        #expect(SonosGroupSuggestionNotificationIdentifier.isSuggestionID("group-suggestion-RINCON_OFFICE"))
        #expect(!SonosGroupSuggestionNotificationIdentifier.isSuggestionID("group-suggestion-failure-RINCON_OFFICE"))
        #expect(!SonosGroupSuggestionNotificationIdentifier.isSuggestionID("other-RINCON_OFFICE"))
    }

    @Test
    func matchesExactOrRetargetedSuggestionIdentifier() {
        let notificationID = SonosGroupSuggestionNotificationIdentifier.suggestionID("RINCON_OFFICE|Port")

        #expect(
            SonosGroupSuggestionNotificationIdentifier.matchesSuggestionID(
                notificationID,
                ids: ["RINCON_OFFICE|Port"]
            )
        )
        #expect(
            SonosGroupSuggestionNotificationIdentifier.matchesSuggestionID(
                notificationID,
                ids: ["RINCON_OFFICE|Kitchen"]
            )
        )
        #expect(
            SonosGroupSuggestionNotificationIdentifier.matchesSuggestionID(
                notificationID,
                ids: ["RINCON_OFFICE"]
            )
        )
        #expect(
            !SonosGroupSuggestionNotificationIdentifier.matchesSuggestionID(
                notificationID,
                ids: ["RINCON_KITCHEN|Port"]
            )
        )
    }

    @Test
    func neverMatchesFailureIdentifierAsActiveSuggestion() {
        let failureID = SonosGroupSuggestionNotificationIdentifier.failureID("RINCON_OFFICE|Port")

        #expect(
            !SonosGroupSuggestionNotificationIdentifier.matchesSuggestionID(
                failureID,
                ids: ["RINCON_OFFICE|Port", "RINCON_OFFICE"]
            )
        )
    }
}
