import Foundation
import TerminalDeckNativeCore

/// A/SYNC inject the existing authenticated, budgeted request path. This adapter
/// owns only the §6.5 shapes; it cannot create a URL or a network session.
public struct BackendCloudSecretsControl: CloudSecretsControlPort {
    public typealias Send = @Sendable (_ method: String, _ path: String, _ body: Data, _ requestId: String) async throws -> Data
    private let send: Send
    private let registration: @Sendable (String) async throws -> CloudDeviceRegistration
    /// PASSWORDS-5 point 6: the account's device list as friendly names (nil = not wired: names fall back as before).
    private let names: (@Sendable () async throws -> [CloudSecretsDeviceName])?
    public init(send: @escaping Send, registeredDevice: @escaping @Sendable (String) async throws -> CloudDeviceRegistration,
                deviceNames: (@Sendable () async throws -> [CloudSecretsDeviceName])? = nil) {
        self.send = send; self.registration = registeredDevice; self.names = deviceNames
    }
    private func post<T: Encodable, R: Decodable>(_ path: String, _ body: T, id: String) async throws -> R {
        let data = try CloudSecretsCanonical.encode(body)
        guard data.count <= 131_072 else { throw CloudFailure.invalidRequest }
        return try await CloudWire.decode(R.self, from: send("POST", path, data, id), maximumBytes: 131_072)
    }
    private func get<R: Decodable>(_ path: String) async throws -> R {
        try await CloudWire.decode(R.self, from: send("GET", path, Data(), UUID().uuidString.lowercased()), maximumBytes: 131_072)
    }
    public func status() async throws -> CloudSecretsStatus { try await get("/secrets/status") }
    public func initialize(_ request: CloudSecretsInitializeRequest) async throws -> CloudSecretsEnvelopeReceipt {
        try await post("/secrets/initialize", request, id: request.requestId)
    }
    public func requestApproval(_ request: CloudApprovalRequest) async throws -> CloudApproval {
        struct Response: Decodable { let approvalId: String; let challenge: String; let expiresAt: Int64 }
        let result: Response = try await post("/secrets/approval/request", request, id: request.requestId)
        return .init(approvalId: result.approvalId, targetDeviceId: request.targetDeviceId,
                     targetKeyHash: request.targetKeyHash, challenge: result.challenge, expiresAt: result.expiresAt)
    }
    public func answerApproval(_ request: CloudApprovalAnswer) async throws -> CloudSecretsAnswerReceipt {
        try await post("/secrets/approval/answer", request, id: request.requestId)
    }
    public func envelope() async throws -> CloudSecretsEnvelopeReceipt { try await get("/secrets/envelope") }
    public func possession(_ request: CloudPossessionRequest) async throws -> CloudSecretsPossessionReceipt {
        try await post("/secrets/possession", request, id: request.requestId)
    }
    public func recoveryChallenge(_ request: CloudRecoveryChallengeRequest) async throws -> CloudRecoveryChallenge {
        try await post("/secrets/recovery/challenge", request, id: request.requestId)
    }
    public func recover(_ request: CloudRecoveryCompleteRequest) async throws -> CloudSecretsEnvelopeReceipt {
        try await post("/secrets/recovery/complete", request, id: request.requestId)
    }
    public func reset(_ request: CloudSecretsResetRequest) async throws -> CloudSecretsResetReceipt {
        try await post("/secrets/reset", request, id: request.requestId)
    }
    public func registeredDevice(_ deviceId: String) async throws -> CloudDeviceRegistration { try await registration(deviceId) }
}

