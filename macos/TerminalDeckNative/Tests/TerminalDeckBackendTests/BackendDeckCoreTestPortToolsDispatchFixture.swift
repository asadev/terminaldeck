import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortToolsCoreSurface: BackendDeckCoreCatalogueSurface, @unchecked Sendable {
    let window: Bool
    private let lock = NSLock()
    private var preferences: NativeRPCValue = .object([.init("theme",.string("dark"))])
    private var settings: NativeRPCValue = .object([.init("appearance.density",.string("comfortable"))])
    private var pushes: [NativeRPCValue] = []
    private var started: [NativeRPCValue] = []
    init(window: Bool = true) { self.window = window }
    func listSessions() -> [NativeRPCValue] { [] }
    func listProjects() -> [NativeRPCValue] { [.object([.init("path",.string("/work/api")),.init("lastOpenedAt",.number(1))])] }
    func sessionStatus(_ sessionID: String) -> NativeRPCValue { .null }
    func appStateRoot() -> String { "/state" }
    func copilotRoot() -> String { "/state/copilot" }
    func windows(sessionID: String) -> [NativeRPCValue] { [] }
    func readSettings() -> NativeRPCValue { lock.withLock { .object([.init("settings",settings),.init("preferences",preferences)]) } }
    func snapshotSettings() -> NativeRPCValue { .object([.init("path",.string("/fixture/settings.last-good.json")),.init("at",.number(0))]) }
    func writeSettings(_ patch: NativeRPCValue) -> NativeRPCValue { lock.withLock { settings = settings.merging(patch); return settings } }
    func writePreferences(_ patch: NativeRPCValue) -> NativeRPCValue { lock.withLock { preferences = preferences.merging(patch); return preferences } }
    func applyToWindow(scope: String,values: NativeRPCValue) -> Bool { lock.withLock { if window { pushes.append(.object([.init("scope",.string(scope)),.init("values",values)])) }; return window } }
    func pushed() -> [NativeRPCValue] { lock.withLock { pushes } }
    func starts() -> [NativeRPCValue] { lock.withLock { started } }
    func startSession(input: NativeRPCValue,forDevice: String?) -> NativeRPCValue { lock.withLock { started.append(input); return input.setting("id",.string("new")) } }
}

private actor BackendDeckCoreTestPortToolsConsentReference {
    var broker: BackendDeckCoreSecurityConsentBroker?
    func bind(_ broker: BackendDeckCoreSecurityConsentBroker) { self.broker = broker }
    func answer(_ question: BackendDeckCoreSecurityConsentRequest) async -> Bool { await broker?.respond(id:question.id,approved:true,by:"window") ?? false }
}

struct BackendDeckCoreTestPortToolsCoreRig: Sendable {
    let surface: BackendDeckCoreTestPortToolsCoreSurface
    let control: BackendDeckCoreSecurityControl
    let log: BackendDeckCoreSecurityActionLog
    let directory: URL
    static func make(window: Bool = true,extra: [BackendDeckCoreSecurityToolPolicy] = []) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreTestPortTools-"+UUID().uuidString)
        let log = BackendDeckCoreSecurityActionLog(directory:directory,now:{ 1_000_000 }),reference = BackendDeckCoreTestPortToolsConsentReference()
        let broker = BackendDeckCoreSecurityConsentBroker(now:{ 1_000_000 },ask:{ await reference.answer($0) }); await reference.bind(broker)
        let surface = BackendDeckCoreTestPortToolsCoreSurface(window:window),builtins = try BackendDeckCoreCatalogueBuiltins.tools(surface:surface),meta = try BackendDeckCoreCatalogueDescribe.tools(catalogue:{ [] })
        let control = try BackendDeckCoreSecurityControl(log:log,consent:broker,policies:builtins.policies+meta.policies+extra,now:{ 1_000_000 })
        return Self(surface:surface,control:control,log:log,directory:directory)
    }
    static func context() -> BackendDeckCoreSecurityCallContext { .init(native:BackendDeckCoreTestPortToolsFixture.caller(),caller:.local,callID:"row",attended:true,granted:nil,sessionLimits:.missing,now:{ 1_000_000 },startedByCopilot:{ _ in false },noteStarted:{ _ in }) }
}
