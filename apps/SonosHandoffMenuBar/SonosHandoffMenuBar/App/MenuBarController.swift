import AppKit
import os
import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarController: View {
    static let settingsWindowID = "settings-window"

    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @StateObject private var volumeMonitor = SonosVolumeMonitor.shared
    private let doctorFeature = DoctorFeature()
    private let shortcutLogger = os.Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Shortcuts")
    private let transferLogger = os.Logger(subsystem: "com.fpieringer.SonosHandoffMenuBar", category: "Transfer")

    @State private var speakers: [SonosSpeaker] = []
    @State private var selectedRoomName: String?
    @State private var loadingRoomName: String?
    @State private var volumeValue = 0.0
    @State private var muted = false
    @State private var outputFixed = false
    @State private var hasVolumeStatus = false
    @State private var sliderEditing = false
    @State private var sliderCommitTask: Task<Void, Never>?
    @State private var sliderCommitSequence = 0
    @State private var volumeBusy = false
    @State private var isRefreshingOutputs = false
    @State private var showMore = false
    @State private var menuMessage: String?

    private static let sliderCommitDelayNanoseconds: UInt64 = 120_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            volumeControl
            divider
            outputSection
            divider
                .padding(.top, 8)
            footer
        }
        .frame(width: 296)
        .padding(.vertical, 0)
        .background(.ultraThickMaterial)
        .onAppear {
            applyMonitoredVolume(volumeMonitor.snapshot, allowRoomSelection: true)
            volumeMonitor.setRoomName(selectedRoomName)
            Task { await refreshOutputs() }
        }
        .onReceive(volumeMonitor.$snapshot) { snapshot in
            applyMonitoredVolume(snapshot, allowRoomSelection: selectedRoomName == nil)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sound")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            if isRefreshingOutputs || loadingRoomName != nil {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.64)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    private var volumeControl: some View {
        HStack(spacing: 5) {
            Button {
                toggleMute()
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 14, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary.opacity(0.9))
            .opacity(canControlVolume ? 1 : 0.45)
            .disabled(!canControlVolume)

            nativeVolumeSlider
            .disabled(!canControlVolume || outputFixed)
            .opacity(canControlVolume && !outputFixed ? 1 : 0.45)

            Button {
                adjustVolume(.up)
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 21, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary.opacity(0.9))
            .opacity(canControlVolume ? 1 : 0.45)
            .disabled(!canControlVolume || outputFixed)
        }
        .frame(height: 18)
        .padding(.horizontal, 9)
        .padding(.bottom, 7)
    }

    private var nativeVolumeSlider: some View {
        GeometryReader { proxy in
            nativeVolumeSliderTrack(width: proxy.size.width)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .accessibilityLabel("Volume")
        .accessibilityIdentifier("sonos-volume-slider")
        .accessibilityValue("\(Int(volumeValue.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjustVolume(.up)
            case .decrement:
                adjustVolume(.down)
            default:
                break
            }
        }
    }

    private func nativeVolumeSliderTrack(width: CGFloat) -> some View {
        let trackWidth = max(width, 1)
        let clampedVolume = min(max(volumeValue, 0), 100)
        let progress = CGFloat(clampedVolume / 100)
        let knobSize: CGFloat = 17
        let knobOffset = min(max((trackWidth * progress) - (knobSize / 2), 0), max(trackWidth - knobSize, 0))

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(height: 4)

            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: max(trackWidth * progress, knobSize / 2), height: 4)

            Circle()
                .fill(Color.white.opacity(0.96))
                .frame(width: knobSize, height: knobSize)
                .offset(x: knobOffset)
                .shadow(color: .black.opacity(0.22), radius: 0.75, y: 0.5)
        }
        .frame(height: 18)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard canControlVolume, !outputFixed else {
                        return
                    }
                    sliderEditing = true
                    volumeValue = volume(forSliderLocation: value.location.x, width: trackWidth)
                    queueSliderVolumeCommit(delayNanoseconds: Self.sliderCommitDelayNanoseconds)
                }
                .onEnded { value in
                    guard canControlVolume, !outputFixed else {
                        return
                    }
                    volumeValue = volume(forSliderLocation: value.location.x, width: trackWidth)
                    queueSliderVolumeCommit(delayNanoseconds: 0)
                    sliderEditing = false
                }
        )
    }

    private func volume(forSliderLocation locationX: CGFloat, width: CGFloat) -> Double {
        let boundedX = min(max(locationX, 0), max(width, 1))
        return Double((boundedX / max(width, 1)) * 100)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Output")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if speakers.isEmpty {
                emptyOutputRow
            } else {
                ForEach(speakers) { speaker in
                    outputRow(for: speaker)
                }
            }

            if let menuMessage {
                Text(menuMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
            }
        }
    }

    private var emptyOutputRow: some View {
        HStack(spacing: 9) {
            if isRefreshingOutputs {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.56)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "hifispeaker")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }

            Text(isRefreshingOutputs ? "Searching..." : "No Sonos speakers found")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow(title: "Show More", systemImage: showMore ? "chevron.down" : "chevron.right", emphasized: true) {
                withAnimation(.easeInOut(duration: 0.14)) {
                    showMore.toggle()
                }
            }

            if showMore {
                footerRow(title: "Check Shortcut Status", systemImage: "keyboard") {
                    checkShortcutStatus()
                }

                footerRow(title: doctorFeature.menuTitle, systemImage: "stethoscope") {
                    doctorFeature.runDoctor(using: environment)
                }

                if !AccessibilityPermission.isGranted() {
                    footerRow(title: "Enable fn Volume Shortcuts...", systemImage: "accessibility") {
                        openShortcutPermissions()
                    }
                }

                footerRow(title: "Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }

            divider
            footerRow(title: "Sound Settings...", systemImage: nil, emphasized: true) {
                openSettingsWindow()
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator.opacity(0.7))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private var canControlVolume: Bool {
        selectedRoomName != nil && !volumeBusy && loadingRoomName == nil
    }

    private func outputRow(for speaker: SonosSpeaker) -> some View {
        let selected = speaker.roomName == selectedRoomName
        let loading = speaker.roomName == loadingRoomName

        return Button {
            transfer(to: speaker)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(outputIconBackground(selected: selected))

                    Image(systemName: outputIconName(for: speaker))
                        .font(.system(size: 12, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(outputIconForeground(selected: selected))
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(speaker.roomName)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if loading {
                        Text("Transferring...")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.56)
                        .frame(width: 18, height: 18)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.045 : 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(loadingRoomName != nil || volumeBusy)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer-to-\(speaker.roomName)")
        .accessibilityLabel("Transfer to \(speaker.roomName)")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityHint("Hands off Spotify playback to \(speaker.roomName)")
    }

    private func outputIconName(for speaker: SonosSpeaker) -> String {
        switch speaker.roomName.lowercased() {
        case "port":
            return "hifispeaker"
        default:
            return "hifispeaker"
        }
    }

    private func outputIconBackground(selected: Bool) -> Color {
        selected ? Color.white.opacity(0.115) : Color.white.opacity(0.075)
    }

    private func outputIconForeground(selected: Bool) -> Color {
        selected ? Color.white.opacity(0.95) : Color.secondary.opacity(0.85)
    }

    private func footerRow(
        title: String,
        systemImage: String?,
        emphasized: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                    .foregroundStyle(emphasized ? Color.primary : Color.secondary.opacity(0.92))
                Spacer()
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.secondary.opacity(0.74))
                        .frame(width: 16, height: 16)
                }
            }
            .frame(height: emphasized ? 29 : 27)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSettingsWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: Self.settingsWindowID)
        }
    }

    private func refreshOutputs() async {
        guard !isRefreshingOutputs else {
            return
        }
        isRefreshingOutputs = true
        defer { isRefreshingOutputs = false }
        menuMessage = nil
        do {
            let discovered = try await environment.speakerDiscovery.discoverSpeakers()
            speakers = discovered

            if let selectedRoomName,
               discovered.contains(where: { $0.roomName == selectedRoomName }) {
                refreshVolumeStatus(roomName: selectedRoomName)
                volumeMonitor.setRoomName(selectedRoomName)
            } else {
                selectedRoomName = preferredInitialRoomName(in: discovered)
                volumeMonitor.setRoomName(selectedRoomName)
                if let selectedRoomName {
                    refreshVolumeStatus(roomName: selectedRoomName)
                } else {
                    hasVolumeStatus = false
                    menuMessage = "No Sonos speakers found on this network."
                }
            }
        } catch {
            speakers = []
            selectedRoomName = nil
            volumeMonitor.setRoomName(nil)
            hasVolumeStatus = false
            menuMessage = "Could not search for Sonos speakers."
            shortcutLogger.error("SonosHandoffDiscovery result=failure error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshVolumeStatus(roomName: String? = nil) {
        guard let roomName = roomName ?? selectedRoomName else {
            return
        }

        let volumeService = environment.volumeService
        volumeBusy = true
        Task.detached(priority: .userInitiated) {
            do {
                let status = try await volumeService.volumeStatus(roomName: roomName)
                await MainActor.run {
                    guard selectedRoomName == roomName else {
                        return
                    }
                    volumeValue = Double(status.volume)
                    muted = status.muted
                    outputFixed = status.outputFixed
                    hasVolumeStatus = true
                    volumeBusy = false
                    shortcutLogger.info("SonosHandoffVolumeStatus room=\(status.roomName, privacy: .public) host=\(status.host, privacy: .public) volume=\(status.volume, privacy: .public) muted=\(status.muted, privacy: .public) outputFixed=\(status.outputFixed, privacy: .public)")
                }
            } catch {
                await MainActor.run {
                    guard selectedRoomName == roomName else {
                        return
                    }
                    hasVolumeStatus = false
                    volumeBusy = false
                    menuMessage = "Could not read \(roomName) volume."
                    shortcutLogger.error("SonosHandoffVolumeStatus result=failure room=\(roomName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func applyMonitoredVolume(_ snapshot: VolumeMonitorSnapshot?, allowRoomSelection: Bool = false) {
        guard let snapshot, !volumeBusy, !sliderEditing else {
            return
        }
        if selectedRoomName == nil, allowRoomSelection {
            selectedRoomName = snapshot.roomName
            volumeMonitor.setRoomName(snapshot.roomName)
        }
        guard let selectedRoomName,
              selectedRoomName.caseInsensitiveCompare(snapshot.roomName) == .orderedSame
        else {
            return
        }

        volumeValue = Double(snapshot.volume)
        muted = snapshot.muted
        outputFixed = snapshot.outputFixed
        hasVolumeStatus = true
    }

    private func queueSliderVolumeCommit(delayNanoseconds: UInt64) {
        guard hasVolumeStatus, let roomName = selectedRoomName else {
            refreshVolumeStatus()
            return
        }

        let desiredVolume = Int(volumeValue.rounded())
        sliderCommitSequence += 1
        let sequence = sliderCommitSequence
        sliderCommitTask?.cancel()
        volumeMonitor.noteLocalChange(roomName: roomName, volume: desiredVolume, muted: false)
        sliderCommitTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else {
                return
            }

            commitSliderVolume(roomName: roomName, desiredVolume: desiredVolume, sequence: sequence)
        }
    }

    private func commitSliderVolume(roomName: String, desiredVolume: Int, sequence: Int) {
        let volumeService = environment.volumeService
        Task.detached(priority: .userInitiated) {
            do {
                let volume = try await volumeService.setVolume(roomName: roomName, volume: desiredVolume)
                await MainActor.run {
                    guard selectedRoomName == roomName, sliderCommitSequence == sequence else {
                        return
                    }
                    volumeValue = Double(volume)
                    muted = false
                    hasVolumeStatus = true
                    menuMessage = nil
                    volumeMonitor.noteLocalChange(roomName: roomName, volume: volume, muted: false)
                    shortcutLogger.info("SonosHandoffVolumeSet result=success source=slider room=\(roomName, privacy: .public) volume=\(volume, privacy: .public)")
                }
            } catch {
                await MainActor.run {
                    guard selectedRoomName == roomName, sliderCommitSequence == sequence else {
                        return
                    }
                    menuMessage = "Could not set \(roomName) volume."
                    shortcutLogger.error("SonosHandoffVolumeSet result=failure source=slider room=\(roomName, privacy: .public) volume=\(desiredVolume, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    refreshVolumeStatus(roomName: roomName)
                }
            }
        }
    }

    private func adjustVolume(_ direction: VolumeMenuDirection) {
        guard let roomName = selectedRoomName else {
            return
        }

        let volumeService = environment.volumeService
        volumeBusy = true
        menuMessage = nil
        volumeMonitor.noteLocalChange(roomName: roomName)
        Task.detached(priority: .userInitiated) {
            do {
                let volume: Int
                switch direction {
                case .down:
                    volume = try await volumeService.volumeDown(roomName: roomName, step: VolumeControlDefaults.step)
                case .up:
                    volume = try await volumeService.volumeUp(roomName: roomName, step: VolumeControlDefaults.step)
                }
                await MainActor.run {
                    guard selectedRoomName == roomName else {
                        return
                    }
                    volumeValue = Double(volume)
                    muted = false
                    hasVolumeStatus = true
                    volumeBusy = false
                    volumeMonitor.noteLocalChange(roomName: roomName, volume: volume, muted: false)
                }
            } catch {
                await MainActor.run {
                    guard selectedRoomName == roomName else {
                        return
                    }
                    volumeBusy = false
                    menuMessage = "Could not change \(roomName) volume."
                    refreshVolumeStatus(roomName: roomName)
                }
            }
        }
    }

    private func toggleMute() {
        guard let roomName = selectedRoomName else {
            return
        }

        let volumeService = environment.volumeService
        volumeBusy = true
        menuMessage = nil
        volumeMonitor.noteLocalChange(roomName: roomName)
        Task.detached(priority: .userInitiated) {
            do {
                let muted = try await volumeService.toggleMute(roomName: roomName)
                await MainActor.run {
                    guard selectedRoomName == roomName else {
                        return
                    }
                    self.muted = muted
                    volumeBusy = false
                    volumeMonitor.noteLocalChange(roomName: roomName, muted: muted)
                }
            } catch {
                await MainActor.run {
                    guard selectedRoomName == roomName else {
                        return
                    }
                    volumeBusy = false
                    menuMessage = "Could not toggle \(roomName) mute."
                }
            }
        }
    }

    private func transfer(to speaker: SonosSpeaker) {
        let roomName = speaker.roomName
        let handoffService = environment.roomHandoffService
        loadingRoomName = roomName
        menuMessage = nil
        transferLogger.info("SonosHandoffTransfer state=started room=\(roomName, privacy: .public) host=\(speaker.host, privacy: .public)")
        Task.detached(priority: .userInitiated) {
            let result = await handoffService.transfer(toRoomName: roomName)
            await MainActor.run {
                loadingRoomName = nil
                switch result {
                case .success:
                    selectedRoomName = roomName
                    volumeMonitor.setRoomName(roomName)
                    menuMessage = nil
                    transferLogger.info("SonosHandoffTransfer state=succeeded room=\(roomName, privacy: .public)")
                    refreshVolumeStatus(roomName: roomName)
                case .failure(let code, let details):
                    menuMessage = "Could not transfer to \(roomName)."
                    transferLogger.error("SonosHandoffTransfer state=failed room=\(roomName, privacy: .public) code=\(code.rawValue, privacy: .public) details=\(details, privacy: .public)")
                }
            }
        }
    }

    private func checkShortcutStatus() {
        NotificationCenter.default.post(name: .sonosHandoffRefreshHotkeys, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let status = ShortcutRuntimeStatus.shared.snapshot()
            shortcutLogger.info("SonosHandoffShortcuts accessibility=\(status.accessibilityGranted, privacy: .public) mediaFallback=\(status.mediaFallback.rawValue, privacy: .public) plainHotkeys=\(status.plainHotkeysRegistered, privacy: .public) fnHotkeys=\(status.fnHotkeysRegistered, privacy: .public) failure=\(status.lastFailureReason ?? "none", privacy: .public) step=\(status.step, privacy: .public) appPath=\(status.appPath, privacy: .public)")
            StatusHUD.shared.finish(title: status.title, message: status.message, dismissAfter: status.mediaFallback == .enabled ? 4.0 : 7.0)
            showNotification(title: status.title, message: status.message)
        }
    }

    private func openShortcutPermissions() {
        AccessibilityPermission.requestPrompt()
        NotificationCenter.default.post(name: .sonosHandoffRefreshHotkeys, object: nil)
        shortcutLogger.info("SonosHandoffShortcuts action=open_accessibility_settings appPath=\(Bundle.main.bundlePath, privacy: .public)")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        StatusHUD.shared.finish(
            title: "Enable Shortcuts",
            message: "Add and enable Sonos Handoff in Accessibility",
            dismissAfter: 7.0
        )
    }

    private func preferredInitialRoomName(in speakers: [SonosSpeaker]) -> String? {
        let preferred = preferredRoomName()
        return speakers.first(where: { $0.roomName.caseInsensitiveCompare(preferred) == .orderedSame })?.roomName
            ?? speakers.first?.roomName
    }

    private func preferredRoomName() -> String {
        preferredTarget()?.spotifyDeviceName ?? "Port"
    }

    private func preferredTarget() -> SavedTarget? {
        guard let config = try? environment.configStore.load() else {
            return nil
        }

        return config.targets.first(where: { $0.alias.caseInsensitiveCompare("port") == .orderedSame })
            ?? config.targets.first
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }
}

private enum VolumeMenuDirection {
    case down
    case up
}
