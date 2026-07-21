import Foundation

@MainActor
final class MediaTransportCommandCenterFilter {
    private static let programmaticCommandCenterEchoMatchBudget = 3
    private static let applicationRetargetedMediaKeyEchoMinimumAge: TimeInterval = 0.35

    private struct TimedCommand {
        let command: MediaRemoteTransportCommand
        let metadata: MediaTransportInputMetadata?
        let commandCenterMetadata: MediaCommandCenterInputMetadata?
        let createdAt: Date
        let expiresAt: Date
        var remainingMatches: Int?
        let expectedTargetUnixProcessID: Int64?
        let expectedApplicationUnixProcessID: Int64?

        init(
            command: MediaRemoteTransportCommand,
            metadata: MediaTransportInputMetadata?,
            commandCenterMetadata: MediaCommandCenterInputMetadata?,
            createdAt: Date = Date(),
            expiresAt: Date,
            remainingMatches: Int?,
            expectedTargetUnixProcessID: Int64? = nil,
            expectedApplicationUnixProcessID: Int64? = nil
        ) {
            self.command = command
            self.metadata = metadata
            self.commandCenterMetadata = commandCenterMetadata
            self.createdAt = createdAt
            self.expiresAt = expiresAt
            self.remainingMatches = remainingMatches
            self.expectedTargetUnixProcessID = expectedTargetUnixProcessID
            self.expectedApplicationUnixProcessID = expectedApplicationUnixProcessID
        }
    }

    enum IgnoreReason: String {
        case programmaticEcho = "command_center_echo_ignored"
        case programmaticMediaKeyEcho = "programmatic_media_key_echo_ignored"
        case mediaKeyRebound = "media_key_rebound_ignored"
        case chooserTargetedMediaKeyEcho = "chooser_targeted_media_key_echo_ignored"
        case mediaKeyShadow = "command_center_media_key_shadow_ignored"
        case commandCenterInputShadow = "command_center_input_shadow_ignored"
        case commandCenterShadow = "media_key_command_center_shadow_ignored"
        case unpairedCommandCenterInput = "command_center_unpaired_input_ignored"

    }

    private let mediaKeyShadowInterval: TimeInterval
    private let commandCenterInputShadowInterval: TimeInterval
    private let programmaticCommandCenterEchoWindow: TimeInterval
    private let programmaticGeneratedMediaKeyCallbackWindow: TimeInterval
    private let physicalMediaKeyReboundWindow: TimeInterval
    private let chooserTargetedMediaKeyEchoWindow: TimeInterval
    private var inFlightProgrammaticCommandCenterEchoes: [TimedCommand] = []
    private var inFlightProgrammaticMediaKeyEchoes: [TimedCommand] = []
    private var inFlightChooserMediaKeyRebounds: [TimedCommand] = []
    private var inFlightChooserTargetedMediaKeyEchoes: [TimedCommand] = []
    private var mediaKeyShadow: TimedCommand?
    private var commandCenterInputShadow: TimedCommand?

    init(
        mediaKeyShadowInterval: TimeInterval,
        commandCenterInputShadowInterval: TimeInterval,
        programmaticCommandCenterEchoWindow: TimeInterval,
        programmaticGeneratedMediaKeyCallbackWindow: TimeInterval,
        physicalMediaKeyReboundWindow: TimeInterval,
        chooserTargetedMediaKeyEchoWindow: TimeInterval
    ) {
        self.mediaKeyShadowInterval = mediaKeyShadowInterval
        self.commandCenterInputShadowInterval = commandCenterInputShadowInterval
        self.programmaticCommandCenterEchoWindow = programmaticCommandCenterEchoWindow
        self.programmaticGeneratedMediaKeyCallbackWindow = programmaticGeneratedMediaKeyCallbackWindow
        self.physicalMediaKeyReboundWindow = physicalMediaKeyReboundWindow
        self.chooserTargetedMediaKeyEchoWindow = chooserTargetedMediaKeyEchoWindow
    }

    func noteMediaKey(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata? = nil
    ) {
        mediaKeyShadow = TimedCommand(
            command: command,
            metadata: metadata,
            commandCenterMetadata: nil,
            expiresAt: Date().addingTimeInterval(mediaKeyShadowInterval),
            remainingMatches: 3
        )
    }