/// Review point 2's seam: the requesting device's own signature over its request. Needs the service change in
/// notes/cloud-everything-20261114/PASSWORDS-SERVICE-CHANGE.md; until the service keeps and returns it, nothing is
/// answered by itself (and the app does not wire the automatic hand-over at all).
extension BackendCloudSecretsControl: CloudSecretsRequestSigningPort {
    public func signRequest(requestId: String, approvalId: String, signature: String) async throws {
        struct Body: Encodable { let requestId: String; let approvalId: String; let signature: String }
        struct Receipt: Decodable { let approvalId: String }
        let receipt: Receipt = try await post("/secrets/approval/sign", Body(requestId: requestId, approvalId: approvalId, signature: signature), id: requestId)
        guard receipt.approvalId == approvalId else { throw CloudFailure.checksumMismatch }
    }
    public func requestSignatures() async throws -> [String: String] {
        let data = try await send("GET", "/secrets/status", Data(), UUID().uuidString.lowercased())
        guard data.count <= 131_072 else { throw CloudFailure.invalidRequest }
        let raw = try NativeRPCValue.parseJSON(data)
        var found: [String: String] = [:]
        for item in raw["pendingApprovals"].elements ?? [] {
            if let id = item["approvalId"].string, let signature = item["targetSignature"].string { found[id] = signature }
        }
        return found
    }
}

/// The owner's stricter setting, carried by the service for his other devices (service follow-up: `POST /secrets/policy`
/// with exactly `{requestId, askPolicy}`, kept per account, newest `at` wins, and returned unchanged as the optional
/// `askPolicy` of `/secrets/status` to every active device). The service cannot forge it: each Mac verifies the
/// signature with the key IT pinned. Until the route exists the publish fails and the setting stays on this Mac.
extension BackendCloudSecretsControl: CloudSecretsPolicyRelayPort {
    public func publishPolicy(requestId: String, policy: CloudSecretsAskPolicy) async throws {
        struct Body: Encodable { let requestId: String; let askPolicy: CloudSecretsAskPolicy }
        struct Receipt: Decodable { let at: Int64 }
        let receipt: Receipt = try await post("/secrets/policy", Body(requestId: requestId, askPolicy: policy), id: requestId)
        guard receipt.at >= policy.at else { throw CloudFailure.checksumMismatch }
    }
    public func publishedPolicy() async throws -> CloudSecretsAskPolicy? {
        let data = try await send("GET", "/secrets/status", Data(), UUID().uuidString.lowercased())
        guard data.count <= 131_072 else { throw CloudFailure.invalidRequest }
        return Self.askPolicy(try NativeRPCValue.parseJSON(data)["askPolicy"])
    }
    static func askPolicy(_ found: NativeRPCValue) -> CloudSecretsAskPolicy? {
        guard let ask = found["askOnNewDevice"].bool, let at = found["at"].number, let whole = Int64(exactly: at),
              let by = found["by"].string, let signature = found["signature"].string else { return nil }
        return .init(askOnNewDevice: ask, at: whole, by: by, signature: signature)
    }
}

/// 15 Nov: "Keep saved passwords and secret files off my phones", carried by the service for his other Macs (Servers
/// contract: `POST /secrets/policy/phones {requestId, phonesPolicy}`, computers only, newest `at` wins, returned unchanged
/// as the optional `phonesPolicy` of `/secrets/status`). Signed by the changing Mac, so the service cannot forge it.
/// Until the route exists the publish fails and the setting stays on this Mac.
extension BackendCloudSecretsControl: CloudSecretsPhonesPolicyRelayPort {
    public func publishPhonesPolicy(requestId: String, policy: CloudSecretsPhonesPolicy) async throws {
        struct Body: Encodable { let requestId: String; let phonesPolicy: CloudSecretsPhonesPolicy }
        struct Receipt: Decodable { let at: Int64 }
        let receipt: Receipt = try await post("/secrets/policy/phones", Body(requestId: requestId, phonesPolicy: policy), id: requestId)
        guard receipt.at >= policy.at else { throw CloudFailure.checksumMismatch }
    }
    public func publishedPhonesPolicy() async throws -> CloudSecretsPhonesPolicy? {
        let data = try await send("GET", "/secrets/status", Data(), UUID().uuidString.lowercased())
        guard data.count <= 131_072 else { throw CloudFailure.invalidRequest }
        let found = try NativeRPCValue.parseJSON(data)["phonesPolicy"]
        guard let off = found["phonesOff"].bool, let at = found["at"].number, let whole = Int64(exactly: at),
              let by = found["by"].string, let signature = found["signature"].string else { return nil }
        return .init(phonesOff: off, at: whole, by: by, signature: signature)
    }
}

