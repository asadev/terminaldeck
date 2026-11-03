import Foundation
import TerminalDeckNativeCore

/// Absence of a fact means unasked. `no` means measured absence; `cannot`
/// always carries the reason to display instead of a zero or empty card.
public enum BackendServersFact<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case yes(T, measuredAt: Double, how: String)
    case no(measuredAt: Double, how: String)
    case cannot(measuredAt: Double, why: String)
    private enum Keys: String, CodingKey { case known, value, measuredAt, how, why }
    public var known: String { switch self { case .yes: "yes"; case .no: "no"; case .cannot: "cannot" } }
    public var value: T? { if case .yes(let value, _, _) = self { return value }; return nil }
    public var measuredAt: Double { switch self { case .yes(_, let at, _), .no(let at, _), .cannot(let at, _): at } }
    public var how: String? { switch self { case .yes(_, _, let how), .no(_, let how): how; case .cannot: nil } }
    public var why: String? { if case .cannot(_, let why) = self { return why }; return nil }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let at = try c.decode(Double.self, forKey: .measuredAt)
        switch try c.decode(String.self, forKey: .known) {
        case "yes": self = .yes(try c.decode(T.self, forKey: .value), measuredAt: at, how: try c.decode(String.self, forKey: .how))
        case "no": self = .no(measuredAt: at, how: try c.decode(String.self, forKey: .how))
        case "cannot": self = .cannot(measuredAt: at, why: try c.decode(String.self, forKey: .why))
        default: throw DecodingError.dataCorruptedError(forKey: .known, in: c, debugDescription: "Unknown fact state")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(known, forKey: .known); try c.encode(measuredAt, forKey: .measuredAt)
        switch self {
        case .yes(let value, _, let how): try c.encode(value, forKey: .value); try c.encode(how, forKey: .how)
        case .no(_, let how): try c.encode(how, forKey: .how)
        case .cannot(_, let why): try c.encode(why, forKey: .why)
        }
    }
}

public enum BackendServersInitSystem: String, Codable, Sendable { case systemd, openrc, launchd, sysvinit; case containerNone = "container-none" }
public enum BackendServersContainerRuntime: String, Codable, Sendable { case docker, podman }
public enum BackendServersPrivilege: String, Codable, Sendable { case yes, no; case sudoNoPassword = "sudo-nopasswd", sudoPassword = "sudo-password" }
public enum BackendServersRunState: String, Codable, Sendable { case running, stopped, failed, unknown }
public enum BackendServersAgentID: String, Codable, Sendable, CaseIterable { case claude, codex, gemini }
public enum BackendServersSigninState: String, Codable, Sendable { case yes, no, unknown }

public struct BackendServersServiceFact: Codable, Equatable, Sendable {
    public var name: String; public var state: BackendServersRunState; public var description: String; public var addedHere: Bool
    public init(name: String, state: BackendServersRunState, description: String = "", addedHere: Bool = false) { self.name = name; self.state = state; self.description = description; self.addedHere = addedHere }
}
public struct BackendServersContainerFact: Codable, Equatable, Sendable {
    public var name: String; public var image: String; public var state: BackendServersRunState; public var status: String; public var ports: String
    public init(name: String, image: String, state: BackendServersRunState, status: String = "", ports: String = "") { self.name = name; self.image = image; self.state = state; self.status = status; self.ports = ports }
}
public struct BackendServersListenerFact: Codable, Equatable, Sendable {
    public var address: String; public var port: Int; public var program: String; public var pid: Int?; public var unit: String
    public init(address: String, port: Int, program: String = "", pid: Int? = nil, unit: String = "") { self.address = address; self.port = port; self.program = program; self.pid = pid; self.unit = unit }
}
public struct BackendServersAgentFact: Codable, Equatable, Sendable {
    public var id: BackendServersAgentID; public var path: String; public var version: String; public var signedIn: BackendServersSigninState; public var account: String?
    public init(id: BackendServersAgentID, path: String, version: String, signedIn: BackendServersSigninState = .unknown, account: String? = nil) { self.id = id; self.path = path; self.version = version; self.signedIn = signedIn; self.account = account }
}
public struct BackendServersAgentInstallRoom: Codable, Equatable, Sendable {
    public var downloader: String; public var npm: String; public var memoryAvailableKb: Double?; public var homeFreeKb: Double?
    public init(downloader: String, npm: String = "", memoryAvailableKb: Double? = nil, homeFreeKb: Double? = nil) { self.downloader = downloader; self.npm = npm; self.memoryAvailableKb = memoryAvailableKb; self.homeFreeKb = homeFreeKb }
}
public struct BackendServersDiskFact: Codable, Equatable, Sendable { public var usedKb: Double; public var totalKb: Double }
public struct BackendServersMemoryFact: Codable, Equatable, Sendable { public var totalKb: Double; public var freeKb: Double }