    func noteCommandCenterInput(
        command: MediaRemoteTransportCommand,
        metadata: MediaCommandCenterInputMetadata? = nil
    ) {
        commandCenterInputShadow = TimedCommand(
            command: command,
            metadata: nil,
            commandCenterMetadata: metadata,
            expiresAt: Date().addingTimeInterval(commandCenterInputShadowInterval),
            remainingMatches: 2
        )
    }

    func beginProgrammaticDispatch(command: MediaRemoteTransportCommand) {
        pruneExpiredProgrammaticEchoes()
        let now = Date()
        let commandCenterExpiresAt = now.addingTimeInterval(programmaticCommandCenterEchoWindow)
        let mediaKeyExpiresAt = now.addingTimeInterval(programmaticGeneratedMediaKeyCallbackWindow)
        inFlightProgrammaticCommandCenterEchoes.append(TimedCommand(
            command: command,
            metadata: nil,
            commandCenterMetadata: nil,
            expiresAt: commandCenterExpiresAt,
            remainingMatches: Self.programmaticCommandCenterEchoMatchBudget
        ))
        inFlightProgrammaticMediaKeyEchoes.append(TimedCommand(
            command: command,
            metadata: nil,
            commandCenterMetadata: nil,
            expiresAt: mediaKeyExpiresAt,
            remainingMatches: Self.programmaticCommandCenterEchoMatchBudget
        ))
        inFlightChooserMediaKeyRebounds = []
        inFlightChooserTargetedMediaKeyEchoes = []
        mediaKeyShadow = nil
        commandCenterInputShadow = nil
    }

    func beginChooserDispatch(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata? = nil,
        targetUnixProcessID: Int64? = nil,
        applicationUnixProcessID: Int64? = nil
    ) {
        beginProgrammaticDispatch(command: command)
        let now = Date()
        let targetedMediaKeyEchoExpiresAt = now.addingTimeInterval(chooserTargetedMediaKeyEchoWindow)
        guard let metadata else {
            return
        }

        pruneExpiredChooserMediaKeyRebounds()
        let mediaKeyReboundExpiresAt = Date().addingTimeInterval(physicalMediaKeyReboundWindow)
        inFlightChooserMediaKeyRebounds = [
            TimedCommand(
                command: command,
                metadata: metadata,
                commandCenterMetadata: nil,
                expiresAt: mediaKeyReboundExpiresAt,
                remainingMatches: Self.programmaticCommandCenterEchoMatchBudget
            )
        ]
        inFlightChooserTargetedMediaKeyEchoes = [
            TimedCommand(
                command: command,
                metadata: metadata,
                commandCenterMetadata: nil,
                expiresAt: targetedMediaKeyEchoExpiresAt,
                remainingMatches: 1,
                expectedTargetUnixProcessID: targetUnixProcessID,
                expectedApplicationUnixProcessID: applicationUnixProcessID
            )
        ]
    }

    func ignoreReasonForMediaKey(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata? = nil
    ) -> IgnoreReason? {
        if consumeProgrammaticMediaKeyEcho(command: command, metadata: metadata) {
            return .programmaticMediaKeyEcho
        }

        if consumeChooserMediaKeyRebound(command: command, metadata: metadata) {
            return .mediaKeyRebound
        }

        if consumeChooserTargetedMediaKeyEcho(command: command, metadata: metadata) {
            return .chooserTargetedMediaKeyEcho
        }

        return ignoreCommandCenterShadowForMediaKey(command: command, metadata: metadata)
    }

    func ignoreReasonForCommandCenter(
        command: MediaRemoteTransportCommand,
        metadata: MediaCommandCenterInputMetadata? = nil
    ) -> IgnoreReason? {
        if let reason = ignoreProgrammaticEcho(
            command: command,
            metadata: metadata,
            reason: .programmaticEcho,
            inFlightEchoes: &inFlightProgrammaticCommandCenterEchoes
        ) {
            return reason
        }

        let now = Date()
        guard let mediaKeyShadow else {
            return ignoreCommandCenterInputShadow(command: command, metadata: metadata, now: now)
                ?? .unpairedCommandCenterInput
        }

        guard now <= mediaKeyShadow.expiresAt else {
            self.mediaKeyShadow = nil
            return ignoreCommandCenterInputShadow(command: command, metadata: metadata, now: now)
                ?? .unpairedCommandCenterInput
        }

        guard timedCommandMatches(mediaKeyShadow, command) else {
            return ignoreCommandCenterInputShadow(command: command, metadata: metadata, now: now)
                ?? .unpairedCommandCenterInput
        }
        consumeCurrentTimedCommand(value: &self.mediaKeyShadow)
        return .mediaKeyShadow
    }