/// The service's optional status facts (lane/cloud-secrets-policy 72959fbbd, 7ff81baac), read from the same answer as
/// the status: `askPolicy` (ON only, signed), `askPolicyTurnedOff {by, byName, changedAt}` (unsigned, display only),
/// `nobodyCanOpen`, `spare {addedBy, addedByName, addedAt}`. Today's live service sends none of them (all nil). A field
/// of the wrong shape counts as absent.
extension BackendCloudSecretsControl: CloudSecretsStatusFactsPort {
    public func statusFacts() async throws -> (status: CloudSecretsStatus, facts: CloudSecretsStatusFacts) {
        let data = try await send("GET", "/secrets/status", Data(), UUID().uuidString.lowercased())
        guard data.count <= 131_072 else { throw CloudFailure.invalidRequest }
        let status = try CloudWire.decode(CloudSecretsStatus.self, from: data, maximumBytes: 131_072)
        return (status, Self.facts(try NativeRPCValue.parseJSON(data)))
    }
    static func facts(_ raw: NativeRPCValue) -> CloudSecretsStatusFacts {
        func change(_ value: NativeRPCValue, by: String, name: String, at: String) -> CloudSecretsStatusFacts.Change? {
            guard let who = value[by].string, !who.isEmpty, who.count <= 64, let number = value[at].number,
                  let when = Int64(exactly: number), when > 0 else { return nil }
            // A name for one plain line: no line breaks, at most 80 characters.
            let shown = String((value[name].string ?? "").filter { !$0.isNewline }.prefix(80))
            return .init(by: who, byName: shown, at: when)
        }
        return .init(askPolicy: askPolicy(raw["askPolicy"]),
                     turnedOff: change(raw["askPolicyTurnedOff"], by: "by", name: "byName", at: "changedAt"),
                     nobodyCanOpen: raw["nobodyCanOpen"].bool,
                     spare: change(raw["spare"], by: "addedBy", name: "addedByName", at: "addedAt"),
                     spareCredentialId: raw["spare"]["credentialId"].string.flatMap { $0.isEmpty || $0.count > 1400 ? nil : $0 },
                     spareReplaced: change(raw["spare"], by: "replacedBy", name: "replacedByName", at: "replacedAt"))
    }
}

/// PASSWORDS-5 point 6: the one source of device names (the account's own list, friendly names). Display only.
extension BackendCloudSecretsControl: CloudSecretsDeviceNamesPort {
    public func deviceNames() async throws -> [CloudSecretsDeviceName] {
        guard let names else { throw CloudFailure.unavailable }
        return try await names()
    }
}

/// The passkey spare key's routes (service b51a46424 + 7ff81baac, computers only): `POST /secrets/spare/challenge`,
/// `POST /secrets/spare/add` (with this device's own signature), `POST /secrets/spare/open`. Until they are live every
/// call fails and the spare key is simply not offered. One spare per key generation.
extension BackendCloudSecretsControl: CloudSecretsSparePort {
    public func spareChallenge(requestId: String) async throws -> CloudSecretsSpareChallenge {
        struct Body: Encodable { let requestId: String }
        let found: CloudSecretsSpareChallenge = try await post("/secrets/spare/challenge", Body(requestId: requestId), id: requestId)
        guard found.spares.count <= 1 else { throw CloudFailure.invalidRequest }
        return found
    }
    public func addSpare(_ request: CloudSecretsSpareAddRequest) async throws {
        struct Receipt: Decodable { let credentialId: String }
        let receipt: Receipt = try await post("/secrets/spare/add", request, id: request.requestId)
        guard receipt.credentialId == request.credentialId else { throw CloudFailure.checksumMismatch }
    }
    public func openWithSpare(_ request: CloudSecretsSpareOpenRequest) async throws -> CloudSecretsEnvelopeReceipt {
        try await post("/secrets/spare/open", request, id: request.requestId)
    }
}

