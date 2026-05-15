import ArgumentParser
import Foundation

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage the legacy Spotify Web API OAuth token.",
        subcommands: [AuthLoginCommand.self]
    )
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AuthLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Refresh the legacy Spotify Web API OAuth token. This does not create the Desktop Connect token used for Sonos handoff."
    )

    mutating func run() async throws {
        do {
            try await CLIContext.live().authCoordinator.login()
            CLIIO.printLine("Spotify Web API sign-in completed. Desktop Connect token is still required for Sonos handoff.")
        } catch {
            CLIIO.printError(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}
