import Foundation

/// Reads a child's pipe without ever spinning. Dispatch re-fires a readability
/// handler for as long as the pipe sits at end-of-file, so a handler that returns
/// early on EOF without removing itself burns a whole core forever. The old
/// handler here returned on `guard let self` BEFORE its EOF check: once the
/// device child closed (owner released, child exited) it spun at ~100% CPU
/// for the rest of the app's life (PERF, round 6). EOF — and a released owner —
/// now always remove the handler first.
public enum BackendPipeDrain {
    public static func install<Owner: AnyObject & Sendable>(on reader: FileHandle, owner: Owner, receive: @escaping @Sendable (Owner, Data) -> Void) {
        reader.readabilityHandler = { [weak owner] handle in
            let data = handle.availableData
            guard !data.isEmpty, let owner else { handle.readabilityHandler = nil; return }
            receive(owner, data)
        }
    }
}
