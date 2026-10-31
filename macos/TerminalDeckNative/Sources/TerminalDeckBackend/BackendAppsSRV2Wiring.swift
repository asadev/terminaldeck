import Foundation
import TerminalDeckNativeCore

/// SRV2 wiring helpers for INT2 (in-module: they build the existing engine's
/// action type so SRV2 writes reuse the ONE approval + recovery path).
extension BackendAppsSRV2Channels {
    /// Adapts the composition's existing Apps authorizer (approval + recovery
    /// record) to SRV2's channels. Previews never carry values or passwords.
    public static func authorize(using existing: @escaping BackendAppsChannels.Authorize) -> Authorize {
        { action, context in
            try await existing(BackendAppsAction(channel: action.channel, serverID: action.serverID, appID: action.appID,
                                                 destructive: false, confirmation: nil, preview: action.preview), context)
        }
    }

    /// Every SRV2 channel name, for the composition's `invokes:` set and the recovery authority.
    public static var invokeChannels: Set<String> { readChannels.union(allWriteChannels) }

    /// Removes the redirect route SRV2 adds next to an app's main route (the
    /// main route id is the existing engine's, removed by apps:remove). Safe to
    /// call after apps:remove: it needs only the address manager, not the app folder.
    public func removeExtraRoutes(serverID: String, appID: String) async {
        guard let app = try? BackendAppsValidation.id(appID), let facts = try? await deployer.resolvedFacts(serverID, nil),
              facts.mode == .caddy || facts.mode == .ownCaddy, let admin = facts.caddyAdmin,
              admin.range(of: #"^[A-Za-z0-9.:\[\]-]+$"#, options: .regularExpression) != nil else { return }
        let id = runtime.resourcePrefix + "-" + app + "-redirect"
        let url = BackendAppsRuntime.quote("http://" + admin + "/id/" + id)
        _ = try? await runtime.run(serverID, "code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 \(url)); [ \"$code\" = 200 ] || exit 0; curl -s --noproxy '*' -o /dev/null --max-time 10 -X DELETE \(url)", timeoutMS: 30_000, maximumBytes: 4096)
    }

    /// Server-started deploys (pushes, deploy links, Deploy on the server) run only the
    /// app's recipe, so they are prepared by writing it, also for an app the Mac never
    /// deployed. Apps the server can't deploy (not GitHub, or Compose) are left alone.
    public func prepareServerDeploys(serverID: String, appID: String) async throws {
        let store = self.store, deployer = self.deployer
        try await store.withLock(serverID, appID) {
            let record = try await store.read(serverID, appID)
            guard record["kind"].string == "app", record["source"]["kind"].string == "github", record["source"]["build"].string != "compose" else { return }
            _ = try await deployer.writeRecipe(serverID, appID, record: record)
        }
    }
}

extension BackendAppsSRV2MCP {
    /// The catalogue rows INT2 appends to BackendAppsMCP.definitions().
    public static func definitions() -> [BackendAppsMCPCatalogue.Definition] {
        specs().map { BackendAppsMCPCatalogue.Definition(id: $0.id, channel: $0.channel, tier: $0.write ? .alter : .read, description: $0.description,
                                                         properties: $0.properties, required: $0.required, destructive: false) }
    }
}

extension BackendAppsSRV2Channels {
    /// ONE router detection: SRV1's server probe, used by SRV2 only when the
    /// shared <stateRoot>/router.json is missing (it never writes the record).
    public static func srv1RouterProbe(runtime: BackendAppsRuntime) -> BackendAppsSRV2Deployer.RouterProbe {
        { serverID in
            let layout = try BackendAppsServerLayout(runtime: runtime)
            let result = try await runtime.run(serverID, BackendAppsServerProbe.script(layout), timeoutMS: 30_000, maximumBytes: 2_000_000)
            guard result.code == 0, !result.truncated else { return nil }
            let facts = BackendAppsServerProbe.parse(result.stdout)
            // Before setup, "nothing on 80/443" is not yet our Caddy.
            if facts.router == BackendAppsServerRouter.none { return .init(mode: .free, owner: "Nothing yet") }
            return BackendAppsSRV2Router.record(try BackendAppsServerSetup.routerRecord(facts))
        }
    }
}
