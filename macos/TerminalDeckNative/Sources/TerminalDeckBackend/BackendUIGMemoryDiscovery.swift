import Foundation
import TerminalDeckNativeCore

/// Discovery projection for the paused Memory page. Keep the original metadata,
/// policy, handler, grants and caller checks in the real catalogue and dispatcher.
/// This helper neither mints permissions nor dispatches a tool.
public enum BackendUIGMemoryDiscovery {
    public static func showsTool(_ tool: BackendMCPTool) -> Bool {
        UIGMemoryVisibility.showsTool(id: tool.id, wireName: tool.wireName)
    }

    public static func tools(_ tools: [BackendMCPTool]) -> [BackendMCPTool] {
        tools.filter(showsTool)
    }

    public static func metadata(_ rows: [BackendDeckCoreCatalogueMetadata]) -> [BackendDeckCoreCatalogueMetadata] {
        rows.filter { showsTool($0.tool) }
    }

    public static func wireListing(metadata rows: [BackendDeckCoreCatalogueMetadata],
                                   caller: BackendDeckCoreSecurityCaller,
                                   granted: Set<String>?) throws -> [NativeRPCValue] {
        try BackendDeckCoreCatalogueDescribe.wireListing(metadata: metadata(rows), caller: caller, granted: granted)
    }

    /// Filters before existing alias resolution and caller/grant checks. Even an
    /// explicit request for a hidden alias receives the normal unknown response.
    public static func describe(_ arguments: NativeRPCValue,
                                catalogue: [BackendDeckCoreCatalogueMetadata],
                                granted: Set<String>?,
                                caller: BackendDeckCoreSecurityCaller) throws -> BackendDeckCoreSecurityToolOutput {
        try BackendDeckCoreCatalogueDescribe.answer(arguments, catalogue: metadata(catalogue), granted: granted, caller: caller)
    }

    public static func coverageAreas(_ names: [String]) -> [String] {
        names.filter { $0 != "memory" }
    }

    public static func coverageRows(_ rows: [BackendDeckCoreCatalogueCoverageRow]) -> [BackendDeckCoreCatalogueCoverageRow] {
        rows.compactMap { row in
            guard row.area != "memory", !row.action.hasPrefix("memory:") else { return nil }
            guard let tools = row.tools else { return row }
            let kept = tools.filter { !UIGMemoryVisibility.isMemoryToolName($0) }
            // An unrelated action may have more than one matching tool. Retire
            // only its Memory contribution, never the other real capability.
            guard !kept.isEmpty || tools.isEmpty else { return nil }
            return .init(area: row.area, action: row.action, tools: kept, skip: row.skip)
        }
    }

    /// ui.list can offer commands independently of tools/list. Keep its sessions,
    /// settings sections and all other fields byte-for-byte as supplied.
    public static func uiListing(_ listing: NativeRPCValue) -> NativeRPCValue {
        guard let commands = listing["commands"].elements else { return listing }
        return listing.setting("commands", .array(commands.filter { command in
            guard let id = command["id"].string else { return true }
            return UIGMemoryVisibility.showsCommand(id)
        }))
    }
}
