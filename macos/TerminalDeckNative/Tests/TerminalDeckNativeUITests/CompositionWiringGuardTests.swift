import Foundation
import Testing
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// A wiring member read before assemble() set it fails that one operation with a clear line, never a launch trap.
@Suite("Composition wiring guard")
struct CompositionWiringGuardTests {
    @Test func aMissingMemberReturnsAnErrorAndOneLineInsteadOfCrashing() {
        let lines = NativeCompositionWiringLines()
        let missing: BackendCompositionAuthority? = nil
        #expect(throws: NativeRPCError(code: "composition-incomplete", message: "The app's authority is not ready yet.")) {
            _ = try NativeCompositionProduction.wired(missing, "authority", report: lines.append)
        }
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("authority is not wired yet") == true)
        #expect(lines.all.first?.contains("aMissingMemberReturnsAnErrorAndOneLineInsteadOfCrashing()") == true)
    }

    @MainActor @Test func productionAcceptsScreenActionsAndLogWithoutAWindow() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/part57-wiring-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in NativeWebAssets.required {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let configuration = EngineConfiguration(source: .nativeOnly(try NativeWebAssets.discover(resources: directory)), dataRoot: directory)
        let store = NativeStateStore()
        let graph = try BackendCompositionRoot(dataRoot: directory, state: store, environment: [:], home: directory.path)
        let settings = BackendAppSettingsStore(userData: directory, writable: false)
        let state = await BackendCompositionState.make(store: store, settings: settings, dataRoot: directory,
                                                       registry: graph.registry, copilotRoot: { _ in directory.path })
        let lines = NativeCompositionWiringLines()
        var runtime = NativeCompositionRoot.Runtime()
        runtime.window = { nil }
        runtime.showProject = { path in lines.append(path); return path == "/fixture/project" }
        runtime.whereWindow = { .string("fixture window") }
        runtime.report = lines.append
        let production = try NativeCompositionProduction(root: graph, state: state,
            engineConfiguration: configuration, window: runtime.window,
            showProject: runtime.showProject, whereWindow: runtime.whereWindow, report: runtime.report)
        #expect(production.window() == nil)
        #expect(try await production.showProject("/fixture/project"))
        #expect(try await NativeCompositionWhere(readWindow: production.whereWindow).read() == .string("fixture window"))
        production.report("fixture log")
        #expect(lines.all == ["/fixture/project", "fixture log"])
        await state.stop()
    }

    @Test func aWiredMemberPassesThroughWithoutALine() throws {
        let lines = NativeCompositionWiringLines()
        #expect(try NativeCompositionProduction.wired("ready", "core", report: lines.append) == "ready")
        #expect(lines.all.isEmpty)
    }
}

private final class NativeCompositionWiringLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}
