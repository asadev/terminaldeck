import Foundation
import Security
import AppKit
import SecurityInterface
import TerminalDeckNativeCore

/// Native supplier for the fourth retained FRONTED_DIALOGS operation. Existing
/// open/save/message presenters stay with NativeOSBridge. Construction is inert;
/// only an actual app-owned call opens the standard macOS trust panel.
@MainActor public enum BackendNodelessCertificateDialog {
    public static let method = "showCertificateTrustDialog"
    public static let maximumCertificateBytes = 1024 * 1024
    public static let maximumChainBytes = 4 * 1024 * 1024
    public static let maximumChainLength = 32

    /// The legacy Electron Certificate wire shape carries PEM in `data` and its
    /// issuer in `issuerCert`. Principal names/dates/fingerprints are descriptive;
    /// derive native trust from the actual certificates rather than trusting them.
    public static func certificates(_ options: NativeRPCValue) throws -> [Data] {
        guard options.fields != nil, options["certificate"].fields != nil else {
            throw NativeRPCError.invalidArguments("The certificate trust dialog needs a certificate.")
        }
        var current = options["certificate"], out: [Data] = [], seen = Set<Data>(), total = 0
        while current.fields != nil {
            guard let text = current["data"].string, text.utf8.count <= maximumCertificateBytes * 2 else {
                throw NativeRPCError.invalidArguments("The certificate has no usable bounded data.")
            }
            let bytes = try certificateData(text)
            if seen.contains(bytes) { break } // Self-issued root, not a second copy.
            guard out.count < maximumChainLength, bytes.count <= maximumCertificateBytes,
                  total <= maximumChainBytes - bytes.count else {
                throw NativeRPCError.invalidArguments("The certificate chain exceeds the native dialog’s size limit.")
            }
            seen.insert(bytes); out.append(bytes); total += bytes.count
            let issuer = current["issuerCert"]
            guard issuer.fields != nil else { break }; current = issuer
        }
        guard !out.isEmpty else { throw NativeRPCError.invalidArguments("The certificate trust dialog needs a certificate.") }
        return out
    }

    public static func certificateData(_ text: String) throws -> Data {
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        let raw = BackendSharedText.trim(text)
        let body: String
        if raw.hasPrefix(begin), raw.hasSuffix(end) {
            body = String(raw.dropFirst(begin.count).dropLast(end.count))
            guard !body.contains(begin), !body.contains(end) else {
                throw NativeRPCError.invalidArguments("Each certificate entry must hold one certificate.")
            }
        } else {
            guard !raw.contains("-----") else { throw NativeRPCError.invalidArguments("The certificate PEM is malformed.") }
            body = raw
        }
        let compact = body.unicodeScalars.filter { ![9, 10, 13, 32].contains(Int($0.value)) }.map(String.init).joined()
        guard compact.utf8.count <= maximumCertificateBytes * 2, let bytes = Data(base64Encoded: compact),
              !bytes.isEmpty, bytes.count <= maximumCertificateBytes, bytes.base64EncodedString() == compact else {
            throw NativeRPCError.invalidArguments("The certificate does not contain valid PEM or base64 DER data.")
        }
        return bytes
    }

    /// Electron resolves void when its certificate dialog closes. Closing this
    /// panel does not itself mean that a certificate was accepted; the system
    /// panel owns every actual trust edit. No automatic trust grant is installed.
    public static func show(_ options: NativeRPCValue, context: NativeRPCContext) throws -> NativeRPCValue {
        guard context.caller == .nativeApp else {
            throw NativeRPCError(code: "access-denied", message: "Certificate trust is changed from this app’s own window.")
        }
        let chain = try certificates(options).map { data -> SecCertificate in
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
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = SFCertificateTrustPanel()
        _ = panel.runModal(for: trust, message: options["message"].string)
        return .missing
    }
}
