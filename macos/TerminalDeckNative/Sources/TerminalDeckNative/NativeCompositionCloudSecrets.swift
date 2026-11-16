import AppKit
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Lane A creates this once from its authenticated, subject-scoped composition.
/// This file does not register a route or touch any existing application wiring.
@MainActor
struct NativeCompositionCloudSecrets {
    let recovery: CloudRecoveryCoordinator
    let content: CloudSecretsContent
    let interaction: NativeCloudRecoveryInteraction
    static func make(subject: CloudSubject, device: CloudDeviceRegistration, keys: any CloudDeviceKeyPort,
                     local: any CloudSecretsLocalKeyPort, control: any CloudSecretsControlPort,
                     policy: CloudSecretsPolicy, parent: @escaping @MainActor @Sendable () -> NSWindow?,
                     resetTicket: @escaping @Sendable () async throws -> String) -> Self {
        let interaction = NativeCloudRecoveryInteraction(parent: parent)
        let recovery = CloudRecoveryCoordinator(subject: subject, device: device, keys: keys, local: local, control: control,
            words: BackendCloudRecoveryMnemonic(), interaction: interaction, policy: policy, resetTicket: resetTicket)
        return .init(recovery: recovery, content: .init(subject: subject, deviceId: device.deviceId, local: local, policy: policy), interaction: interaction)
    }
}
