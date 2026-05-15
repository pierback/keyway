import AppKit
import os
import SonosHandoffCore
import SwiftUI

@MainActor
struct TransferMenuFeature {
    let menuTitle = "Transfer to..."
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Transfer")

    @ViewBuilder
    func menuItems(
        using environment: AppEnvironment,
        openSettings: @escaping @MainActor () -> Void
    ) -> some View {
        switch loadTargetMenuState(from: environment.configStore) {
        case .loaded(let targets):
            if targets.isEmpty {
                Button("Add Target...") {
                    openSettings()
                }
            } else {
                Text("Transfer to")
                ForEach(targets, id: \.alias) { target in
                    Button("\(target.alias) -> \(target.spotifyDeviceName)") {
                        transfer(
                            target: target,
                            using: environment
                        )
                    }
                }
            }
        case .failed:
            Button("Could Not Load Targets") {}
                .disabled(true)
        }
    }

    private func loadTargetMenuState(from configStore: ConfigStoring) -> TargetMenuState {
        do {
            return .loaded(sortedTargets(try configStore.load().targets))
        } catch {
            return .failed
        }
    }

    private func sortedTargets(_ targets: [SavedTarget]) -> [SavedTarget] {
        targets.sorted {
            $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }

    private func transfer(
        target: SavedTarget,
        using environment: AppEnvironment
    ) {
        let handoffService = environment.handoffService
        logger.info("SonosHandoffTransfer state=started alias=\(target.alias, privacy: .public) device=\(target.spotifyDeviceName, privacy: .public)")
        StatusHUD.shared.show(
            title: "Transfer to \(target.spotifyDeviceName)",
            message: "Connecting Spotify to Sonos..."
        )
        Task.detached(priority: .userInitiated) {
            let result = await handoffService.transfer(to: target.alias)
            await MainActor.run {
                switch result {
                case .success:
                    logger.info("SonosHandoffTransfer state=succeeded alias=\(target.alias, privacy: .public) device=\(target.spotifyDeviceName, privacy: .public)")
                    StatusHUD.shared.finish(
                        title: "Transfer to \(target.spotifyDeviceName)",
                        message: "Playback is on \(target.spotifyDeviceName)."
                    )
                    showNotification(
                        title: "Transfer to \(target.spotifyDeviceName)",
                        message: "Transfer succeeded via Spotify Connect."
                    )
                case .failure(let code, let details):
                    logger.error("SonosHandoffTransfer state=failed alias=\(target.alias, privacy: .public) device=\(target.spotifyDeviceName, privacy: .public) code=\(code.rawValue, privacy: .public) details=\(details, privacy: .public)")
                    StatusHUD.shared.finish(
                        title: "Transfer Failed",
                        message: details
                    )
                    switch code {
                    case .authRequired:
                        showNotification(
                            title: "Spotify Authentication Required",
                            message: details
                        )
                    default:
                        showNotification(
                            title: "Transfer to \(target.spotifyDeviceName)",
                            message: details
                        )
                    }
                }
            }
        }
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }
}

private enum TargetMenuState {
    case loaded([SavedTarget])
    case failed
}
