import Foundation

/// Guided setup uses the bundled engine's detected defaults. The preview is
/// evidence about coverage, never a promise that the first check will pass.
public struct SFXSetupProduct: Equatable, Sendable, Identifiable {
    public var id: String { name + ":" + kind }
    public let name: String
    public let kind: String
    public let evidence: [String]
}

public struct SFXSetupFile: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let action: String
    public let summary: String
}

public struct SFXSetupPreview: Equatable, Sendable {
    public let token: String?
    public let summary: String
    public let configFile: String?
    public let configText: String
    public let files: [SFXSetupFile]
    public let products: [SFXSetupProduct]
    public let ready: [String]
    public let gaps: [FixedGap]
    public let notHere: [String]
    public let canApply: Bool
    public let alreadySetUp: Bool
    public let prepareNeeded: Bool
    public let preparation: String
    public let problem: String?
    public let commandNeeded: Bool
    public let checkCommand: String?
    public let commandExplanation: String
    public let partialSetup: Bool
    public let retryToken: String?
}

public struct SFXSetupApplyOutcome: Equatable, Sendable {
    public let ok: Bool
    public let wrote: [String]
    public let problem: String?
    public let partialSetup: Bool
    public let retryToken: String?
}

public enum SFXSetupWire {
    public static let preview = "staysfixed:setup-preview"
    public static let prepare = "staysfixed:setup-prepare"
    public static let apply = "staysfixed:setup-apply"

    public static func apply(_ value: Any?) -> SFXSetupApplyOutcome {
        let v = value as? [String: Any] ?? [:]
        let token = v["retryToken"] as? String ?? ""
        return SFXSetupApplyOutcome(ok: v["ok"] as? Bool == true, wrote: v["wrote"] as? [String] ?? [], problem: v["problem"] as? String, partialSetup: v["partialSetup"] as? Bool == true, retryToken: token.isEmpty ? nil : token)
    }

    public static func preview(_ value: Any?) -> SFXSetupPreview {
        let v = value as? [String: Any] ?? [:]
        func string(_ key: String) -> String { v[key] as? String ?? "" }
        func optional(_ key: String) -> String? { let text = string(key); return text.isEmpty ? nil : text }
        func strings(_ key: String) -> [String] { (v[key] as? [String] ?? []).filter { !$0.isEmpty } }
        let files = (v["files"] as? [[String: Any]] ?? []).map {
            SFXSetupFile(path: $0["path"] as? String ?? "", action: $0["action"] as? String ?? "", summary: $0["summary"] as? String ?? "")
        }.filter { !$0.path.isEmpty }
        let products = (v["products"] as? [[String: Any]] ?? []).map {
            SFXSetupProduct(name: $0["name"] as? String ?? "", kind: $0["kind"] as? String ?? "", evidence: $0["evidence"] as? [String] ?? [])
        }.filter { !$0.name.isEmpty }
        let gaps = (v["gaps"] as? [[String: Any]] ?? []).map {
            FixedGap(name: $0["name"] as? String ?? "", what: $0["what"] as? String ?? "", why: $0["why"] as? String ?? "", fix: $0["fix"] as? String ?? "", byPerson: $0["byPerson"] as? Bool == true, unlocks: $0["unlocks"] as? String ?? "")
        }
        return SFXSetupPreview(token: optional("token"), summary: string("summary"), configFile: optional("configFile"), configText: string("configText"), files: files, products: products, ready: strings("ready"), gaps: gaps, notHere: strings("notHere"), canApply: v["canApply"] as? Bool == true, alreadySetUp: v["alreadySetUp"] as? Bool == true, prepareNeeded: v["prepareNeeded"] as? Bool == true, preparation: string("preparation"), problem: optional("problem"), commandNeeded: v["commandNeeded"] as? Bool == true, checkCommand: optional("checkCommand"), commandExplanation: string("commandExplanation"), partialSetup: v["partialSetup"] as? Bool == true, retryToken: optional("retryToken"))
    }
}
