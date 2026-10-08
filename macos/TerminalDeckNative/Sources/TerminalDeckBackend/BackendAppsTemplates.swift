import Foundation
import TerminalDeckNativeCore

/// A reviewed subset, translated from Coolify's Apache-2.0 template.
/// Attribution and changes are recorded in macos/docker/THIRD-PARTY.md.
public enum BackendAppsTemplates {
    public static func list() -> NativeRPCValue {
        .array([BackendAppsValidation.object([
            ("id", .string("uptime-kuma")), ("name", .string("Uptime Kuma")),
            ("description", .string("A status page and checks for your apps.")),
            ("credit", .string("Adapted from Coolify by coolLabs")), ("license", .string("Apache-2.0")),
            ("sourceURL", .string("https://github.com/coollabsio/coolify/blob/main/templates/compose/uptime-kuma.yaml")),
            ("requires", .array([.string("A private data volume")]))
        ])])
    }
    public static func source(templateID: String) throws -> NativeRPCValue {
        guard templateID == "uptime-kuma" else { throw NativeRPCError(code: "not-found", message: "That template is not in the reviewed template list.") }
        return BackendAppsValidation.object([
            ("kind", .string("template")), ("templateId", .string(templateID)),
            ("image", .string("louislam/uptime-kuma:2")), ("port", .number(3001)), ("dataPath", .string("/app/data"))
        ])
    }
}
