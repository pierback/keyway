@preconcurrency import AppKit

@MainActor
final class StatusHUDPanel {
    let panel: NSPanel

    private let containerView: HUDContainerView
    private let backgroundView: HUDBackgroundView
    private let spinner: NSProgressIndicator
    private let titleField: NSTextField
    private let messageField: NSTextField
    private let statusDot: NSView
    private let trackView: NSView
    private let fillView: NSView
    private let knobView: NSView
    private let leftIconView: NSImageView
    private let rightIconView: NSImageView
    private let dividerView: NSView
    private let outputLabelField: NSTextField
    private let outputBadgeView: NSView
    private let outputNameField: NSTextField

    private let messagePanelSize = NSSize(width: 306, height: 176)
    private let volumePanelSize = NSSize(width: 296, height: 64)
    private let edgeInset: CGFloat = 18
    private let messageTrackFrame = NSRect(x: 56, y: 111, width: 198, height: 5)
    private let compactTrackFrame = NSRect(x: 28, y: 22, width: 233, height: 4)
    private let knobSize: CGFloat = 17
    private var activeTrackFrame = NSRect(x: 56, y: 111, width: 198, height: 5)

    init(onClick: @escaping @MainActor () -> Void) {
        let bodyFrame = NSRect(origin: .zero, size: messagePanelSize)
        let panel = NSPanel(
            contentRect: bodyFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false

        let containerView = HUDContainerView(frame: bodyFrame)
        containerView.onClick = onClick
        containerView.wantsLayer = true

        let backgroundView = HUDBackgroundView(frame: bodyFrame)
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 22
        backgroundView.layer?.masksToBounds = true

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 128, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        let statusDot = NSView(frame: NSRect(x: 23, y: 132, width: 10, height: 10))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.isHidden = true

        let titleField = NSTextField(labelWithString: "")
        titleField.frame = NSRect(x: edgeInset, y: 132, width: 270, height: 24)
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail

        let messageField = NSTextField(labelWithString: "")
        messageField.frame = NSRect(x: 46, y: 111, width: 240, height: 15)
        messageField.font = .systemFont(ofSize: 11, weight: .medium)
        messageField.textColor = NSColor.white.withAlphaComponent(0.78)
        messageField.lineBreakMode = .byTruncatingTail

        let leftIconView = NSImageView(frame: NSRect(x: 21, y: 101, width: 23, height: 23))
        leftIconView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        leftIconView.imageScaling = .scaleProportionallyDown
        leftIconView.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        leftIconView.isHidden = true

        let rightIconView = NSImageView(frame: NSRect(x: 267, y: 98, width: 25, height: 25))
        rightIconView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        rightIconView.imageScaling = .scaleProportionallyDown
        rightIconView.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        rightIconView.isHidden = true

        let trackView = NSView(frame: messageTrackFrame)
        trackView.wantsLayer = true
        trackView.layer?.cornerRadius = messageTrackFrame.height / 2
        trackView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        trackView.isHidden = true

        let fillView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: messageTrackFrame.height))
        fillView.wantsLayer = true
        fillView.layer?.cornerRadius = messageTrackFrame.height / 2
        fillView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        trackView.addSubview(fillView)

        let knobView = NSView(frame: NSRect(
            x: messageTrackFrame.minX - knobSize / 2,
            y: messageTrackFrame.midY - knobSize / 2,
            width: knobSize,
            height: knobSize
        ))
        knobView.wantsLayer = true
        knobView.layer?.cornerRadius = knobSize / 2
        knobView.layer?.backgroundColor = NSColor.white.cgColor
        knobView.layer?.shadowColor = NSColor.black.cgColor
        knobView.layer?.shadowOpacity = 0.22
        knobView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        knobView.layer?.shadowRadius = 2
        knobView.isHidden = true

        let dividerView = NSView(frame: NSRect(x: edgeInset, y: 84, width: messagePanelSize.width - (edgeInset * 2), height: 1))
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        dividerView.isHidden = true

        let outputLabelField = NSTextField(labelWithString: "Output")
        outputLabelField.frame = NSRect(x: edgeInset, y: 58, width: 120, height: 20)
        outputLabelField.font = .systemFont(ofSize: 14, weight: .semibold)
        outputLabelField.textColor = NSColor.white.withAlphaComponent(0.58)
        outputLabelField.lineBreakMode = .byTruncatingTail
        outputLabelField.isHidden = true

        let outputBadgeView = NSView(frame: NSRect(x: edgeInset, y: 20, width: 34, height: 34))
        outputBadgeView.wantsLayer = true
        outputBadgeView.layer?.cornerRadius = 17
        outputBadgeView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        outputBadgeView.isHidden = true

