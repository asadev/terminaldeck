import Foundation
import TerminalDeckNativeCore

/// A sent request is not a created session. Wait for the other Mac's state before opening its tab.
@MainActor enum NativeMachineSessionStart {
    static func create(machine: String, folder: String, provider: String,
        invoke: @MainActor (String, [Any?]) async throws -> Any = { try await EngineBridge.shared.invoke($0, $1) },
        observe: @MainActor (@escaping @MainActor (MachinesSnapshot) -> Void) -> (@MainActor () -> Void) = { receive in
            let subscription = EngineBridge.shared.on("machines:state") { args in
                if let view = MachinesSnapshot.decode(args.first) { receive(view) }
            }
            return { subscription.cancel() }
        }, created: @MainActor (RemoteSessionFacts) -> Void = { _ in }, timeout: Duration = .seconds(10)) async throws -> String {
        let (states, continuation) = AsyncStream<MachinesSnapshot>.makeStream()
        let stop = observe { continuation.yield($0) }
        defer { stop(); continuation.finish() }
        guard let before = MachinesSnapshot.decode(try await invoke("machines:list", []))?.links[machine], before.state == .online else {
            throw NativeRPCError(code: "refused", message: "That Mac is not connected. Check its connection and try again.")
        }
        let known = Set(before.sessions.map(\.id))
        guard (try await invoke("machines:create", [machine, folder, provider])) as? Bool == true else {
            throw NativeRPCError(code: "refused", message: "That Mac could not start the session. Please try again.")
        }
        let timer = Task { try? await Task.sleep(for: timeout); continuation.finish() }
        defer { timer.cancel() }
        for await view in states {
            guard let link = view.links[machine], link.state == .online else {
                throw NativeRPCError(code: "refused", message: "That Mac disconnected while starting. Check its sessions before trying again.")
            }
            if let row = link.sessions.first(where: { !known.contains($0.id) && NewSessionPaths.normalize($0.cwd) == NewSessionPaths.normalize(folder) && $0.provider == provider }) {
                created(row)
                return row.id
            }
        }
        throw NativeRPCError(code: "refused", message: "No new session appeared on that Mac. Check its sessions before trying again.")
    }
}
