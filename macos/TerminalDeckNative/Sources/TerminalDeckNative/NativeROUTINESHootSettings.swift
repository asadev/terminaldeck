import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct ROUTINESHootFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A view model over the real capability owner, never a second defaults store.
@MainActor @Observable
final class ROUTINESHootSettingsModel {
    /// The live app shares one model between Settings → Hoot and the quick popover.
    static let shared = ROUTINESHootSettingsModel()
    typealias Invoke = @MainActor (String, [Any?]) async throws -> CodingAIJSON
    var values = CodingAIJSON([String: Any]())
    var loaded = false
    var busy = false
    var problem: String?
    var status: String?
    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let live: Bool

    init(snapshot: CodingAIJSON? = nil, live: Bool = true, invoke: @escaping Invoke = { channel, args in
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }) {
        self.invoke = invoke
        self.live = live
        if let snapshot { values = snapshot; loaded = true }
    }
    func canChange(_ field: String) -> Bool { loaded && !busy && values["capabilities"][field].isTrue }
    func boolBinding(_ field: String) -> Binding<Bool> {
        Binding(get: { self.values[field].isTrue }, set: { self.save(field, $0) })
    }
    func stringBinding(_ field: String, fallback: String) -> Binding<String> {
        Binding(get: { self.values[field].string ?? fallback }, set: { self.save(field, $0) })
    }
    func load() {
        guard live, !busy else { return }
        generation += 1; let mine = generation
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard generation == mine, !loaded, problem == nil else { return }
            generation += 1
            problem = "Hoot's abilities took too long to read. Try Again."
        }
        Task {
            do {
                let value = try await invoke("hoot:settings:read", [])
                guard generation == mine else { return }
                values = value; loaded = true; problem = nil
            } catch {
                guard generation == mine else { return }
                problem = CodingAIErrorText.from(error, fallback: "Couldn't read Hoot's abilities.")
            }
        }
    }
    func save(_ field: String, _ value: Any, completion: (@MainActor () -> Void)? = nil) {
        guard canChange(field) else { problem = "This Hoot control is unavailable."; return }
        busy = true; status = "Saving…"; problem = nil
        Task {
            defer { busy = false }
            do {
                values = try await invoke("hoot:settings:set", [["field": field, "value": value]])
                status = "Saved."
                completion?()
            } catch { problem = CodingAIErrorText.from(error, fallback: "Couldn't save Hoot's settings."); status = nil }
        }
    }
    func reset(_ completion: @escaping @MainActor () -> Void) {
        guard canChange("reset") else { return }
        busy = true; status = "Resetting…"; problem = nil
        Task {
            defer { busy = false }
            do {
                let answer = try await invoke("hoot:settings:reset", [["confirm": "Reset Hoot"]])
                guard answer["ok"].isTrue else { throw ROUTINESHootFailure(answer["error"].string ?? "Couldn't reset Hoot.") }
                status = "Hoot's chat and notes were cleared."; completion()
            } catch { problem = CodingAIErrorText.from(error, fallback: "Couldn't reset Hoot."); status = nil }
        }
    }
}
