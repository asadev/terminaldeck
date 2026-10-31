import Foundation
import TerminalDeckNativeCore

/// A sink for existing opt-in events; never opens a stream or probes a server.
public enum BackendDockerMCPReceiver {
    public static func docker(_ value: NativeRPCValue) {
        guard let event = dockerEvent(value) else { return }
        deliver(event)
    }
    public static func apps(channel: String, value: NativeRPCValue) {
        guard channel == "apps:deployment", value["phase"].string == "failed",
              let server = value["serverId"].string, let app = value["appId"].string else { return }
        let name = safe(app)
        deliver(.init(kind: "apps.deploy.failed", severity: .error,
            title: "\(name) deploy failed", text: "The deploy did not finish. Check the app's saved deploys.",
            fields: ["server": safe(server), "app": name],
            id: "deploy:\(server):\(app):\(value["deploymentId"].string ?? UUID().uuidString)"))
    }
    public static func dockerEvent(_ value: NativeRPCValue) -> BackendRCVInternalEvent? {
        guard value["type"].string == "container", let action = value["action"].string,
              let id = value["id"].string, !id.isEmpty else { return nil }
        let unhealthy = action == "health_status: unhealthy" || action == "health_status:unhealthy"
        guard unhealthy || action == "die" || action == "oom" else { return nil }
        let attributes = value["attributes"]
        let name = safe(attributes["name"].string ?? String(id.prefix(12)))
        var fields = ["container": name, "server": safe(value["target"].string ?? "local")]
        if let app = attributes["io.terminaldeck.app"].string { fields["app"] = safe(app) }
        let stamp = value["timeNano"].number ?? value["time"].number ?? 0
        return .init(kind: unhealthy ? "docker.container.unhealthy" : "docker.container.died", severity: .error,
            title: "\(name) \(unhealthy ? "is unhealthy" : "stopped")",
            text: unhealthy ? "The service failed its health check. Open Advanced to inspect it." : "The service stopped. Open Advanced to inspect its logs.",
            fields: fields, id: "docker:\(id):\(stamp):\(action)")
    }
    private static func safe(_ value: String) -> String { BackendDockerMCPMasker.text(String(value.prefix(160))) }
    private static func deliver(_ event: BackendRCVInternalEvent) {
        Task(priority: .utility) { await BackendRCVFeed.shared.postIfAvailable("terminaldeck.servers", event) }
    }
}
