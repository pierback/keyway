import ArgumentParser
import Foundation

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check local auth, Spotify app, accessibility, and target configuration."
    )

    mutating func run() async throws {
        let report = try await CLIContext.live().doctorService.run()

        CLIIO.printLine("spotifyAuthenticated\t\(report.spotifyAuthenticated)")
        CLIIO.printLine("spotifyDesktopTokenAvailable\t\(report.spotifyDesktopTokenAvailable)")
        CLIIO.printLine("spotifyWebAPITokenAvailable\t\(report.spotifyWebAPITokenAvailable)")
        CLIIO.printLine("spotifyAppInstalled\t\(report.spotifyAppInstalled)")
        CLIIO.printLine("spotifyAppRunning\t\(report.spotifyAppRunning)")
        CLIIO.printLine("accessibilityGranted\t\(report.accessibilityGranted)")
        CLIIO.printLine("virtualDisplayConfigured\t\(report.virtualDisplayConfigured)")
        CLIIO.printLine("virtualDisplayAvailable\t\(report.virtualDisplayAvailable)")
        CLIIO.printLine("savedTargetsValid\t\(report.savedTargetsValid)")
    }
}