    private func ignoreCommandCenterInputShadow(
        command: MediaRemoteTransportCommand,
        metadata: MediaCommandCenterInputMetadata?,
        now: Date
    ) -> IgnoreReason? {
        guard let commandCenterInputShadow else {
            return nil
        }

        guard now <= commandCenterInputShadow.expiresAt else {
            self.commandCenterInputShadow = nil
            return nil
        }

        guard timedCommandMatches(commandCenterInputShadow, command) else {
            return nil
        }
        guard commandCenterMetadataMatches(commandCenterInputShadow, metadata) else {
            return nil
        }

        consumeCurrentTimedCommand(value: &self.commandCenterInputShadow)
        return .commandCenterInputShadow
    }

    private func ignoreCommandCenterShadowForMediaKey(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata?
    ) -> IgnoreReason? {
        if metadata?.isPhysicalHIDSystemSource == true {
            return nil
        }

        let now = Date()
        guard let commandCenterInputShadow else {
            return nil
        }

        guard now <= commandCenterInputShadow.expiresAt else {
            self.commandCenterInputShadow = nil
            return nil
        }

        guard timedCommandMatches(commandCenterInputShadow, command) else {
            return nil
        }

        consumeCurrentTimedCommand(value: &self.commandCenterInputShadow)
        return .commandCenterShadow
    }

    private func ignoreProgrammaticEcho(
        command: MediaRemoteTransportCommand,
        metadata: MediaCommandCenterInputMetadata?,
        reason: IgnoreReason,
        inFlightEchoes: inout [TimedCommand]
    ) -> IgnoreReason? {
        if consumeTimedCommand(command: command, metadata: metadata, from: &inFlightEchoes) {
            return reason
        }

        return nil
    }

    private func pruneExpiredProgrammaticEchoes() {
        let now = Date()
        inFlightProgrammaticCommandCenterEchoes.removeAll { now > $0.expiresAt }
        inFlightProgrammaticMediaKeyEchoes.removeAll { now > $0.expiresAt }
        inFlightChooserTargetedMediaKeyEchoes.removeAll { now > $0.expiresAt }
    }

    private func pruneExpiredChooserMediaKeyRebounds() {
        let now = Date()
        inFlightChooserMediaKeyRebounds.removeAll { now > $0.expiresAt }
        inFlightChooserTargetedMediaKeyEchoes.removeAll { now > $0.expiresAt }
    }

    private func consumeChooserMediaKeyRebound(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata?
    ) -> Bool {
        let now = Date()
        inFlightChooserMediaKeyRebounds.removeAll { now > $0.expiresAt }
        guard let index = inFlightChooserMediaKeyRebounds.firstIndex(where: { value in
            timedCommandMatches(value, command)
                && mediaKeyMetadataMatches(value.metadata, metadata)
        }) else {
            return false
        }
        consumeTimedCommand(at: index, in: &inFlightChooserMediaKeyRebounds)
        return true
    }

    private func consumeChooserTargetedMediaKeyEcho(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata?
    ) -> Bool {
        guard let metadata,
              metadata.isPhysicalHIDSystemSource,
              !metadata.isUntargetedPhysicalHIDSystemSource
        else {
            return false
        }

        let now = Date()
        inFlightChooserTargetedMediaKeyEchoes.removeAll { now > $0.expiresAt }
        guard let index = inFlightChooserTargetedMediaKeyEchoes.firstIndex(where: { value in
            timedCommandMatches(value, command)
                && targetedMediaKeyEchoMatches(value, metadata, now: now)
        }) else {
            return false
        }
        consumeTimedCommand(at: index, in: &inFlightChooserTargetedMediaKeyEchoes)
        commandCenterInputShadow = TimedCommand(
            command: command,
            metadata: nil,
            commandCenterMetadata: nil,
            expiresAt: now.addingTimeInterval(commandCenterInputShadowInterval),
            remainingMatches: 2
        )
        return true
    }

