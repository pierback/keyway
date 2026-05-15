import ArgumentParser
import Foundation
import SonosHandoffCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct TargetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "target",
        abstract: "Manage saved handoff targets.",
        subcommands: [TargetAddCommand.self, TargetListCommand.self]
    )
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct TargetAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add or replace a saved target alias."
    )

    @Argument(help: "Alias used when invoking the target.")
    var alias: String

    @Option(name: [.short, .long], help: "Exact Spotify device name to bind to this alias.")
    var device: String?

    mutating func run() async throws {
        let context = CLIContext.live()
        var config = try context.configStore.load()
        let deviceName = device ?? alias.capitalized
        let savedTarget = SavedTarget(alias: alias, spotifyDeviceName: deviceName)
        let filteredTargets = config.targets.filter { $0.alias.caseInsensitiveCompare(alias) != .orderedSame }
        config = AppConfig(
            targets: filteredTargets + [savedTarget],
            spotifyClientID: config.spotifyClientID,
            spotifyVirtualDisplayName: config.spotifyVirtualDisplayName
        )
        try context.configStore.save(config)
        CLIIO.printLine("Saved target '\(alias)' -> '\(deviceName)'.")
    }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct TargetListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List saved handoff targets."
    )

    mutating func run() async throws {
        let config = try CLIContext.live().configStore.load()

        guard !config.targets.isEmpty else {
            CLIIO.printLine("No saved targets.")
            return
        }

        for target in config.targets.sorted(by: { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }) {
            CLIIO.printLine("\(target.alias)\t\(target.spotifyDeviceName)")
        }
    }
}
