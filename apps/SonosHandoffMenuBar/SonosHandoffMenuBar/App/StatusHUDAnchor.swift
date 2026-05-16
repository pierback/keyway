@preconcurrency import AppKit
import ApplicationServices

enum StatusHUDAnchor {
    private static let statusItemTitle = "Sonos"

    static func statusItemFrame() -> NSRect? {
        let appElement = AXUIElementCreateApplication(getpid())
        let menuBarAttributes = [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute]

        for attribute in menuBarAttributes {
            if let frame = statusItemFrame(for: attribute, in: appElement) {
                return frame
            }
        }

        return nil
    }

    static func fallbackStatusAreaCenterX(in visibleFrame: NSRect) -> CGFloat {
        let statusAreaWidth = min(visibleFrame.width, 680)
        return visibleFrame.maxX - (statusAreaWidth / 2)
    }

    private static func statusItemFrame(for attribute: String, in appElement: AXUIElement) -> NSRect? {
        var menuBarsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &menuBarsValue) == .success,
              let menuBarsValue
        else {
            return nil
        }

        let menuBars: [AXUIElement]
        if CFGetTypeID(menuBarsValue) == AXUIElementGetTypeID() {
            // Swift requires a forced CoreFoundation cast; the CFTypeID check above is the runtime guard.
            menuBars = [menuBarsValue as! AXUIElement]
        } else if CFGetTypeID(menuBarsValue) == CFArrayGetTypeID() {
            menuBars = menuBarsValue as? [AXUIElement] ?? []
        } else {
            return nil
        }

        for menuBar in menuBars {
            if let frame = statusItemFrame(in: menuBar) {
                return frame
            }
        }

        return nil
    }

    private static func statusItemFrame(in menuBar: AXUIElement) -> NSRect? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if statusItemMatches(child), let frame = frame(of: child) {
                return frame
            }
        }

        return nil
    }

    private static func statusItemMatches(_ element: AXUIElement) -> Bool {
        guard stringAttribute(kAXTitleAttribute, from: element) == statusItemTitle else {
            return false
        }

        return stringAttribute(kAXRoleAttribute, from: element) == kAXMenuBarItemRole
    }

    private static func frame(of element: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              let point = point(from: positionValue),
              let dimensions = size(from: sizeValue)
        else {
            return nil
        }

        return NSRect(origin: point, size: dimensions)
    }

    private static func point(from value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        // Swift requires a forced CoreFoundation cast; the CFTypeID check above is the runtime guard.
        let axValue = value as! AXValue
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private static func size(from value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        // Swift requires a forced CoreFoundation cast; the CFTypeID check above is the runtime guard.
        let axValue = value as! AXValue
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }
}
