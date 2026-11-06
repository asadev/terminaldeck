import AppKit
import ApplicationServices
import Foundation
import TerminalDeckNativeCore

/// The signed caller admits the owner's Full-control watch before forwarding a password. Capture ownership is
/// independent: the app may already have the working lock-screen picture, so this agent need not open another one.
@MainActor public enum BackendMacReachPassword {
    public struct Focus {
        public let secure: Bool
        public let pid: pid_t
        public let bundleID: String
        public init(secure: Bool, pid: pid_t, bundleID: String) {
            self.secure = secure; self.pid = pid; self.bundleID = bundleID
        }
    }
    /// Only the operating-system reads and event sink vary in tests; admission and every keystroke check stay real.
    public struct Environment {
        public var trusted: () -> Bool
        public var focus: () -> Focus?
        public var post: (pid_t, [UniChar]?, Bool) -> Void
        public init(trusted: @escaping () -> Bool, focus: @escaping () -> Focus?,
                    post: @escaping (pid_t, [UniChar]?, Bool) -> Void) {
            self.trusted = trusted; self.focus = focus; self.post = post
        }
        public static var system: Environment {
            Environment(trusted: { AXIsProcessTrusted() }, focus: {
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
                let element = unsafeBitCast(focused, to: AXUIElement.self)
                var subrole: CFTypeRef?, pid: pid_t = 0
                guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                      AXUIElementGetPid(element, &pid) == .success else { return nil }
                return Focus(secure: subrole as? String == "AXSecureTextField", pid: pid,
                             bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
            }, post: { pid, units, down in
                let source = CGEventSource(stateID: .hidSystemState)
                let event = CGEvent(keyboardEventSource: source, virtualKey: units == nil ? 36 : 0, keyDown: down)
                if let units { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
                event?.postToPid(pid)
            })
        }
    }
    public static func send(_ password: String?, state: () -> MacReach.State, environment: Environment = .system) throws {
        guard let attempt = BackendMacSignInAttempt.current else { throw BackendMacSignInAttempt.failure }
        try attempt.check()
        guard [.locked, .signingIn].contains(state()), environment.trusted(),
              let password, !password.isEmpty, password.utf16.count <= 2_000 else { throw BackendMacSignInAttempt.failure }
        guard let focus = environment.focus(), focus.secure, focus.pid > 1,
              ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.authorizationhost"].contains(focus.bundleID),
              [.locked, .signingIn].contains(state()) else { throw passwordFocus }
        // Target the secure process, so moving focus cannot type into an ordinary app. No waits or capture setup here.
        var chunk: [UniChar] = []
        func typeChunk() throws {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                try attempt.check()
                environment.post(focus.pid, chunk, down)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for character in password {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 16 { try typeChunk() }
            chunk.append(contentsOf: units)
        }
        try typeChunk()
        for down in [true, false] {
            try attempt.check()
            environment.post(focus.pid, nil, down)
        }
    }
    private static var passwordFocus: NativeRPCError {
        .init(code: "unavailable", message: "Click your Mac's password field first, then send the password again.")
    }
}
