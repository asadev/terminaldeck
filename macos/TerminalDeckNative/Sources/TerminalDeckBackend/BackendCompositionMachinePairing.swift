import Foundation
import TerminalDeckNativeCore

public enum BackendCompositionMachinePairing {
    /// The server installer receives the device's actual pairing fingerprint,
    /// not the remote host fingerprint displayed on a saved machine row.
    public static func receipt(coordinator: BackendMachineCoordinator, store: BackendMachineStore, code: String) async throws -> BackendServersHostLinkOutcome {
        let record = try await coordinator.pair(code: code)
        let paired = try await store.secrets(record.id)
        return .linked(machineId: record.id, machineName: record.name, deviceFingerprint: paired.guestIdentity.fingerprint)
    }
}
