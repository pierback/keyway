import AppKit
import Darwin
import Foundation

struct HostBrowserIdentity {
    let family: String
    let displayName: String
    let bundleIdentifier: String
    let processIdentifier: Int

    static func current() -> HostBrowserIdentity {
        let parentPID = getppid()
        guard let app = NSRunningApplication(processIdentifier: pid_t(parentPID)) else {
            exitWithFailure("could not resolve parent browser process \(parentPID).")
        }
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? ""
        guard let family = browserFamily(bundleIdentifier: bundleIdentifier, displayName: appName) else {
            exitWithFailure("parent is not a supported browser: \(bundleIdentifier) \(appName)")
        }

        return HostBrowserIdentity(
            family: family,
            displayName: appName.isEmpty ? displayName(family: family) : appName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int(app.processIdentifier)
        )
    }

    private static func exitWithFailure(_ message: String) -> Never {
        fputs("Keyway Chromium native host: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }

    private static func browserFamily(bundleIdentifier: String, displayName: String) -> String? {
        let identities = [bundleIdentifier, displayName].map { $0.lowercased() }
        if identities.contains(where: { $0.contains("helium") }) {
            return "helium"
        }
        if identities.contains(where: { $0.contains("thebrowser") || $0.contains("arc") }) {
            return "arc"
        }
        if identities.contains(where: { $0.contains("brave") }) {
            return "brave"
        }
        if identities.contains(where: { $0.contains("edgemac") || $0.contains("microsoft edge") }) {
            return "edge"
        }
        if identities.contains(where: { $0.contains("opera") }) {
            return "opera"
        }
        if identities.contains(where: { $0.contains("vivaldi") }) {
            return "vivaldi"
        }
        if identities.contains(where: { $0.contains("chromium") }) {
            return "chromium"
        }
        if identities.contains(where: { $0.contains("chrome") || $0.contains("google") }) {
            return "chrome"
        }
        return nil
    }

    private static func displayName(family: String) -> String {
        switch family {
        case "arc":
            return "Arc"
        case "brave":
            return "Brave"
        case "edge":
            return "Microsoft Edge"
        case "helium":
            return "Helium"
        case "opera":
            return "Opera"
        case "vivaldi":
            return "Vivaldi"
        case "chrome":
            return "Chrome"
        default:
            return "Chromium"
        }
    }

}
