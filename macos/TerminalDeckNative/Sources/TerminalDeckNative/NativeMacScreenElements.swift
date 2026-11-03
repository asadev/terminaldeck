import AppKit
import ApplicationServices
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Pick on this Mac's screen from a phone (devices-fix, 31 Oct): the elements of the windows on that display, read
/// through Accessibility (the permission This Mac's control already needs). Frontmost windows first, each window's
/// elements in reading order. Without Accessibility there is nothing to pick and the phone says so; drawing still works.
enum NativeMacScreenElements {
    static let missing = "Picking elements on this Mac needs Accessibility for Terminal Deck (System Settings → Privacy & Security → Accessibility). You can still draw on it."
    /// Roles a person points at even without a name.
    static let actionable: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
        "AXTextArea", "AXSearchField", "AXComboBox", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXTab", "AXDisclosureTriangle",
        "AXIncrementor", "AXColorWell", "AXSegmentedControl", "AXImage", "AXStaticText", "AXCell", "AXRow"]
    /// Scaffolding: only with a name of its own.
    static let scaffold: Set<String> = ["AXGroup", "AXUnknown", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem",
        "AXSplitter", "AXScrollBar", "AXValueIndicator", "AXList", "AXOutline", "AXTable", "AXColumn", "AXWebArea", "AXToolbar"]

    static func read(_ id: String) async -> BackendPhoneDeviceInspection {
        guard id.hasPrefix("mac:"), let number = UInt32(id.dropFirst(4)) else { return .init() }
        guard AXIsProcessTrusted() else { return .init(note: missing) }
        let display = CGDirectDisplayID(number)
        // Other apps are read off the main thread (they may be slow to answer); Terminal Deck's own windows only on the
        // main thread, where AppKit answers them in this process (read from a background thread it trapped in our own
        // views: the install #18 crash).
        let others = await Task.detached(priority: .userInitiated) { collect(display: display, own: false) }.value
        let own = await MainActor.run { collect(display: display, own: true) }
        guard !own.elements.isEmpty else { return others }
        let ownFirst = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        let all = Array((ownFirst ? own.elements + others.elements : others.elements + own.elements).prefix(BackendPhoneDevices.mostElements))
        return .init(elements: all, app: ownFirst || others.app.isEmpty ? own.app : others.app,
                     note: all.isEmpty ? "Nothing on this screen can be picked. You can still draw on it." : "")
    }

    /// The windows on `display`, front to back (their owners' Accessibility trees), as picks.
    /// `own`: only Terminal Deck's own windows (call on the main thread), else every other app's.
    nonisolated static func collect(display: CGDirectDisplayID, own: Bool) -> BackendPhoneDeviceInspection {
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0, bounds.height > 0 else { return .init() }
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var owners: [pid_t] = []
        for window in listed {
            guard (window[kCGWindowLayer as String] as? Int) == 0, let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let frame = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: frame as CFDictionary), rect.intersects(bounds), !owners.contains(pid),
                  MacFocusProbe.mustAskOnMain(focusedPID: pid, ownPID: getpid()) == own else { continue }
            owners.append(pid)
            if owners.count >= 4 { break }
        }
        var out: [BackendPhoneDeviceElement] = []
        var seen = Set<String>()
        var budget = 2_500
        let deadline = Date().addingTimeInterval(2.5)
        var front = ""
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 30, budget > 0, out.count < BackendPhoneDevices.mostElements, Date() < deadline else { return }
            budget -= 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if let rect = frame(element)?.intersection(bounds), !rect.isNull, rect.width >= 4, rect.height >= 4 {
                let secure = role == "AXSecureTextField" || string(element, kAXSubroleAttribute) == "AXSecureTextField"
                let name = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute),
                            secure ? nil : string(element, kAXValueAttribute), string(element, kAXHelpAttribute)]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                let identifier = string(element, "AXIdentifier") ?? ""
                let named = !name.isEmpty || !identifier.isEmpty
                let area = (rect.width * rect.height) / (bounds.width * bounds.height)
                if role != "AXWindow", area < 0.9, scaffold.contains(role) ? named : (named || actionable.contains(role)) {
                    let x = (rect.minX - bounds.minX) / bounds.width, y = (rect.minY - bounds.minY) / bounds.height
                    let key = "\(name)|\(Int(x * 1000)),\(Int(y * 1000)),\(Int(rect.width)),\(Int(rect.height))"
                    if seen.insert(key).inserted {
                        out.append(.init(role: plain(role), name: String(name.prefix(120)), identifier: identifier == name ? "" : identifier,
                                         x: x, y: y, width: rect.width / bounds.width, height: rect.height / bounds.height))
                    }
                }
            }
            for child in elements(element, kAXChildrenAttribute) { visit(child, depth: depth + 1) }
        }
        for pid in owners {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.4)
            if front.isEmpty { front = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "" }
            for window in elements(app, kAXWindowsAttribute) {
                guard let frame = frame(window), frame.intersects(bounds) else { continue }
                visit(window, depth: 0)
            }
        }
        return .init(elements: out, app: front, note: out.isEmpty ? "Nothing on this screen can be picked. You can still draw on it." : "")
    }

    nonisolated static func plain(_ role: String) -> String {
        var bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        if bare == "StaticText" { bare = "Text" }
        var out = ""
        var previous: Character?
        for char in bare {
            if let previous, previous.isLowercase, char.isUppercase { out.append(" ") }
            out.append(char); previous = char
        }
        return out.lowercased()
    }

    nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let list = value as? [AnyObject] else { return [] }
        return list.compactMap { item in CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil }
    }

    /// The element's frame in global display points (top-left origin, as `CGDisplayBounds`).
    nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
