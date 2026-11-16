import AppKit
import AuthenticationServices
import CryptoKit
import Security
import TerminalDeckNativeCore

/// PASSWORDS-2 slice 2: his passkey with the WebAuthn PRF extension (AuthenticationServices, macOS 15+; the app needs
/// macOS 26). Shows only the system's own passkey sheet (Touch ID). Usable only when the app carries the associated
/// domain `webcredentials:terminaldeck.dev` (Release seat) and terminaldeck.dev serves its
/// `apple-app-site-association` (Store & Website seat); until then `available()` is false and nothing is offered.
@MainActor
final class NativeCloudPasskey: NSObject, CloudSecretsPasskeyPort, ASAuthorizationControllerDelegate,
                                ASAuthorizationControllerPresentationContextProviding {
    nonisolated static let relyingParty = "terminaldeck.dev"
    private var pending: CheckedContinuation<ASAuthorization, any Error>?
    private var controller: ASAuthorizationController?

    /// The signed app carries `webcredentials:terminaldeck.dev` (without it macOS refuses every passkey request).
    nonisolated static func hasAssociatedDomain() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.associated-domains" as CFString, nil) as? [String]
        else { return false }
        return value.contains("webcredentials:" + relyingParty)
    }
    nonisolated func available() async -> Bool { Self.hasAssociatedDomain() }

    nonisolated func create(challenge: Data, userId: Data, userName: String, salt: Data, excluded: [Data]) async throws -> CloudSecretsPasskeyCreated {
        try await createHere(challenge: challenge, userId: userId, userName: userName, salt: salt, excluded: excluded)
    }
    /// PASSWORDS-5 point 1: the system's cancel on this app's own open sheet (a spare was made elsewhere, or the sheet's
    /// one-time challenge ran out). The waiting call ends with `CancellationError`.
    nonisolated func cancel() async { await cancelHere() }
    private func cancelHere() {
        guard pending != nil else { return }
        controller?.cancel()
        // The delegate normally reports the cancel; ending the wait here too makes sure it ends (the second end is ignored).
        finish(.failure(CancellationError()))
    }
    nonisolated func use(challenge: Data, allowed: [Data], salt: Data) async throws -> CloudSecretsPasskeyUsed {
        try await useHere(challenge: challenge, allowed: allowed, salt: salt)
    }
    /// Everything of AuthenticationServices stays on the main actor; only plain values leave it.
    private func createHere(challenge: Data, userId: Data, userName: String, salt: Data, excluded: [Data]) async throws -> CloudSecretsPasskeyCreated {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: userId)
        // PASSWORDS-5 point 5: the system refuses (error 1006) to make a second passkey where one of these is held.
        if !excluded.isEmpty {
            request.excludedCredentials = excluded.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        }
        request.prf = .inputValues(.init(saltInput1: salt))
        // The service accepts only a passkey made with Touch ID or his password (user verified); ask for exactly that.
        request.userVerificationPreference = .required
        let result = try await perform(request)
        guard let registration = result.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else { throw CloudFailure.invalidRequest }
        guard registration.prf?.isSupported == true else { throw CloudFailure.unsupportedFormat }
        let id = registration.credentialID
        let attestation = registration.rawAttestationObject ?? Data()
        let client = registration.rawClientDataJSON
        // Some authenticators give the PRF output only on use: then one more Touch ID right away.
        if let first = registration.prf?.first {
            return .init(credentialId: id, attestationObject: attestation, clientDataJSON: client, prf: first.withUnsafeBytes { Data($0) })
        }
        let used = try await useHere(challenge: challenge, allowed: [id], salt: salt)
        return .init(credentialId: id, attestationObject: attestation, clientDataJSON: client, prf: used.prf)
    }
    private func useHere(challenge: Data, allowed: [Data], salt: Data) async throws -> CloudSecretsPasskeyUsed {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        request.prf = .inputValues(.init(saltInput1: salt))
        request.userVerificationPreference = .required
        let result = try await perform(request)
        guard let assertion = result.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
              let first = assertion.prf?.first else { throw CloudFailure.unsupportedFormat }
        return .init(credentialId: assertion.credentialID, authenticatorData: assertion.rawAuthenticatorData,
                     clientDataJSON: assertion.rawClientDataJSON, signature: assertion.signature, prf: first.withUnsafeBytes { Data($0) })
    }
    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        guard pending == nil else { throw CloudFailure.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let asked = ObjectIdentifier(controller)
        MainActor.assumeIsolated {
            // A late answer from a sheet this app already withdrew never ends a later sheet's wait.
            guard let current = self.controller, ObjectIdentifier(current) == asked else { return }
            finish(.success(authorization))
        }
    }
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let asked = ObjectIdentifier(controller)
        MainActor.assumeIsolated {
            guard let current = self.controller, ObjectIdentifier(current) == asked else { return }
            // His "Cancel" on the system sheet is not a failure. Anything else is said in plain words (gap 2: the log
            // shows the system's reason, never its text, which can quote the app's identifier).
            if (error as? ASAuthorizationError)?.code == .canceled { finish(.failure(CancellationError())) }
            // PASSWORDS-5: the system refused because an excluded passkey (the spare's) is on this Mac: said as such.
            else if (error as NSError).domain == ASAuthorizationError.errorDomain, (error as NSError).code == 1006 {
                finish(.failure(CloudSecretsPasskeyExcluded()))
            }
            else { finish(.failure(CloudSecretsPlainFailure(Self.plainReason(error)))) }
        }
    }
    private func finish(_ result: Result<ASAuthorization, any Error>) {
        let waiting = pending
        pending = nil; controller = nil
        waiting?.resume(with: result)
    }
    /// The system's reason for a failed passkey sheet, in plain words (raw codes of ASAuthorizationError.Code).
    nonisolated static func plainReason(_ error: any Error) -> String {
        let ns = error as NSError
        guard ns.domain == ASAuthorizationError.errorDomain else { return CloudSecretsLog.cause(error) }
        switch ns.code {
        case 1004: return "the system refused the passkey (failed; on a first try Apple's copy of the domain file may not be there yet)"
        case 1003: return "the system did not handle the passkey request"
        case 1002: return "the system gave an answer that could not be used"
        case 1005: return "the system needs a person at this Mac (not interactive)"
        case 1006: return "a passkey for this account already exists on this Mac"
        case 1000: return "the system gave an unknown error"
        default: return "the system refused the passkey (code " + String(ns.code) + ")"
        }
    }
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow() }
    }
}
