import Foundation
import Observation
import TerminalDeckNativeCore

/// Names and colours used by the existing rows. One push subscription; no timer.
@MainActor
@Observable
final class NativePROJLabels {
    static let shared = NativePROJLabels()
    var projects = PROJProjects.defaults
    var activeProjectID: String?
    private(set) var error: String?
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var loading: Task<Void, Never>?
    private init() {}
    func name(for id: String) -> String { PROJProjects.name(for: id, projects: projects) }
    func name(for id: String?, folder: String?) -> String { name(for: PROJProjects.resolve(projectID: id, folder: folder, projects: projects)) }
    func start() {
        guard EngineBridge.shared.isReady, subscription == nil else { return }
        subscription = EngineBridge.shared.on("project-registry:changed") { [weak self] args in
            Task { @MainActor in
                guard let self else { return }
                if let value = args.first { self.accept(value) } else { self.read() }
            }
        }
        read()
    }
    private func accept(_ value: Any) {
        do {
            let state = try NativeRPCValue.fromFoundation(value)
            let decoded = try PROJProjects.registeredProjects(state)
            projects = decoded; activeProjectID = state["activeProjectId"].string; error = nil
        } catch { self.error = "Could not read projects." }
    }
    private func read() {
        guard loading == nil else { return }
        loading = Task { [weak self] in
            guard let self else { return }
            defer { self.loading = nil }
            do { self.accept(try await EngineBridge.shared.invoke("project-registry:list")) }
            catch { self.error = "Could not read projects." }
        }
    }
}
