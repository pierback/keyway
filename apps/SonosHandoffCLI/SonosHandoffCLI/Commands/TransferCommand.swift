import ArgumentParser
import Foundation
import SonosHandoffCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct TransferCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transfer",
        abstract: "Transfer the current Spotify session to a saved target."
    )

    @Argument(help: "Saved alias to transfer playback to.")
    var alias: String

    mutating func run() async throws {
        let result = await CLIContext.live().handoffService.transfer(to: alias)

        switch result {
        case .success:
            CLIIO.printLine("Transferred via Spotify Connect.")
        case .failure(_, let message):
            CLIIO.printError(message)
            throw ExitCode.failure
        }
    }
}
