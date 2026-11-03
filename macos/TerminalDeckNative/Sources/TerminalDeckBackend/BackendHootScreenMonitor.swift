import Foundation

@MainActor public protocol BackendHootDisplayRefresh: AnyObject {
    func displaysChanged()
}
extension BackendHootMenuBar: BackendHootDisplayRefresh {}

/// The app supplies screen notifications. Backend tests need no display or AppKit.
@MainActor public final class BackendHootScreenMonitor {
    public typealias Observe = (@escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)
    private let observe: Observe
    private weak var bar: (any BackendHootDisplayRefresh)?
    private var cancel: (@MainActor () -> Void)?
    public init(observe: @escaping Observe = { _ in {} }) { self.observe = observe }
    public func start(bar: any BackendHootDisplayRefresh) {
        stop(); self.bar = bar
        cancel = observe { [weak self] in self?.bar?.displaysChanged() }
        bar.displaysChanged()
    }
    public func stop() { cancel?(); cancel = nil; bar = nil }
}

/// The transparent catcher can miss mouseExited when it hands input to the
/// island. Match hoot-catcher.ts's repeat entry rule in its native mouseMoved
/// binding, so the second hover wakes the same controller again.
public struct BackendHootCatcherEntryGate: Sendable {
    public static let repeatMS = 100.0
    private var inside = false, said = 0.0
    public init() { }
    public mutating func moved(at milliseconds: Double) -> String? {
        guard !inside || milliseconds - said >= Self.repeatMS else { return nil }
        inside = true; said = milliseconds; return "enter"
    }
    public mutating func left() -> String? {
        guard inside else { return nil }; inside = false; return "leave"
    }
    public func pressed(button: Int) -> String? { button == 0 ? "press" : nil }
}
