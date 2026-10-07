import Foundation

public struct BackendServersComposeRef: Codable, Equatable, Sendable {
    public var project: String; public var service: String; public var workingDir: String
    public init(project: String, service: String, workingDir: String = "") { self.project = project; self.service = service; self.workingDir = workingDir }
}
public enum BackendServersManagedBy: Codable, Equatable, Sendable {
    case systemd(unit: String)
    case openrc(service: String)
    case container(runtime: BackendServersContainerRuntime, name: String, compose: BackendServersComposeRef?)
    private enum Keys: String, CodingKey { case kind, unit, service, runtime, name, compose }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "systemd": self = .systemd(unit: try c.decode(String.self, forKey: .unit))
        case "openrc": self = .openrc(service: try c.decode(String.self, forKey: .service))
        case "container": self = .container(runtime: try c.decode(BackendServersContainerRuntime.self, forKey: .runtime), name: try c.decode(String.self, forKey: .name), compose: try c.decodeIfPresent(BackendServersComposeRef.self, forKey: .compose))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown manager")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .systemd(let unit): try c.encode("systemd", forKey: .kind); try c.encode(unit, forKey: .unit)
        case .openrc(let service): try c.encode("openrc", forKey: .kind); try c.encode(service, forKey: .service)
        case .container(let runtime, let name, let compose): try c.encode("container", forKey: .kind); try c.encode(runtime, forKey: .runtime); try c.encode(name, forKey: .name); try c.encode(compose, forKey: .compose)
        }
    }
    public var runtime: BackendServersContainerRuntime? { if case .container(let runtime, _, _) = self { return runtime }; return nil }
    public var compose: BackendServersComposeRef? { if case .container(_, _, let compose) = self { return compose }; return nil }
}
public enum BackendServersKnownEngine: String, Codable, Sendable { case postgres, mysql, mariadb, mongo, redis, elasticsearch, clickhouse }
public enum BackendServersCardKind: String, Codable, Sendable, CaseIterable { case site, app, database, other }
public struct BackendServersCard: Codable, Equatable, Sendable {
    public var id: String; public var kind: BackendServersCardKind; public var name: String; public var detail: String
    public var running: Bool?; public var managedBy: BackendServersManagedBy?; public var url: String?; public var engine: BackendServersKnownEngine?; public var repoDir: String?
    public init(id: String, kind: BackendServersCardKind, name: String, detail: String = "", running: Bool? = nil, managedBy: BackendServersManagedBy? = nil, url: String? = nil, engine: BackendServersKnownEngine? = nil, repoDir: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.detail = detail; self.running = running; self.managedBy = managedBy; self.url = url; self.engine = engine; self.repoDir = repoDir
    }
}
public struct BackendServersWayBackSurvey: Codable, Equatable, Sendable {
    public var compose: [String: BackendServersComposeRef] = [:]; public var repos: [String: String] = [:]; public var compose_available = false
    public init() {}
    public var composeAvailable: Bool { compose_available }
}
public struct BackendServersCannot: Codable, Equatable, Sendable { public var what: String; public var why: String }