/// PASSWORDS-5 repair (service 7750c816e): `POST /secrets/spare/replace`, answer `{credentialId, replaced}`.
extension BackendCloudSecretsControl: CloudSecretsSpareReplacePort {
    public func replaceSpare(_ request: CloudSecretsSpareReplaceRequest) async throws -> String {
        struct Receipt: Decodable { let credentialId: String; let replaced: String }
        let receipt: Receipt = try await post("/secrets/spare/replace", request, id: request.requestId)
        guard receipt.credentialId == request.credentialId else { throw CloudFailure.checksumMismatch }
        return receipt.replaced
    }
}

/// A lost Mac signed out from another device (service as built, lane/cloud-next d0c902d76 + 68cd59435):
/// `rotationDue {since, removedDeviceId, removedName, holders[]}` of `/secrets/status` (computers only, only while due)
/// and `POST /secrets/rotate`. A plain `true` (f3f3d5910) is still read: holders then come from the account's device
/// list (`holdsKey`). Anything else, or a list that cannot be read: nothing due, nothing changes.
extension BackendCloudSecretsControl: CloudSecretsRotationPort {
    public func rotationDue() async throws -> CloudSecretsRotationDue? {
        let data = try await send("GET", "/secrets/status", Data(), UUID().uuidString.lowercased())
        guard data.count <= 131_072 else { return nil }
        let found = try NativeRPCValue.parseJSON(data)["rotationDue"]
        if let due = Self.rotationDue(found) { return due }
        guard found.bool == true, let names else { return nil }
        return .init(since: 0, removedDeviceId: "", removedName: "", holders: try await names().filter(\.holdsKey).map(\.deviceId))
    }
    /// The object form; a field of the wrong shape counts as absent (a malformed answer never starts a key change).
    static func rotationDue(_ found: NativeRPCValue) -> CloudSecretsRotationDue? {
        guard let since = found["since"].number, let at = Int64(exactly: since), at > 0,
              let removed = found["removedDeviceId"].string, !removed.isEmpty, removed.count <= 64,
              let listed = found["holders"].elements, listed.count <= 256 else { return nil }
        let holders = listed.compactMap { $0.string }.filter { !$0.isEmpty && $0.count <= 64 }
        guard holders.count == listed.count else { return nil }
        let name = String((found["removedName"].string ?? "").filter { !$0.isNewline }.prefix(80))
        return .init(since: at, removedDeviceId: removed, removedName: name, holders: holders)
    }
    public func rotate(_ request: CloudSecretsRotateRequest) async throws -> CloudSecretsRotateReceipt {
        try await post("/secrets/rotate", request, id: request.requestId)
    }
}

/// D1 "Yes, it's mine" (service 68cd59435): `signedOutBefore: true` on a pending request in `/secrets/status`, and
/// `POST /devices/confirm-mine {deviceId}` -> `{ok:true}` from another of his devices.
extension BackendCloudSecretsControl: CloudSecretsSignedOutBeforePort {
    public func signedOutBeforeRequests() async throws -> Set<String> {
        let data = try await send("GET", "/secrets/status", Data(), UUID().uuidString.lowercased())
        guard data.count <= 131_072 else { throw CloudFailure.invalidRequest }
        var flagged: Set<String> = []
        for item in try NativeRPCValue.parseJSON(data)["pendingApprovals"].elements ?? [] where item["signedOutBefore"].bool == true {
            if let id = item["approvalId"].string { flagged.insert(id) }
        }
        return flagged
    }
    public func confirmMine(deviceId: String) async throws {
        struct Body: Encodable { let deviceId: String }
        struct Receipt: Decodable { let ok: Bool }
        let receipt: Receipt = try await post("/devices/confirm-mine", Body(deviceId: deviceId), id: UUID().uuidString.lowercased())
        guard receipt.ok else { throw CloudFailure.checksumMismatch }
    }
}
