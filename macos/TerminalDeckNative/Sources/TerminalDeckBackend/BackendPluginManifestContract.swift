import Foundation
import TerminalDeckNativeCore

extension BackendPluginsManifestReader {
    static func contract(_ block: NativeRPCValue, capabilities: [String], tools: [BackendPluginsToolManifest]) throws -> NativeRPCValue {
        var jobs: [NativeRPCValue] = [], cards: [NativeRPCValue] = [], events: [NativeRPCValue] = []
        for job in try (block.has("jobs") ? list(block["jobs"], "plugin.jobs", 4) : []) {
            try PluginContract.closed(job, ["id", "title", "inputSchema"], "plugin.jobs")
            let id = try PluginContract.key(job["id"]); _ = try PluginContract.text(job["title"], limit: 80)
            guard !jobs.contains(where: { $0["id"].string == id }) else { throw refusal("plugin.jobs repeats an id") }
            try actionSchema(job["inputSchema"])
            jobs.append(job)
        }
        if block.has("ui") {
            try PluginContract.closed(block["ui"], ["cards"], "plugin.ui")
            for card in try list(block["ui"]["cards"], "plugin.ui.cards", 4) {
                try PluginContract.closed(card, ["id", "title", "fields", "actions"], "plugin.ui.cards")
                let id = try PluginContract.key(card["id"]); _ = try PluginContract.text(card["title"], limit: 80)
                guard !cards.contains(where: { $0["id"].string == id }) else { throw refusal("plugin.ui.cards repeats an id") }
                let fields = try list(card["fields"], "card.fields", 8)
                var seen = Set<String>()
                for field in fields { try PluginContract.closed(field, ["id", "label"], "card.fields"); guard seen.insert(try PluginContract.key(field["id"])).inserted else { throw refusal("card.fields repeats an id") }; _ = try PluginContract.text(field["label"], limit: 60) }
                seen = []
                var actions: [NativeRPCValue] = []
                for action in try list(card["actions"], "card.actions", 4) {
                    try PluginContract.closed(action, ["id", "title", "kind", "target"], "card.actions")
                    guard seen.insert(try PluginContract.key(action["id"])).inserted else { throw refusal("card.actions repeats an id") }
                    _ = try PluginContract.text(action["title"], limit: 60)
                    let target = try PluginContract.key(action["target"])
                    guard action["kind"].string == "job" && jobs.contains(where: { $0["id"].string == target }) || action["kind"].string == "tool" && tools.contains(where: { $0.name == target }) else { throw refusal("card.actions must name a declared job or tool") }
                    let targetSchema = action["kind"].string == "job" ? jobs.first { $0["id"].string == target }!["inputSchema"] : tools.first { $0.name == target }!.inputSchema
                    try actionSchema(targetSchema)
                    let tier = action["kind"].string == "job" ? "act" : tools.first { $0.name == target }!.tier
                    actions.append(action.setting("inputSchema", targetSchema).setting("tier", .string(tier)))
                }
                cards.append(card.setting("actions", .array(actions)))
            }
        }
        for event in try (block.has("events") ? list(block["events"], "plugin.events", 1) : []) {
            try PluginContract.closed(event, ["type", "job", "input"], "plugin.events")
            guard event["type"].string == "tasks.finished", jobs.contains(where: { $0["id"] == event["job"] }) else { throw refusal("plugin.events supports tasks.finished and a declared job only") }
            let job = jobs.first { $0["id"] == event["job"] }!
            try BackendDeckCoreCatalogueSchema.check(tool: .init(id: "plugin.event", wireName: "plugin_event", description: "Event input", inputSchema: job["inputSchema"], tier: .act), arguments: event["input"])
            events.append(event)
        }
        guard jobs.isEmpty || capabilities.contains("jobs.run"), cards.isEmpty || capabilities.contains("ui.contribute"), events.isEmpty || capabilities.contains("events.receive") && capabilities.contains("tasks.read") && capabilities.contains("jobs.run") else { throw refusal("plugin.ui/jobs/events need their matching capabilities") }
        guard !capabilities.contains("jobs.run") || !jobs.isEmpty, !capabilities.contains("ui.contribute") || !cards.isEmpty, !capabilities.contains("events.receive") || !events.isEmpty else { throw refusal("extension capabilities need corresponding declarations") }
        return jobs.isEmpty && cards.isEmpty && events.isEmpty ? .null : .object([.init("jobs", .array(jobs)), .init("cards", .array(cards)), .init("events", .array(events))])
    }
    private static func actionSchema(_ value: NativeRPCValue) throws {
        try schema(value, "job.inputSchema", 0)
        guard value["type"].string == "object", value["additionalProperties"].bool == false,
              let fields = value["properties"].fields, fields.count <= 8 else { throw refusal("job.inputSchema needs a closed object with at most eight scalar fields") }
        for field in fields {
            _ = try PluginContract.key(.string(field.key))
            guard ["string", "boolean", "number", "integer"].contains(field.value["type"].string ?? ""), field.value["properties"].isNullish, field.value["items"].isNullish else { throw refusal("job inputs support scalar fields only") }
        }
    }
}