    private func consumeProgrammaticMediaKeyEcho(
        command: MediaRemoteTransportCommand,
        metadata: MediaTransportInputMetadata?
    ) -> Bool {
        guard let metadata,
              !metadata.isPhysicalHIDSystemSource
        else {
            return false
        }

        let now = Date()
        inFlightProgrammaticMediaKeyEchoes.removeAll { now > $0.expiresAt }
        guard let index = inFlightProgrammaticMediaKeyEchoes.firstIndex(where: { value in
            timedCommandMatches(value, command)
        }) else {
            return false
        }
        consumeTimedCommand(at: index, in: &inFlightProgrammaticMediaKeyEchoes)
        return true
    }

    private func consumeTimedCommand(
        command: MediaRemoteTransportCommand,
        metadata: MediaCommandCenterInputMetadata?,
        from values: inout [TimedCommand]
    ) -> Bool {
        let now = Date()
        values.removeAll { now > $0.expiresAt }
        guard let index = values.firstIndex(where: { value in
            timedCommandMatches(value, command)
                && commandCenterMetadataMatches(value, metadata)
        }) else {
            return false
        }
        consumeTimedCommand(at: index, in: &values)
        return true
    }

    private func consumeTimedCommand(at index: Int, in values: inout [TimedCommand]) {
        guard let remainingMatches = values[index].remainingMatches else {
            return
        }
        let updatedMatches = remainingMatches - 1
        if updatedMatches <= 0 {
            values.remove(at: index)
        } else {
            values[index].remainingMatches = updatedMatches
        }
    }

    private func consumeCurrentTimedCommand(value: inout TimedCommand?) {
        guard let remainingMatches = value?.remainingMatches else {
            return
        }
        let updatedMatches = remainingMatches - 1
        if updatedMatches <= 0 {
            value = nil
        } else {
            value?.remainingMatches = updatedMatches
        }
    }

    private func commandsMatch(
        _ expected: MediaRemoteTransportCommand,
        _ actual: MediaRemoteTransportCommand
    ) -> Bool {
        if expected == actual {
            return true
        }

        return isPlayPauseFamily(expected) && isPlayPauseFamily(actual)
    }

    private func timedCommandMatches(
        _ expected: TimedCommand,
        _ actual: MediaRemoteTransportCommand
    ) -> Bool {
        commandsMatch(expected.command, actual)
    }

    private func commandCenterMetadataMatches(
        _ expected: TimedCommand,
        _ actual: MediaCommandCenterInputMetadata?
    ) -> Bool {
        guard let expectedMetadata = expected.commandCenterMetadata else {
            return true
        }
        guard let actual else {
            return false
        }
        return expectedMetadata.matchesSameCommandCenterEvent(as: actual)
    }

    private func mediaKeyMetadataMatches(
        _ expected: MediaTransportInputMetadata?,
        _ actual: MediaTransportInputMetadata?
    ) -> Bool {
        guard let expected, let actual else {
            return false
        }
        return expected.matchesSameGeneratedMediaKey(as: actual)
    }

    private func targetedMediaKeyEchoMatches(
        _ expected: TimedCommand,
        _ actual: MediaTransportInputMetadata,
        now: Date
    ) -> Bool {
        guard let expectedMetadata = expected.metadata else {
            return true
        }
        return expectedMetadata.isPhysicalHIDSystemSource
            && actual.isPhysicalHIDSystemSource
            && expectedMetadata.matchesSameGeneratedMediaKey(as: actual)
            && reboundTargetUnixProcessIDMatches(expected, actual.targetUnixProcessID, now: now)
    }

    private func reboundTargetUnixProcessIDMatches(
        _ expected: TimedCommand,
        _ actual: Int64,
        now: Date
    ) -> Bool {
        if targetUnixProcessIDMatches(expected.expectedTargetUnixProcessID, actual) {
            return true
        }
        guard targetUnixProcessIDMatches(expected.expectedApplicationUnixProcessID, actual) else {
            return false
        }
        return now.timeIntervalSince(expected.createdAt) >= Self.applicationRetargetedMediaKeyEchoMinimumAge
    }

    private func targetUnixProcessIDMatches(
        _ expected: Int64?,
        _ actual: Int64
    ) -> Bool {
        guard let expected, expected > 0 else {
            return false
        }
        return actual == expected
    }

    private func isPlayPauseFamily(_ command: MediaRemoteTransportCommand) -> Bool {
        command == .playPause || command == .pause || command == .play
    }
}
