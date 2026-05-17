import Foundation
import Testing
@testable import SonosHandoffCore

struct SonosGroupSuggestionTests {
    @Test
    func buildsStableIdentityTitleAndReference() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        let suggestion = SonosGroupSuggestion(
            speaker: speaker("Office"),
            coordinatorRoomName: "Kitchen",
            groupDisplayName: "Kitchen + Port",
            detectedAt: detectedAt
        )

        #expect(suggestion.id == "RINCON_OFFICE|Kitchen")
        #expect(suggestion.title == "Add Office to Kitchen + Port?")
        #expect(suggestion.reference == SonosGroupSuggestionReference(
            speakerID: "RINCON_OFFICE",
            coordinatorRoomName: "Kitchen"
        ))
        #expect(suggestion.matches(identifier: "RINCON_OFFICE|Kitchen"))
        #expect(suggestion.matches(identifier: "RINCON_OFFICE|Port"))
        #expect(!suggestion.matches(identifier: "RINCON_BATH|Kitchen"))
    }

    @Test
    func refreshedSuggestionPreservesOriginalDetectionTime() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        let suggestion = SonosGroupSuggestion(
            speaker: speaker("Office"),
            coordinatorRoomName: "Kitchen",
            groupDisplayName: "Kitchen + Port",
            detectedAt: detectedAt
        )

        let refreshed = suggestion.refreshed(
            with: SonosGroupSuggestionCandidate(
                speaker: speaker("Office"),
                coordinatorRoomName: "Port",
                groupDisplayName: "Port + 2"
            )
        )

        #expect(refreshed.id == "RINCON_OFFICE|Port")
        #expect(refreshed.title == "Add Office to Port + 2?")
        #expect(refreshed.detectedAt == detectedAt)
    }

    @Test
    func collectionReplacesExistingSuggestionForSameSpeaker() {
        let firstDetectedAt = Date(timeIntervalSince1970: 100)
        let secondDetectedAt = Date(timeIntervalSince1970: 200)
        var collection = SonosGroupSuggestionCollection()

        collection.present(SonosGroupSuggestion(
            speaker: speaker("Office"),
            coordinatorRoomName: "Kitchen",
            groupDisplayName: "Kitchen",
            detectedAt: firstDetectedAt
        ))
        collection.present(SonosGroupSuggestion(
            speaker: speaker("Office"),
            coordinatorRoomName: "Port",
            groupDisplayName: "Port + Kitchen",
            detectedAt: secondDetectedAt
        ))

        #expect(collection.suggestions.count == 1)
        #expect(collection.suggestions[0].id == "RINCON_OFFICE|Port")
        #expect(collection.suggestions[0].detectedAt == secondDetectedAt)
    }

    @Test
    func collectionRefreshReturnsOnlyChangedSuggestions() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        var collection = SonosGroupSuggestionCollection(suggestions: [
            SonosGroupSuggestion(
                speaker: speaker("Office"),
                coordinatorRoomName: "Kitchen",
                groupDisplayName: "Kitchen",
                detectedAt: detectedAt
            ),
            SonosGroupSuggestion(
                speaker: speaker("Bath"),
                coordinatorRoomName: "Kitchen",
                groupDisplayName: "Kitchen",
                detectedAt: detectedAt
            ),
        ])

        let changed = collection.refresh([
            SonosGroupSuggestionCandidate(
                speaker: speaker("Office"),
                coordinatorRoomName: "Port",
                groupDisplayName: "Port + Kitchen"
            ),
            SonosGroupSuggestionCandidate(
                speaker: speaker("Bath"),
                coordinatorRoomName: "Kitchen",
                groupDisplayName: "Kitchen"
            ),
        ])

        #expect(changed.map(\.id) == ["RINCON_OFFICE|Port"])
        #expect(collection.suggestions.map(\.id) == ["RINCON_OFFICE|Port", "RINCON_BATH|Kitchen"])
        #expect(collection.suggestions.map(\.detectedAt) == [detectedAt, detectedAt])
    }

    @Test
    func collectionClearsExactRetargetedAndSpeakerIdentifiers() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        var collection = SonosGroupSuggestionCollection(suggestions: [
            SonosGroupSuggestion(
                speaker: speaker("Office"),
                coordinatorRoomName: "Kitchen",
                groupDisplayName: "Kitchen",
                detectedAt: detectedAt
            ),
            SonosGroupSuggestion(
                speaker: speaker("Bath"),
                coordinatorRoomName: "Kitchen",
                groupDisplayName: "Kitchen",
                detectedAt: detectedAt
            ),
        ])

        collection.clear(ids: ["RINCON_OFFICE|Port", "RINCON_BATH"])

        #expect(collection.suggestions.isEmpty)
    }

    private func speaker(_ roomName: String) -> SonosSpeaker {
        SonosSpeaker(
            id: "RINCON_\(roomName.uppercased())",
            roomName: roomName,
            host: "\(roomName.lowercased()).local"
        )
    }
}