public enum BackendServersClassify {
    public static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    public static func isSafePath(_ path: String) -> Bool { !path.isEmpty && path.utf16.count <= 4096 && matches(path, #"^/[A-Za-z0-9_./@+:-]*\z"#) }
    public static func isSafeName(_ name: String) -> Bool { !name.isEmpty && name.utf16.count <= 256 && matches(name, #"^[A-Za-z0-9_.@+:/-]+\z"#) }
    public static func engineOf(_ text: String) -> BackendServersKnownEngine? {
        let patterns: [(String, BackendServersKnownEngine)] = [
            (#"(?i)(^|[^a-z])(postgres|postgresql|pgsql|timescale)([^a-z]|$)"#, .postgres),
            (#"(?i)(^|[^a-z])mariadb([^a-z]|$)"#, .mariadb), (#"(?i)(^|[^a-z])(mysql|percona)([^a-z]|$)"#, .mysql),
            (#"(?i)(^|[^a-z])mongo(db)?([^a-z]|$)"#, .mongo), (#"(?i)(^|[^a-z])(redis|valkey)([^a-z]|$)"#, .redis),
            (#"(?i)(^|[^a-z])(elasticsearch|opensearch)([^a-z]|$)"#, .elasticsearch), (#"(?i)(^|[^a-z])clickhouse([^a-z]|$)"#, .clickhouse)]
        return patterns.first { matches(text, $0.0) }?.1
    }
    public static func waybackScript(_ facts: BackendServersFacts) -> String {
        let runtime = facts.containerRuntime.value?.rawValue
        var parts = ["LC_ALL=C", "export LC_ALL", ###"printf "##compose-available\n""###]
        if let runtime { parts.append("\(runtime) compose version >/dev/null 2>&1 && printf \"yes\\n\" || printf \"no\\n\"") }
        parts.append(###"printf "##compose\n""###)
        if let runtime { parts.append("\(runtime) ps -a --no-trunc --format '{{.Names}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}' 2>/dev/null | head -n 200 || :") }
        parts.append(###"printf "##repos\n""###)
        if facts.`init`.value == .systemd {
            let named = Array((facts.services.value ?? []).filter { $0.addedHere && isSafeName($0.name) }.map(\.name).prefix(100))
            if !named.isEmpty {
                parts += ["command -v git >/dev/null 2>&1 || exit 0", "for u in \(named.map { "'\($0)'" }.joined(separator: " ")); do",
                    #"  d=$(systemctl show -p WorkingDirectory --value "$u" 2>/dev/null)"#, #"  [ -n "$d" ] || continue"#,
                    #"  t=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || continue"#, #"  printf "%s\t%s\n" "$u" "$t""#, "done"]
            }
        }
        return parts.joined(separator: "\n")
    }
    public static func parseSurvey(_ stdout: String) -> BackendServersWayBackSurvey {
        var survey = BackendServersWayBackSurvey(); var section = ""
        for line in stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if matches(trimmed, #"^##[a-z-]+$"#) { section = String(trimmed.dropFirst(2)); continue }
            if trimmed.isEmpty { continue }
            if section == "compose-available" { if trimmed == "yes" { survey.compose_available = true }; continue }
            let c = line.components(separatedBy: "\t")
            if section == "compose" {
                guard c.count >= 3, !c[1].isEmpty, !c[2].isEmpty, c.prefix(3).allSatisfy(isSafeName) else { continue }
                let dir = c.count > 3 ? c[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                guard dir.isEmpty || isSafePath(dir) else { continue }
                survey.compose[c[0].trimmingCharacters(in: .whitespacesAndNewlines)] = .init(project: c[1].trimmingCharacters(in: .whitespacesAndNewlines), service: c[2].trimmingCharacters(in: .whitespacesAndNewlines), workingDir: dir)
            } else if section == "repos" {
                guard c.count >= 2 else { continue }
                let unit = c[0].trimmingCharacters(in: .whitespacesAndNewlines), dir = c[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if isSafeName(unit) && isSafePath(dir) { survey.repos[unit] = dir }
            }
        }
        return survey
    }
    public static func friendlyServiceName(_ name: String) -> String { name.hasSuffix(".service") ? String(name.dropLast(8)) : name }
    public static func siteURL(_ host: String, listeners: [BackendServersListenerFact]) -> String? {
        guard !host.isEmpty, !host.contains("*"), matches(host, #"^[A-Za-z0-9.-]+\z"#) else { return nil }
        if listeners.contains(where: { $0.port == 443 }) { return "https://\(host)" }
        if listeners.contains(where: { $0.port == 80 }) { return "http://\(host)" }
        return nil
    }
    private static func running(_ state: BackendServersRunState) -> Bool? { state == .unknown ? nil : state == .running }
    public static func classify(_ facts: BackendServersFacts, survey: BackendServersWayBackSurvey = .init()) -> [BackendServersCard] {
        var cards: [BackendServersCard] = []; let listeners = facts.listeners.value ?? []
        for host in facts.siteNames.value ?? [] {
            cards.append(.init(id: "site:\(host)", kind: .site, name: host, detail: facts.webServer.value.map { "Served by \($0)" } ?? "Found in this server’s web settings", url: siteURL(host, listeners: listeners)))
        }
        for service in facts.services.value ?? [] {
            let engine = engineOf(service.name); let listed = service.addedHere || engine != nil
            if !listed && service.state != .running && service.state != .failed { continue }
            let name = friendlyServiceName(service.name); var manager: BackendServersManagedBy?
            if isSafeName(service.name) {
                if facts.`init`.value == .systemd { manager = .systemd(unit: service.name) }
                else if facts.`init`.value == .openrc { manager = .openrc(service: service.name) }
            }
            let listens = listeners.contains { !$0.unit.isEmpty && $0.unit == service.name }
            let kind: BackendServersCardKind = !listed ? .other : engine != nil && listens ? .database : .app
            cards.append(.init(id: "service:\(service.name)", kind: kind, name: name, detail: !service.description.isEmpty && service.description != name ? service.description : "Kept running by this server", running: running(service.state), managedBy: manager, engine: engine, repoDir: survey.repos[service.name]))
        }
        for container in facts.containers.value ?? [] {
            guard let runtime = facts.containerRuntime.value, isSafeName(container.name) else { continue }
            let compose = survey.compose[container.name]; let engine = engineOf("\(container.image) \(container.name)")
            cards.append(.init(id: "container:\(container.name)", kind: engine == nil ? .app : .database, name: compose?.service ?? container.name, detail: "Running in a container from \(container.image)", running: running(container.state), managedBy: .container(runtime: runtime, name: container.name, compose: compose), engine: engine, repoDir: compose != nil && compose?.workingDir != "" ? survey.repos[container.name] : nil))
        }
        let order: [BackendServersCardKind: Int] = [.site: 0, .app: 1, .database: 2, .other: 3]
        return cards.enumerated().sorted { a, b in
            let difference = (order[a.element.kind] ?? 0) - (order[b.element.kind] ?? 0)
            if difference != 0 { return difference < 0 }
            let result = a.element.name.localizedCompare(b.element.name)
            return result == .orderedSame ? a.offset < b.offset : result == .orderedAscending
        }.map(\.element)
    }
    public static func howOf(_ f: BackendServersFacts) -> [String] {
        let candidates = [(f.services.known, f.services.how), (f.containers.known, f.containers.how), (f.listeners.known, f.listeners.how), (f.siteNames.known, f.siteNames.how)]
        var out: [String] = []; for (known, how) in candidates { if known == "yes", let how, !out.contains(how) { out.append(how) } }; return out
    }
    public static func cannotOf(_ f: BackendServersFacts) -> [BackendServersCannot] {
        [("the things this server keeps running", f.services.why), ("anything running in a container", f.containers.why), ("what is accepting connections", f.listeners.why), ("the addresses this server answers on", f.siteNames.why)].compactMap { what, why in why.map { .init(what: what, why: $0) } }
    }
}
