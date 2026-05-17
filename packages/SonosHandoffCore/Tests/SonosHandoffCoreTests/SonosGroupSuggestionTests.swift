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

    private func speaker(_ roomName: String) -> SonosSpeaker {
        SonosSpeaker(
            id: "RINCON_\(roomName.uppercased())",
            roomName: roomName,
            host: "\(roomName.lowercased()).local"
        )
    }
}