public struct BackendServersFacts: Codable, Equatable, Sendable {
    public var serverId: String; public var measuredAt: Double
    public var os: BackendServersFact<String>; public var kernel: BackendServersFact<String>; public var arch: BackendServersFact<String>
    public var hostname: BackendServersFact<String>; public var user: BackendServersFact<String>
    public var privilege: BackendServersFact<BackendServersPrivilege>; public var `init`: BackendServersFact<BackendServersInitSystem>
    public var containerRuntime: BackendServersFact<BackendServersContainerRuntime>
    public var packageManager: BackendServersFact<String>; public var webServer: BackendServersFact<String>
    public var cpus: BackendServersFact<Double>; public var disk: BackendServersFact<BackendServersDiskFact>; public var memory: BackendServersFact<BackendServersMemoryFact>
    public var load1: BackendServersFact<Double>; public var uptimeSeconds: BackendServersFact<Double>
    public var services: BackendServersFact<[BackendServersServiceFact]>; public var containers: BackendServersFact<[BackendServersContainerFact]>
    public var listeners: BackendServersFact<[BackendServersListenerFact]>; public var siteNames: BackendServersFact<[String]>
    public var agents: BackendServersFact<[BackendServersAgentFact]>; public var agentInstall: BackendServersFact<BackendServersAgentInstallRoom>
    public init(serverId: String, measuredAt: Double, why: String = "This check did not run.") {
        self.serverId = serverId; self.measuredAt = measuredAt
        os = .cannot(measuredAt: measuredAt, why: why); kernel = os; arch = os; hostname = os; user = os; packageManager = os; webServer = os
        privilege = .cannot(measuredAt: measuredAt, why: why); self.`init` = .cannot(measuredAt: measuredAt, why: why)
        containerRuntime = .cannot(measuredAt: measuredAt, why: why); cpus = .cannot(measuredAt: measuredAt, why: why)
        disk = .cannot(measuredAt: measuredAt, why: why); memory = .cannot(measuredAt: measuredAt, why: why); load1 = cpus; uptimeSeconds = cpus
        services = .cannot(measuredAt: measuredAt, why: why); containers = .cannot(measuredAt: measuredAt, why: why)
        listeners = .cannot(measuredAt: measuredAt, why: why); siteNames = .cannot(measuredAt: measuredAt, why: why)
        agents = .cannot(measuredAt: measuredAt, why: why); agentInstall = .cannot(measuredAt: measuredAt, why: why)
    }
    public var actionFacts: BackendServersActionFacts { .init(privilege: privilege, initSystem: self.`init`, containerRuntime: containerRuntime) }
    public var numbersBelongToTheHost: Bool { self.`init`.value == .containerNone }
    public static let containerNumbersWhy = "This is running inside a container, so these numbers would be the host computer's rather than this one's."
    public static let containerInheritedFacts = ["disk", "memory", "load1", "uptimeSeconds"]
    public func wireValue() throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(self)) }
}

public struct BackendServersActionFacts: Codable, Equatable, Sendable {
    public var privilege: BackendServersFact<BackendServersPrivilege>; public var `init`: BackendServersFact<BackendServersInitSystem>; public var containerRuntime: BackendServersFact<BackendServersContainerRuntime>
    public init(privilege: BackendServersFact<BackendServersPrivilege>, initSystem: BackendServersFact<BackendServersInitSystem>, containerRuntime: BackendServersFact<BackendServersContainerRuntime>) { self.privilege = privilege; self.`init` = initSystem; self.containerRuntime = containerRuntime }
}
