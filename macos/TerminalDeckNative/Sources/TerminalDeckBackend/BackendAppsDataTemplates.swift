import Foundation
import TerminalDeckNativeCore

/// Adapted from Coolify templates, Copyright 2025 Andras Bacsai, Apache-2.0.
/// Changed by Terminal Deck on 2026-10-07: Swift allowlist replaces YAML and
/// Coolify's URL variables; only private networking and owned volumes remain.
/// See macos/docker/APD-THIRD-PARTY.md and BackendAppsData-Coolify-LICENSE.txt.
public enum BackendAppsDataTemplates {
    public static let expandedFeature = "templates:catalogue-v2"

    /// Expanded entries appear only once DKA connects the reviewed planner.
    public static func list(expandedTemplatesEnabled: Bool = false) -> NativeRPCValue {
        .array(entries.filter { expandedTemplatesEnabled || $0.id == "uptime-kuma" }.map { entry in
            BackendAppsValidation.object([
                ("id", .string(entry.id)), ("name", .string(entry.name)),
                ("description", .string(entry.description)), ("category", .string(entry.category)),
                ("credit", .string("Adapted from Coolify by coolLabs / Andras Bacsai")),
                ("license", .string("Apache-2.0")), ("sourceURL", .string(entry.sourceURL)),
                ("applicationLicense", .string(entry.applicationLicense)),
                ("applicationSourceURL", .string(entry.applicationSourceURL)),
                ("requires", .array(entry.dataPath == nil ? [] : [.string("A private saved-data space")]))
            ])
        })
    }

    /// Caller input never supplies an image, mount, command or listening port.
    public static func source(templateID: String) throws -> NativeRPCValue {
        let entry = try entry(templateID)
        var fields: [(String, NativeRPCValue)] = [
            ("kind", .string("template")), ("templateId", .string(entry.id)),
            ("image", .string(entry.image)), ("port", .number(Double(entry.port)))
        ]
        if let path = entry.dataPath { fields.append(("dataPath", .string(path))) }
        return BackendAppsValidation.object(fields)
    }

    /// Check saved state against the reviewed tuple before any server command.
    static func validatedEntry(_ source: NativeRPCValue) throws -> BackendAppsDataTemplateEntry {
        guard let id = source["templateId"].string else {
            throw NativeRPCError.invalidArguments("Choose a reviewed app template.")
        }
        let entry = try entry(id)
        let expected = try Self.source(templateID: id)
        let fields = source.fields ?? []
        let expectedFields = expected.fields ?? []
        guard fields.count == expectedFields.count,
              Set(fields.map(\.key)).count == fields.count,
              Set(fields.map(\.key)) == Set(expectedFields.map(\.key)),
              expectedFields.allSatisfy({ source[$0.key] == $0.value }) else {
            throw NativeRPCError.invalidArguments("This template's saved settings do not match the reviewed template.")
        }
        return entry
    }

    static func entry(_ id: String) throws -> BackendAppsDataTemplateEntry {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw NativeRPCError(code: "not-found", message: "That template is not in the reviewed template list.")
        }
        return entry
    }

    static let entries: [BackendAppsDataTemplateEntry] = [
        .init(id: "uptime-kuma", name: "Uptime Kuma", description: "Check whether your apps are online and share a status page.",
              category: "Monitoring", image: "louislam/uptime-kuma:2", port: 3001, dataPath: "/app/data",
              applicationLicense: "MIT", applicationSourceURL: "https://github.com/louislam/uptime-kuma"),
        .init(id: "it-tools", name: "IT Tools", description: "Useful browser tools for text, dates, formats and everyday development.",
              category: "Tools", image: "corentinth/it-tools:latest", port: 80, dataPath: "/app/data",
              applicationLicense: "GPL-3.0", applicationSourceURL: "https://github.com/corentinth/it-tools"),
        .init(id: "excalidraw", name: "Excalidraw", description: "Sketch diagrams and drawings. Drawings are saved in your browser; shared live editing needs a separate service.",
              category: "Drawing", image: "excalidraw/excalidraw:latest", port: 80, dataPath: nil,
              applicationLicense: "MIT", applicationSourceURL: "https://github.com/excalidraw/excalidraw")
    ]
}

struct BackendAppsDataTemplateEntry: Sendable {
    let id, name, description, category, image: String
    let port: Int
    let dataPath: String?
    let applicationLicense, applicationSourceURL: String
    var sourceURL: String { "https://github.com/coollabsio/coolify/blob/main/templates/compose/" + id + ".yaml" }
}
