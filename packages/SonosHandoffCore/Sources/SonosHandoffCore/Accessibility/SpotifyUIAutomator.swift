import AppKit
import ApplicationServices
import Foundation
import Vision

public protocol AccessibilityAutomating {
    func transferPlayback(toVisibleDeviceNamed name: String, preferredDisplayNamed displayName: String?) async throws
    func checkAccessibilityPermission() -> Bool
}

public struct SpotifyUIAutomator: AccessibilityAutomating {
    private let appLocator: SpotifyAppLocator
    private let timeoutNanoseconds: UInt64
    private let pollIntervalNanoseconds: UInt64
    private let transferWindowSize = CGSize(width: 1440, height: 900)

    public init(
        appLocator: SpotifyAppLocator = SpotifyAppLocator(),
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        pollIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.appLocator = appLocator
        self.timeoutNanoseconds = timeoutNanoseconds
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    public func transferPlayback(toVisibleDeviceNamed name: String, preferredDisplayNamed displayName: String?) async throws {
        guard appLocator.installedAppURL() != nil else {
            throw TransferErrorCode.spotifyAppNotInstalled
        }

        guard let spotify = appLocator.runningApplication() else {
            throw TransferErrorCode.spotifyAppNotRunning
        }

        guard checkAccessibilityPermission() else {
            throw TransferErrorCode.accessibilityNotGranted
        }

        let previousApplication = NSWorkspace.shared.frontmostApplication
        spotify.activate()
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)

        let applicationElement = AXUIElementCreateApplication(spotify.processIdentifier)
        let windowSnapshot = capturePrimaryWindowState(in: applicationElement)
        if shouldRepositionWindow(for: displayName) {
            try await movePrimaryWindow(
                in: applicationElement,
                spotifyProcessIdentifier: spotify.processIdentifier,
                toDisplayNamed: displayName
            )
        }
        defer {
            restoreWindow(windowSnapshot)
            restore(previousApplication, unless: spotify)
        }

        if try await selectVisibleTarget(named: name, in: applicationElement, spotifyProcessIdentifier: spotify.processIdentifier) {
            return
        }

        try await ensureConnectPanelOpen(
            in: applicationElement,
            spotifyProcessIdentifier: spotify.processIdentifier
        )
        if shouldRepositionWindow(for: displayName) {
            try await movePrimaryWindow(
                in: applicationElement,
                spotifyProcessIdentifier: spotify.processIdentifier,
                toDisplayNamed: displayName
            )
        }

        if try await selectVisibleTarget(
            named: name,
            in: applicationElement,
            spotifyProcessIdentifier: spotify.processIdentifier,
            timeoutNanoseconds: 3_000_000_000
        ) {
            return
        }

        throw TransferErrorCode.targetNotVisible
    }

    public func checkAccessibilityPermission() -> Bool {
        AccessibilityPermission.isGranted()
    }

    private func shouldRepositionWindow(for displayName: String?) -> Bool {
        guard let displayName else {
            return false
        }

        return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func restore(_ application: NSRunningApplication?, unless spotify: NSRunningApplication) {
        guard let application, application.processIdentifier != spotify.processIdentifier else {
            return
        }

        application.activate(options: [.activateIgnoringOtherApps])
    }

    private func movePrimaryWindow(
        in applicationElement: AXUIElement,
        spotifyProcessIdentifier: pid_t,
        toDisplayNamed displayName: String?
    ) async throws {
        guard
            let screen = preferredScreen(named: displayName),
            let window = primaryWindow(in: applicationElement)
        else {
            return
        }

        let targetFrame = screen.frame
        let targetSize = targetWindowSize(within: targetFrame)
        let targetOrigin = CGPoint(
            x: targetFrame.minX + 40,
            y: targetFrame.minY + 40
        )

        for _ in 0 ..< 3 {
            set(size: targetSize, on: window)
            set(position: targetOrigin, on: window)
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)

            if isWindowVisible(on: screen, spotifyProcessIdentifier: spotifyProcessIdentifier) {
                return
            }
        }
    }

