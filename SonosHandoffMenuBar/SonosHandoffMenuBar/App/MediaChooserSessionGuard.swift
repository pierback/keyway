import Foundation

@MainActor
final class MediaChooserSessionGuard {
    private struct Session {
        let id: UUID
        let command: MediaRemoteTransportCommand
    }

    private var active: Session?

    var isActive: Bool {
        active != nil
    }

    var stateName: String {
        active == nil ? "inactive" : "visible"
    }

    func begin(
        command: MediaRemoteTransportCommand?
    ) -> UUID {
        let id = UUID()
        if let command {
            active = Session(
                id: id,
                command: command
            )
        }
        return id
    }

    func activeCommandRawValue(for id: UUID) -> String? {
        activeCommand(for: id)?.rawValue
    }

    func activeCommand(for id: UUID) -> MediaRemoteTransportCommand? {
        guard active?.id == id else { return nil }
        return active?.command
    }

    @discardableResult
    func finish(
        id: UUID,
        selected: Bool = false
    ) -> Bool {
        guard active?.id == id else {
            return false
        }
        active = nil
        return true
    }
}
