import AppKit
import Security
import SecurityInterface
import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor enum NativeCertificateDialog {
    /// Electron resolves void when its certificate dialog closes. Closing this
    /// panel does not itself mean that a certificate was accepted; the system
    /// panel owns every actual trust edit. No automatic trust grant is installed.
    static func show(_ options: NativeRPCValue, context: NativeRPCContext) throws -> NativeRPCValue {
        try BackendNodelessCertificateDialog.requireLocal(context)
        let chain = try BackendNodelessCertificateDialog.certificates(options).map { data -> SecCertificate in
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
                throw NativeRPCError.invalidArguments("The certificate data is not a valid X.509 certificate.")
            }; return certificate
        }
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust)
        guard status == errSecSuccess, let trust else {
            throw NativeRPCError(code: "unavailable", message: "macOS could not prepare the certificate trust dialog (status \(status)).")
        }
        // All supplied issuer data is already present. Preparing a dialog must
        // not silently start a certificate-fetch network request.
        let fetchStatus = SecTrustSetNetworkFetchAllowed(trust, false)
        guard fetchStatus == errSecSuccess else {
            throw NativeRPCError(code: "unavailable", message: "macOS could not disable certificate fetching for the trust dialog (status \(fetchStatus)).")
        }
        var evaluationError: CFError?
        _ = SecTrustEvaluateWithError(trust, &evaluationError)
        guard NativeFront.personActing else {
            throw NativeRPCError(code: "refused", message: "Bring the app forward before opening a certificate dialog.")
        }
        NativeFront.onlyForPerson("certificate dialog") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let panel = SFCertificateTrustPanel()
            _ = panel.runModal(for: trust, message: options["message"].string)
        }
        return .missing
    }
}