    private func preferredScreen(named displayName: String?) -> NSScreen? {
        guard let displayName, !displayName.isEmpty else {
            return nil
        }

        let normalizedTarget = Self.normalize(displayName)
        if let exactMatch = NSScreen.screens.first(where: { Self.normalize($0.localizedName) == normalizedTarget }) {
            return exactMatch
        }

        return NSScreen.screens.first(where: { Self.normalize($0.localizedName).contains(normalizedTarget) })
    }

    private func capturePrimaryWindowState(in applicationElement: AXUIElement) -> WindowSnapshot? {
        guard let window = primaryWindow(in: applicationElement) else {
            return nil
        }

        return WindowSnapshot(
            window: window,
            position: pointAttribute(kAXPositionAttribute, from: window),
            size: sizeAttribute(kAXSizeAttribute, from: window)
        )
    }

    private func restoreWindow(_ snapshot: WindowSnapshot?) {
        guard let snapshot else {
            return
        }

        if let size = snapshot.size {
            set(size: size, on: snapshot.window)
        }

        if let position = snapshot.position {
            set(position: position, on: snapshot.window)
        }
    }

    private func primaryWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedWindowAttribute, from: applicationElement)
            ?? elementAttribute(kAXMainWindowAttribute, from: applicationElement)
            ?? childrenAttribute(kAXWindowsAttribute, from: applicationElement).first
    }

    private func targetWindowSize(within visibleFrame: CGRect) -> CGSize {
        let width = min(max(transferWindowSize.width, 1100), max(visibleFrame.width - 80, 900))
        let height = min(max(transferWindowSize.height, 780), max(visibleFrame.height - 80, 700))
        return CGSize(width: width, height: height)
    }

    private func isWindowVisible(on screen: NSScreen, spotifyProcessIdentifier: pid_t) -> Bool {
        guard let windowMatch = spotifyWindowMatch(for: spotifyProcessIdentifier) else {
            return false
        }

        return screen.frame.contains(CGPoint(x: windowMatch.bounds.midX, y: windowMatch.bounds.midY))
    }

    private func set(position: CGPoint, on element: AXUIElement) {
        var value = position
        guard let axValue = AXValueCreate(.cgPoint, &value) else {
            return
        }

        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }

    private func set(size: CGSize, on element: AXUIElement) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else {
            return
        }

        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    private func waitForConnectButton(
        in applicationElement: AXUIElement,
        timeoutNanoseconds overrideTimeoutNanoseconds: UInt64? = nil
    ) async throws -> AXUIElement? {
        try await waitForElement(in: applicationElement, timeoutNanoseconds: overrideTimeoutNanoseconds) { element in
            let role = self.stringAttribute(kAXRoleAttribute, from: element)
            guard role == kAXButtonRole as String || role == kAXGroupRole as String else {
                return false
            }

            let text = self.elementText(for: element)
            return Self.connectButtonLabels.contains { label in
                text.localizedCaseInsensitiveContains(label)
            }
        }
    }

    private func waitForTargetElement(
        named name: String,
        in applicationElement: AXUIElement,
        timeoutNanoseconds overrideTimeoutNanoseconds: UInt64? = nil
    ) async throws -> AXUIElement? {
        try await waitForElement(in: applicationElement, timeoutNanoseconds: overrideTimeoutNanoseconds) { element in
            let text = self.elementText(for: element)
            guard Self.matchesTargetName(name, in: text) else {
                return false
            }
            return true
        }
    }

    private func selectVisibleTarget(
        named name: String,
        in applicationElement: AXUIElement,
        spotifyProcessIdentifier: pid_t,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let targetElement = try await waitForTargetElement(
                named: name,
                in: applicationElement,
                timeoutNanoseconds: pollIntervalNanoseconds
            ) {
                try pressTargetElement(targetElement)
                return true
            }

            if try clickTargetFromWindowText(named: name, spotifyProcessIdentifier: spotifyProcessIdentifier) {
                return true
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return false
    }

    private func waitForElement(
        in applicationElement: AXUIElement,
        timeoutNanoseconds overrideTimeoutNanoseconds: UInt64? = nil,
        predicate: (AXUIElement) -> Bool
    ) async throws -> AXUIElement? {
        let deadline = DispatchTime.now().uptimeNanoseconds + (overrideTimeoutNanoseconds ?? timeoutNanoseconds)

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let match = findElement(in: applicationElement, predicate: predicate) {
                return match
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return nil
    }

    private func ensureConnectPanelOpen(
        in applicationElement: AXUIElement,
        spotifyProcessIdentifier: pid_t
    ) async throws {
        if try await isConnectPanelVisible(in: applicationElement) {
            return
        }

        if let connectButton = try await waitForConnectButton(
            in: applicationElement,
            timeoutNanoseconds: 1_500_000_000
        ) {
            try triggerElement(connectButton)
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            if try await isConnectPanelVisible(in: applicationElement) {
                return
            }
        }

        if try clickConnectButtonFromWindowText(spotifyProcessIdentifier: spotifyProcessIdentifier) {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            if try await isConnectPanelVisible(in: applicationElement) {
                return
            }
        }

        for clickPoint in connectButtonFallbackPoints(spotifyProcessIdentifier: spotifyProcessIdentifier) {
            try click(at: clickPoint)
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)

            if try await isConnectPanelVisible(in: applicationElement) {
                return
            }
        }

        throw TransferErrorCode.targetNotVisible
    }

    private func isConnectPanelVisible(in applicationElement: AXUIElement) async throws -> Bool {
        if try await waitForElement(
            in: applicationElement,
            timeoutNanoseconds: 1_000_000_000,
            predicate: { element in
            let text = self.elementText(for: element)
            if text == "Connect" {
                return true
            }

            return Self.connectPanelLabels.contains { label in
                text.localizedCaseInsensitiveContains(label)
            }
        }) != nil {
            return true
        }

        return connectPanelVisibleInWindowText(applicationElement: applicationElement)
    }

    private func pressTargetElement(_ element: AXUIElement) throws {
        if try clickExpandedRowHitArea(for: element) {
            return
        }

        if try triggerElementIfPossible(element) {
            return
        }

        var current: AXUIElement? = element
        for _ in 0 ..< 10 {
            guard let candidate = current else {
                break
            }

            if try clickExpandedRowHitArea(for: candidate) {
                return
            }

            if try triggerElementIfPossible(candidate) {
                return
            }

            current = parent(of: candidate)
        }

        throw TransferErrorCode.targetNotVisible
    }

    private func clickExpandedRowHitArea(for element: AXUIElement) throws -> Bool {
        guard
            let point = expandedRowHitPoint(for: element)
        else {
            return false
        }

        try click(at: point)
        return true
    }

    private func expandedRowHitPoint(for element: AXUIElement) -> CGPoint? {
        guard
            let position = pointAttribute(kAXPositionAttribute, from: element),
            let size = sizeAttribute(kAXSizeAttribute, from: element),
            size.width > 24,
            size.height > 18
        else {
            return nil
        }

        let rowWidth = max(size.width, 160)
        let xInset = min(max(rowWidth * 0.22, 72), rowWidth - 18)
        return CGPoint(
            x: position.x + xInset,
            y: position.y + (size.height / 2)
        )
    }

    private func findElement(
        in root: AXUIElement,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue = initialSearchRoots(for: root)
        var index = 0
        var visited = 0

        while index < queue.count && visited < 1500 {
            let element = queue[index]
            index += 1
            visited += 1

            if predicate(element) {
                return element
            }

            queue.append(contentsOf: children(of: element))
        }

        return nil
    }

    private func initialSearchRoots(for applicationElement: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []

        if let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement) {
            roots.append(focusedWindow)
            roots.append(contentsOf: children(of: focusedWindow))
        }

        let windows = childrenAttribute(kAXWindowsAttribute, from: applicationElement)
        if !windows.isEmpty {
            roots.append(contentsOf: windows)
        }

        if roots.isEmpty {
            roots.append(applicationElement)
        }

        var seen = Set<CFHashCode>()
        return roots.filter { element in
            let identifier = CFHash(element)
            return seen.insert(identifier).inserted
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []

        for attribute in Self.childAttributes {
            results.append(contentsOf: childrenAttribute(attribute, from: element))
        }

        return results
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXParentAttribute, from: element)
    }

    private func childrenAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return []
        }

        if CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AXUIElement] {
            return array
        }

        return []
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return nil
        }

        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }

        return nil
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return ""
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return ""
    }

    private func elementText(for element: AXUIElement) -> String {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute,
            kAXHelpAttribute,
        ]
        .map { stringAttribute($0, from: element) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private func copyAttributeValue(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }

        return value
    }

    private func canPress(_ element: AXUIElement) -> Bool {
        var actionNames: CFArray?
        let status = AXUIElementCopyActionNames(element, &actionNames)
        guard status == .success, let actions = actionNames as? [String] else {
            return false
        }

        return actions.contains(kAXPressAction as String)
    }

    private func performPress(on element: AXUIElement) throws {
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success else {
            throw TransferErrorCode.targetNotVisible
        }
    }

    private func triggerElement(_ element: AXUIElement) throws {
        guard try triggerElementIfPossible(element) else {
            throw TransferErrorCode.targetNotVisible
        }
    }

    private func triggerElementIfPossible(_ element: AXUIElement) throws -> Bool {
        if canPress(element) {
            try performPress(on: element)
            return true
        }

        guard let clickPoint = clickPoint(for: element) else {
            return false
        }

        try click(at: clickPoint)
        return true
    }

    private func clickPoint(for element: AXUIElement) -> CGPoint? {
        guard
            let position = pointAttribute(kAXPositionAttribute, from: element),
            let size = sizeAttribute(kAXSizeAttribute, from: element),
            size.width > 1,
            size.height > 1
        else {
            return nil
        }

        return CGPoint(x: position.x + (size.width / 2), y: position.y + (size.height / 2))
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return nil
        }

        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return nil
        }

        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private func click(at point: CGPoint) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TransferErrorCode.targetNotVisible
        }

        guard
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            throw TransferErrorCode.targetNotVisible
        }

        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    private func clickTargetFromWindowText(
        named targetName: String,
        spotifyProcessIdentifier: pid_t
    ) throws -> Bool {
        guard let windowMatch = spotifyWindowMatch(for: spotifyProcessIdentifier) else {
            return false
        }

        guard
            let image = CGWindowListCreateImage(
                .null,
                [.optionIncludingWindow],
                windowMatch.windowID,
                [.bestResolution, .boundsIgnoreFraming]
            ),
            let targetPoint = recognizeTargetPoint(
                named: targetName,
                in: image,
                windowBounds: windowMatch.bounds
            )
        else {
            return false
        }

        try click(at: targetPoint)
        return true
    }

    private func clickConnectButtonFromWindowText(spotifyProcessIdentifier: pid_t) throws -> Bool {
        guard let windowMatch = spotifyWindowMatch(for: spotifyProcessIdentifier) else {
            return false
        }

        guard
            let image = CGWindowListCreateImage(
                .null,
                [.optionIncludingWindow],
                windowMatch.windowID,
                [.bestResolution, .boundsIgnoreFraming]
            ),
            let connectPoint = recognizeConnectButtonPoint(in: image, windowBounds: windowMatch.bounds)
        else {
            return false
        }

        try click(at: connectPoint)
        return true
    }

    private func connectButtonFallbackPoints(spotifyProcessIdentifier: pid_t) -> [CGPoint] {
        guard let windowMatch = spotifyWindowMatch(for: spotifyProcessIdentifier) else {
            return []
        }

        return Self.connectButtonRelativePoints.map { relativePoint in
            CGPoint(
                x: windowMatch.bounds.minX + (windowMatch.bounds.width * relativePoint.x),
                y: windowMatch.bounds.minY + (windowMatch.bounds.height * relativePoint.y)
            )
        }
    }

    private func spotifyWindowMatch(for processIdentifier: pid_t) -> WindowMatch? {
        guard
            let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        return windowInfo
            .compactMap { info -> WindowMatch? in
                guard
                    let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                    ownerPID == processIdentifier,
                    let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                    let boundsValue = info[kCGWindowBounds as String],
                    CFGetTypeID(boundsValue as CFTypeRef) == CFDictionaryGetTypeID(),
                    let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                    bounds.width > 200,
                    bounds.height > 200
                else {
                    return nil
                }

                return WindowMatch(windowID: CGWindowID(windowNumber.uint32Value), bounds: bounds)
            }
            .max { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
    }

    private func recognizeTargetPoint(
        named targetName: String,
        in image: CGImage,
        windowBounds: CGRect
    ) -> CGPoint? {
        recognizedTextObservations(in: image).compactMap { observation -> CGPoint? in
            guard observation.topCandidates(5).contains(where: { candidate in
                Self.matchesTargetName(targetName, in: candidate.string)
            }) else {
                return nil
            }

            let boundingBox = observation.boundingBox
            let lineCenterY = windowBounds.minY + ((1 - boundingBox.midY) * windowBounds.height)
            let rowHitX = max(
                windowBounds.minX + (windowBounds.width * 0.76),
                windowBounds.minX + (boundingBox.minX * windowBounds.width) - 72
            )

            return CGPoint(x: rowHitX, y: lineCenterY)
        }.first
    }

    private func recognizeConnectButtonPoint(in image: CGImage, windowBounds: CGRect) -> CGPoint? {
        recognizedTextObservations(in: image).compactMap { observation -> CGPoint? in
            guard observation.topCandidates(5).contains(where: { candidate in
                Self.connectButtonLabels.contains(where: { label in
                    Self.matchesText(label, in: candidate.string)
                })
            }) else {
                return nil
            }

            let boundingBox = observation.boundingBox
            let centerX = windowBounds.minX + (boundingBox.midX * windowBounds.width)
            let centerY = windowBounds.minY + ((1 - boundingBox.midY) * windowBounds.height)
            return CGPoint(x: centerX, y: centerY)
        }.first
    }

    private func connectPanelVisibleInWindowText(applicationElement: AXUIElement) -> Bool {
        guard
            let window = primaryWindow(in: applicationElement),
            let position = pointAttribute(kAXPositionAttribute, from: window),
            let size = sizeAttribute(kAXSizeAttribute, from: window),
            let image = CGWindowListCreateImage(
                CGRect(origin: position, size: size),
                [.optionOnScreenOnly],
                kCGNullWindowID,
                [.bestResolution, .boundsIgnoreFraming]
            )
        else {
            return false
        }

        return recognizedTextObservations(in: image).contains { observation in
            observation.topCandidates(3).contains { candidate in
                Self.connectPanelLabels.contains(where: { label in
                    Self.matchesText(label, in: candidate.string)
                })
            }
        }
    }

    private func recognizedTextObservations(in image: CGImage) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return request.results ?? []
    }

    private static func matchesTargetName(_ targetName: String, in text: String) -> Bool {
        let normalizedTarget = normalize(targetName)
        let normalizedText = normalize(text)

        guard !normalizedTarget.isEmpty, !normalizedText.isEmpty else {
            return false
        }

        if normalizedText == normalizedTarget {
            return true
        }

        if normalizedText.contains(normalizedTarget) {
            return true
        }

        return normalizedText.split(separator: " ").contains { token in
            token == Substring(normalizedTarget)
        }
    }

    private static func matchesText(_ targetText: String, in text: String) -> Bool {
        let normalizedTarget = normalize(targetText)
        let normalizedText = normalize(text)

        guard !normalizedTarget.isEmpty, !normalizedText.isEmpty else {
            return false
        }

        return normalizedText == normalizedTarget || normalizedText.contains(normalizedTarget)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let connectButtonLabels = [
        "Connect to a device",
        "Connect",
        "Devices available",
        "Device picker",
    ]

    private static let connectPanelLabels = [
        "This computer",
        "This Mac",
        "This web browser",
        "What can I connect to?",
        "Don't see your device?",
    ]

    private static let connectButtonRelativePoints = [
        CGPoint(x: 0.72, y: 0.948),
        CGPoint(x: 0.76, y: 0.948),
        CGPoint(x: 0.80, y: 0.948),
        CGPoint(x: 0.84, y: 0.948),
        CGPoint(x: 0.88, y: 0.948),
        CGPoint(x: 0.72, y: 0.972),
        CGPoint(x: 0.76, y: 0.972),
        CGPoint(x: 0.80, y: 0.972),
        CGPoint(x: 0.84, y: 0.972),
        CGPoint(x: 0.88, y: 0.972),
    ]

    private static let childAttributes: [String] = [
        kAXChildrenAttribute,
        kAXRowsAttribute,
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
    ]
}

private struct WindowMatch {
    let windowID: CGWindowID
    let bounds: CGRect
}

private struct WindowSnapshot {
    let window: AXUIElement
    let position: CGPoint?
    let size: CGSize?
}
