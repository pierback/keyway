import ArgumentParser
import Foundation
import SonosHandoffCore

public struct CLIContext {
    let configStore: any ConfigStoring
    let tokenStore: any TokenStoring
    let connectTokenStatusStore: any ConnectTokenStatusChecking
    let accessibilityAutomator: any AccessibilityAutomating
    let handoffService: any HandoffPerforming
    let doctorService: any DoctorPerforming
    let authCoordinator: any SpotifyAuthCoordinating

    static func live() -> CLIContext {
        let configStore = ConfigStore()
        let tokenStore = KeychainTokenStore()
        let connectTokenStatusStore = ConnectTokenStatusStore()
        let accessibilityAutomator = SpotifyUIAutomator()
        let handoffService = SpotifyConnectHandoffService(configStore: configStore)
        let doctorService = DoctorService(
            configStore: configStore,
            connectTokenStatusStore: connectTokenStatusStore,
            accessibilityAutomator: accessibilityAutomator
        )
        let authCoordinator = SpotifyAuthCoordinator(tokenStore: tokenStore, configStore: configStore)

        return CLIContext(
            configStore: configStore,
            tokenStore: tokenStore,
            connectTokenStatusStore: connectTokenStatusStore,
            accessibilityAutomator: accessibilityAutomator,
            handoffService: handoffService,
            doctorService: doctorService,
            authCoordinator: authCoordinator
        )
    }
}

public enum CLIIO {
    static func printLine(_ message: String) {
        Swift.print(message)
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public enum CLIRunner {
    public static func main() async {
        do {
            var command = try SonosHandoffCommandLine.parseAsRoot()

            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            SonosHandoffCommandLine.exit(withError: error)
        }
    }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct SonosHandoffCommandLine: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sonos-handoff",
        abstract: "Hand off Spotify playback to Sonos while keeping Spotify as the controller.",
        subcommands: [
            AuthCommand.self,
            TargetCommand.self,
            TransferCommand.self,
            DoctorCommand.self,
        ]
    )

    public init() {}
}
