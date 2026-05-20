import Foundation
import Testing
@testable import SonosHandoffCore

struct SonosTransferSuggestionTests {
    @Test
    func buildsStableIdentityTitleAndReference() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        let suggestion = SonosTransferSuggestion(
            speaker: speaker("Office"),
            outputDisplayName: "Office",
            sourceDeviceName: "MacBook Pro",
            detectedAt: detectedAt
        )

        #expect(suggestion.id == "RINCON_OFFICE")
        #expect(suggestion.title == "Move Spotify playback to Office?")
        #expect(suggestion.reference == SonosTransferSuggestionReference(speakerID: "RINCON_OFFICE"))
        #expect(suggestion.matches(identifier: "RINCON_OFFICE"))
        #expect(!suggestion.matches(identifier: "RINCON_BATH"))
    }

    @Test
    func refreshedSuggestionPreservesOriginalDetectionTime() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        let suggestion = SonosTransferSuggestion(
            speaker: speaker("Kitchen"),
            outputDisplayName: "Kitchen",
            sourceDeviceName: "MacBook Pro",
            detectedAt: detectedAt
        )

        let refreshed = suggestion.refreshed(
            with: SonosTransferSuggestionCandidate(
                speaker: speaker("Kitchen"),
                outputDisplayName: "Kitchen + Port",
                sourceDeviceName: "iPhone"
            )
        )

        #expect(refreshed.id == "RINCON_KITCHEN")
        #expect(refreshed.title == "Move Spotify playback to Kitchen + Port?")
        #expect(refreshed.sourceDeviceName == "iPhone")
        #expect(refreshed.detectedAt == detectedAt)
    }

    @Test
    func collectionReplacesExistingSuggestionForSameSpeaker() {
        let firstDetectedAt = Date(timeIntervalSince1970: 100)
        let secondDetectedAt = Date(timeIntervalSince1970: 200)
        var collection = SonosTransferSuggestionCollection()

        collection.present(SonosTransferSuggestion(
            speaker: speaker("Office"),
            outputDisplayName: "Office",
            sourceDeviceName: "MacBook Pro",
            detectedAt: firstDetectedAt
        ))
        collection.present(SonosTransferSuggestion(
            speaker: speaker("Office"),
            outputDisplayName: "Office",
            sourceDeviceName: "iPhone",
            detectedAt: secondDetectedAt
        ))

        #expect(collection.suggestions.count == 1)
        #expect(collection.suggestions[0].id == "RINCON_OFFICE")
        #expect(collection.suggestions[0].sourceDeviceName == "iPhone")
        #expect(collection.suggestions[0].detectedAt == secondDetectedAt)
    }

    @Test
    func collectionRefreshReturnsOnlyChangedSuggestions() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        var collection = SonosTransferSuggestionCollection(suggestions: [
            SonosTransferSuggestion(
                speaker: speaker("Kitchen"),
                outputDisplayName: "Kitchen",
                sourceDeviceName: "MacBook Pro",
                detectedAt: detectedAt
            ),
            SonosTransferSuggestion(
                speaker: speaker("Bath"),
                outputDisplayName: "Bath",
                sourceDeviceName: "MacBook Pro",
                detectedAt: detectedAt
            ),
        ])

        let changed = collection.refresh([
            SonosTransferSuggestionCandidate(
                speaker: speaker("Kitchen"),
                outputDisplayName: "Kitchen + Port",
                sourceDeviceName: "iPhone"
            ),
            SonosTransferSuggestionCandidate(
                speaker: speaker("Bath"),
                outputDisplayName: "Bath",
                sourceDeviceName: "MacBook Pro"
            ),
        ])

        #expect(changed.map(\.id) == ["RINCON_KITCHEN"])
        #expect(collection.suggestions.map(\.title) == [
            "Move Spotify playback to Kitchen + Port?",
            "Move Spotify playback to Bath?",
        ])
        #expect(collection.suggestions.map(\.detectedAt) == [detectedAt, detectedAt])
    }

    @Test
    func collectionClearsExactSpeakerIdentifiers() {
        let detectedAt = Date(timeIntervalSince1970: 100)
        var collection = SonosTransferSuggestionCollection(suggestions: [
            SonosTransferSuggestion(
                speaker: speaker("Office"),
                outputDisplayName: "Office",
                sourceDeviceName: "MacBook Pro",
                detectedAt: detectedAt
            ),
            SonosTransferSuggestion(
                speaker: speaker("Bath"),
                outputDisplayName: "Bath",
                sourceDeviceName: "MacBook Pro",
                detectedAt: detectedAt
            ),
        ])

        collection.clear(ids: ["RINCON_OFFICE", "RINCON_BATH"])

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
