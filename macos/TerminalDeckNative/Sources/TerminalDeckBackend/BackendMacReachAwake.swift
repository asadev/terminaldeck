import Foundation
import IOKit.pwr_mgt

/// The approved boot helper follows General's verified power setting, independently of phone access or power source.
/// Injection lets checks exercise the lifetime without changing this Mac's power state.
@MainActor public final class BackendMacReachAwake {
    private var assertion: IOPMAssertionID?
    private let create: () -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    public private(set) var problem: String?
    public var active: Bool { assertion != nil }
    public init(create: @escaping () -> IOPMAssertionID? = BackendMacReachAwake.createAssertion,
                release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.create = create; self.release = release
    }
    nonisolated public static func createAssertion() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Keep this Mac awake" as CFString, &id) == kIOReturnSuccess else { return nil }
        return id
    }
    public func update(enabled: Bool) {
        guard enabled else { stop(); return }
        guard assertion == nil else { return }
        assertion = create()
        problem = assertion == nil ? "macOS could not keep this Mac awake." : nil
    }
    public func stop() {
        if let assertion { release(assertion) }
        assertion = nil; problem = nil
    }
}
