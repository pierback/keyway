import AppKit
import SonosHandoffCore

@MainActor
struct DoctorFeature {
    let menuTitle = "Run Doctor"

    func runDoctor(using environment: AppEnvironment) {
        let doctorService = environment.doctorService
        NSLog("SonosHandoff Doctor started")
        Task.detached(priority: .userInitiated) {
            do {
                let report = try await doctorService.run()
                await MainActor.run {
                    NSLog("SonosHandoff Doctor completed")
                    showNotification(
                        title: "Sonos Handoff Doctor",
                        message: """
                    Spotify authenticated: \(reportBool(report.spotifyAuthenticated))
                    Desktop token: \(reportBool(report.spotifyDesktopTokenAvailable))
                    Web API token: \(reportBool(report.spotifyWebAPITokenAvailable))
                    Spotify app installed: \(reportBool(report.spotifyAppInstalled))
                    Spotify app running: \(reportBool(report.spotifyAppRunning))
                    Accessibility granted: \(reportBool(report.accessibilityGranted))
                    Virtual display configured: \(reportBool(report.virtualDisplayConfigured))
                    Virtual display available: \(reportBool(report.virtualDisplayAvailable))
                    Saved targets configured: \(reportBool(report.savedTargetsValid))
                    """
                    )
                }
            } catch {
                await MainActor.run {
                    NSLog("SonosHandoff Doctor failed: \(error.localizedDescription)")
                    showNotification(
                        title: "Sonos Handoff Doctor Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func reportBool(_ value: Bool) -> String {
        value ? "✓" : "✗"
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }
}
