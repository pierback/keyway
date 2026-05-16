import AppKit
import os

import SonosHandoffCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Hotkeys")
    private var volumeHotkeys: VolumeHotkeyController?

    func configure(environment: AppEnvironment) {
        volumeHotkeys = VolumeHotkeyController(
            volumeService: environment.volumeService,
            outputSelection: environment.outputSelection,
            configStore: environment.configStore
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: .sonosHandoffRefreshHotkeys,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.volumeHotkeys?.refreshMediaFallback(promptIfMissing: false)
            }
        }
        guard let volumeHotkeys else {
            logger.error("SonosHandoffHotkeys state=not_started reason=missing_app_environment")
            return
        }

        volumeHotkeys.start()
    }
}