        let outputIconView = NSImageView(frame: NSRect(x: 7, y: 7, width: 20, height: 20))
        outputIconView.contentTintColor = .white
        outputIconView.imageScaling = .scaleProportionallyDown
        outputIconView.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "Sonos")
        outputBadgeView.addSubview(outputIconView)

        let outputNameField = NSTextField(labelWithString: "Port")
        outputNameField.frame = NSRect(x: 64, y: 26, width: 210, height: 23)
        outputNameField.font = .systemFont(ofSize: 16, weight: .semibold)
        outputNameField.textColor = .white
        outputNameField.lineBreakMode = .byTruncatingTail
        outputNameField.isHidden = true

        containerView.addSubview(backgroundView)
        backgroundView.addSubview(spinner)
        backgroundView.addSubview(statusDot)
        backgroundView.addSubview(titleField)
        backgroundView.addSubview(messageField)
        backgroundView.addSubview(leftIconView)
        backgroundView.addSubview(trackView)
        backgroundView.addSubview(knobView)
        backgroundView.addSubview(rightIconView)
        backgroundView.addSubview(dividerView)
        backgroundView.addSubview(outputLabelField)
        backgroundView.addSubview(outputBadgeView)
        backgroundView.addSubview(outputNameField)
        panel.contentView = containerView

        self.panel = panel
        self.containerView = containerView
        self.backgroundView = backgroundView
        self.spinner = spinner
        self.titleField = titleField
        self.messageField = messageField
        self.statusDot = statusDot
        self.trackView = trackView
        self.fillView = fillView
        self.knobView = knobView
        self.leftIconView = leftIconView
        self.rightIconView = rightIconView
        self.dividerView = dividerView
        self.outputLabelField = outputLabelField
        self.outputBadgeView = outputBadgeView
        self.outputNameField = outputNameField
    }

    func showLoadingMessage(title: String, message: String) {
        configureMessageLayout()
        spinner.startAnimation(nil)
        spinner.isHidden = false
        statusDot.isHidden = true
        titleField.stringValue = title
        messageField.stringValue = message
    }

    func updateMessage(title: String?, message: String) {
        if let title {
            titleField.stringValue = title
        }
        messageField.stringValue = message
    }

    func showFinishedMessage(title: String, message: String) {
        configureMessageLayout()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusDot.isHidden = false
        titleField.stringValue = title
        messageField.stringValue = message
    }

    func showVolumePending(roomName: String) {
        configureVolumeLayout()
        resetVolumeStatus(roomName: roomName)
        leftIconView.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        rightIconView.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        setVolumeFill(0)
    }

    func showVolume(roomName: String, volume: Int) {
        configureVolumeLayout()
        resetVolumeStatus(roomName: roomName)
        setVolumeFill(max(0, min(100, volume)))
    }

    func showMutePending(roomName: String) {
        configureVolumeLayout()
        resetVolumeStatus(roomName: roomName)
        leftIconView.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        rightIconView.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Mute")
        setVolumeFill(0)
    }

    func showMute(roomName: String, muted: Bool) {
        configureVolumeLayout()
        resetVolumeStatus(roomName: roomName)
        leftIconView.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        rightIconView.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Volume")
        setVolumeFill(muted ? 0 : 100)
    }

    func orderFront() {
        position()
        panel.orderFrontRegardless()
    }

    func orderOut() {
        panel.orderOut(nil)
    }

    func position() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            return
        }

        let anchorCenterX = StatusHUDAnchor.statusItemFrame()?.midX ?? StatusHUDAnchor.fallbackStatusAreaCenterX(in: visibleFrame)
        let x = max(
            visibleFrame.minX + 8,
            min(anchorCenterX - (panel.frame.width / 2), visibleFrame.maxX - panel.frame.width - 8)
        )
        let y = visibleFrame.maxY - panel.frame.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func configureMessageLayout() {
        resize(to: messagePanelSize)
        activeTrackFrame = messageTrackFrame
        backgroundView.layer?.cornerRadius = 22
        titleField.alignment = .left
        titleField.frame = NSRect(x: 46, y: 132, width: 240, height: 22)
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        messageField.frame = NSRect(x: 46, y: 111, width: 240, height: 15)
        messageField.isHidden = false
        leftIconView.isHidden = true
        rightIconView.isHidden = true
        trackView.isHidden = true
        knobView.isHidden = true
        dividerView.isHidden = true
        outputLabelField.isHidden = true
        outputBadgeView.isHidden = true
        outputNameField.isHidden = true
    }

    private func configureVolumeLayout() {
        resize(to: volumePanelSize)
        activeTrackFrame = compactTrackFrame
        backgroundView.layer?.cornerRadius = 18
        titleField.alignment = .left
        titleField.frame = NSRect(x: 9, y: 41, width: volumePanelSize.width - 18, height: 16)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        messageField.frame = NSRect(x: 28, y: 8, width: 233, height: 14)
        messageField.isHidden = true
        leftIconView.isHidden = false
        leftIconView.frame = NSRect(x: 9, y: 15, width: 14, height: 18)
        rightIconView.isHidden = false
        rightIconView.frame = NSRect(x: 266, y: 15, width: 21, height: 18)
        trackView.isHidden = false
        trackView.frame = compactTrackFrame
        trackView.layer?.cornerRadius = compactTrackFrame.height / 2
        fillView.layer?.cornerRadius = compactTrackFrame.height / 2
        fillView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        knobView.isHidden = false
        dividerView.isHidden = true
        outputLabelField.isHidden = true
        outputBadgeView.isHidden = true
        outputNameField.isHidden = true
    }

    private func resetVolumeStatus(roomName: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusDot.isHidden = true
        titleField.stringValue = "Sound"
        messageField.stringValue = ""
        messageField.isHidden = true
        outputNameField.stringValue = roomName
        leftIconView.isHidden = false
        rightIconView.isHidden = false
        leftIconView.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Volume")
        rightIconView.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
    }

    private func setVolumeFill(_ volume: Int) {
        let percent = CGFloat(volume) / 100
        let fillWidth = max(0, min(activeTrackFrame.width, activeTrackFrame.width * percent))
        fillView.frame = NSRect(x: 0, y: 0, width: fillWidth, height: activeTrackFrame.height)
        let knobX = min(
            max(activeTrackFrame.minX + fillWidth - (knobSize / 2), activeTrackFrame.minX),
            activeTrackFrame.maxX - knobSize
        )
        knobView.frame = NSRect(
            x: knobX,
            y: activeTrackFrame.midY - (knobSize / 2),
            width: knobSize,
            height: knobSize
        )
    }

    private func resize(to size: NSSize) {
        panel.setContentSize(size)
        containerView.frame = NSRect(origin: .zero, size: size)
        backgroundView.frame = NSRect(origin: .zero, size: size)
    }
}
