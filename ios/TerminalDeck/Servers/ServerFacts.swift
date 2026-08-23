/**
 * What this phone believes about one server, and the grounds for believing it —
 * the phone's half of `src/main/servers/facts.ts` and `probe.sh.ts`.
 *
 * ## Three states, not two
 *
 * The rule this file exists for is Asad's, set while looking at a design drawn
 * around one machine: *"Make sure we don't design it as per our design, it's
 * gonna be used for all so they might have different settings, we need something
 * common."*
 *
 * A two-state model — found it, did not — collapses two different answers onto
 * the same empty card. *"There is no web server on this server"* is a fact about
 * the machine. *"This sign-in is not allowed to ask"* is a fact about the
 * account, and the thing to do about it is different. So every fact is `yes`,
 * `no`, or **`cannot`**, and `cannot` carries its own reason and is drawn *in
 * place of* the value. Never a dash, never a zero: a dash reads as zero, and
 * that is the moment a card starts lying about somebody's server.
 *
 * ## What is ported and what is not
 *
 * The scalars, and the three lists that answer *"what's running, what's not"* —
 * services, containers, and what is listening — plus the site names the web
 * server's own settings give up. What is **not** here is the desktop's
 * `classify.ts`, which sorts those rows into sites, apps and databases; the
 * phone shows the rows the server gave, under the server's own words for them.
 * That is a smaller claim than the desktop makes, and a true one.
 */

import Foundation

/// One thing measured about a server, in the only three states it can honestly be in.
enum Fact<Value: Equatable>: Equatable {
    /// Measured, and this is what it said. `how` names the check that ran.
    case yes(Value, how: String)
    /// Measured, and there is none. Not the same as not having asked.
    case no(how: String)
    /// Could not be asked, or the server would not answer. `why` is shown instead.
    case cannot(why: String)

    var value: Value? {
        if case let .yes(value, _) = self { return value }
        return nil
    }

    /// The sentence a card shows where the value would have been, or nil.
    var refusal: String? {
        if case let .cannot(why) = self { return why }
        return nil
    }
}

struct DiskFact: Equatable {
    let usedKb: Int
    let totalKb: Int
}

struct MemoryFact: Equatable {
    let totalKb: Int
    let freeKb: Int
}

struct ServiceFact: Equatable, Identifiable {
    let name: String
    /// `active`, `inactive`, `failed` — the server's own word.
    let state: String
    let detail: String
    var id: String { name }
    var isRunning: Bool { state == "active" || state == "running" || state == "started" }
}

struct ContainerFact: Equatable, Identifiable {
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: String
    var id: String { name }
    var isRunning: Bool { state == "running" || status.lowercased().hasPrefix("up") }
}

struct ListenerFact: Equatable, Identifiable {
    let address: String
    let port: String
    /// The program holding it, when the server would say. Often empty for a
    /// sign-in that is not root, which is a fact about the account.
    let program: String
    let unit: String
    var id: String { "\(address):\(port)/\(program)" }
}

/// Everything one round trip measured, with the moment it was measured.
struct ServerFacts: Equatable {
    var measuredAt: Date
    var os: Fact<String>
    var kernel: Fact<String>
    var arch: Fact<String>
    var hostname: Fact<String>
    var user: Fact<String>
    /// `yes`, `sudo-nopasswd`, `sudo-password` or `no` — the server's own word.
    var privilege: Fact<String>
    var initSystem: Fact<String>
    var containerRuntime: Fact<String>
    var packageManager: Fact<String>
    var webServer: Fact<String>
    var cpus: Fact<Int>
    var disk: Fact<DiskFact>
    var memory: Fact<MemoryFact>
    var load1: Fact<Double>
    var uptimeSeconds: Fact<Int>
    var services: Fact<[ServiceFact]>
    var containers: Fact<[ContainerFact]>
    var listeners: Fact<[ListenerFact]>
    var siteNames: Fact<[String]>
}

enum ServerProbe {

    /// What each check is called, in words a person can read. `facts.ts`'s table.
    private enum How {
        static let identity = "asked the server what it is"
        static let privilege = "asked what this sign-in is allowed to do"
        static let initSystem = "looked for how this server starts and stops things"
        static let containers = "asked whether this server runs containers"
        static let packages = "looked for how software is installed here"
        static let web = "looked for a web server"
        static let resources = "asked how much room and memory it has"
        static let services = "asked what it is set up to keep running"
        static let listeners = "asked what is listening"
        static let sites = "read the web server's own settings"
    }

    /// Only reachable when `#end ok` is missing: the far end stopped partway.
    private static let cutOff = "The server stopped answering before it finished this check."
    /// A section that should have been in the output of a script that ran to the end.
    private static let neverAsked = "This check did not run."

    private struct Section {
        var state = ""
        var reason = ""
        var rows: [String] = []
    }

    private struct Parsed {
        var scalars: [String: String] = [:]
        var sections: [String: Section] = [:]
        var finished = false
    }

    /**
     * Split the raw output into scalars and sections without interpreting any of
     * it.
     *
     * Deliberately forgiving: a line that is neither `key=value` nor a section
     * header is dropped rather than treated as an error. Servers print things
     * nobody asked for — a login banner, an MOTD, `stdin: is not a tty` — and
     * refusing to parse because of one is refusing to work on a machine that is
     * fine.
     */
    private static func split(_ stdout: String) -> Parsed {
        var parsed = Parsed()
        var current: String?
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("#") {
                let rest = line.dropFirst()
                let pieces = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                let name = pieces.count > 0 ? String(pieces[0]) : ""
                if name == "end" {
                    parsed.finished = true
                    current = nil
                    continue
                }
                var section = Section()
                section.state = pieces.count > 1 ? String(pieces[1]) : ""
                section.reason = pieces.count > 2 ? String(pieces[2]) : ""
                parsed.sections[name] = section
                current = name
                continue
            }
            if let name = current {
                if !line.isEmpty { parsed.sections[name]?.rows.append(line) }
                continue
            }
            if let equals = line.firstIndex(of: "="), equals != line.startIndex {
                parsed.scalars[String(line[line.startIndex..<equals])] =
                    String(line[line.index(after: equals)...])
            }
        }
        return parsed
    }

    /* ------------------------------------------------------------ reading -- */

    static func read(_ stdout: String, at measuredAt: Date = Date()) -> ServerFacts {
        let parsed = split(stdout)

        func text(_ key: String, _ how: String, _ why: String) -> Fact<String> {
            let value = parsed.scalars[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? .cannot(why: why) : .yes(value, how: how)
        }
        func whole(_ key: String, _ how: String, _ why: String) -> Fact<Int> {
            let value = parsed.scalars[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let number = Int(value) else { return .cannot(why: why) }
            return .yes(number, how: how)
        }
        func decimal(_ key: String, _ how: String, _ why: String) -> Fact<Double> {
            let value = parsed.scalars[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let number = Double(value) else { return .cannot(why: why) }
            return .yes(number, how: how)
        }
        func pair(_ first: String, _ second: String) -> (Int, Int)? {
            guard let a = Int(parsed.scalars[first]?.trimmingCharacters(in: .whitespaces) ?? ""),
                  let b = Int(parsed.scalars[second]?.trimmingCharacters(in: .whitespaces) ?? "")
            else { return nil }
            return (a, b)
        }
        func rows<T: Equatable>(_ name: String,
                                _ how: String,
                                _ build: ([String]) -> [T]) -> Fact<[T]> {
            guard let section = parsed.sections[name] else {
                return .cannot(why: parsed.finished ? neverAsked : cutOff)
            }
            if section.state == "cannot" {
                return .cannot(why: sentence(section.reason))
            }
            if section.state == "none" { return .no(how: how) }
            return .yes(build(section.rows), how: how)
        }

        let noAnswer = "This server did not answer that."

        let containerRuntimeRaw = parsed.scalars["containers"] ?? ""
        let containerRuntime: Fact<String>
        switch containerRuntimeRaw {
        case "docker", "podman":
            containerRuntime = .yes(containerRuntimeRaw, how: How.containers)
        case "none":
            containerRuntime = .no(how: How.containers)
        case "present-no-permission":
            containerRuntime = .cannot(
                why: "This sign-in is not allowed to ask this server about its containers.")
        default:
            containerRuntime = .cannot(why: "We could not tell whether this server runs containers.")
        }

        // Present-and-empty and absent-entirely are different answers. The
        // script prints `web=` unconditionally, so an empty value means it
        // looked and found none — a fact about the machine, which is `no`.
        let webRaw = parsed.scalars["web"]
        let webServer: Fact<String>
        if webRaw == nil {
            webServer = .cannot(why: parsed.finished ? neverAsked : cutOff)
        } else if webRaw!.trimmingCharacters(in: .whitespaces).isEmpty {
            webServer = .no(how: How.web)
        } else {
            webServer = .yes(webRaw!.trimmingCharacters(in: .whitespaces), how: How.web)
        }

        let packagesRaw = parsed.scalars["packages"]
        let packageManager: Fact<String>
        if packagesRaw == nil {
            packageManager = .cannot(why: parsed.finished ? neverAsked : cutOff)
        } else if packagesRaw!.trimmingCharacters(in: .whitespaces).isEmpty {
            packageManager = .no(how: How.packages)
        } else {
            packageManager = .yes(packagesRaw!.trimmingCharacters(in: .whitespaces),
                                  how: How.packages)
        }

        return ServerFacts(
            measuredAt: measuredAt,
            os: text("os", How.identity, noAnswer),
            kernel: text("kernel", How.identity, noAnswer),
            arch: text("arch", How.identity, noAnswer),
            hostname: text("host", How.identity, noAnswer),
            user: text("user", How.identity, noAnswer),
            privilege: text("root", How.privilege,
                            "We could not tell what this sign-in is allowed to do on this server."),
            initSystem: text("init", How.initSystem,
                             "We could not tell how this server starts and stops the things it runs."),
            containerRuntime: containerRuntime,
            packageManager: packageManager,
            webServer: webServer,
            cpus: whole("cpus", How.resources, noAnswer),
            disk: pair("disk_used_kb", "disk_total_kb").map {
                Fact<DiskFact>.yes(DiskFact(usedKb: $0.0, totalKb: $0.1), how: How.resources)
            } ?? .cannot(why: noAnswer),
            memory: pair("memory_total_kb", "memory_free_kb").map {
                Fact<MemoryFact>.yes(MemoryFact(totalKb: $0.0, freeKb: $0.1), how: How.resources)
            } ?? .cannot(why: noAnswer),
            load1: decimal("load1", How.resources, noAnswer),
            uptimeSeconds: whole("uptime_s", How.resources, noAnswer),
            services: rows("services", How.services) { lines in
                lines.map { line in
                    let column = columns(line, 4)
                    return ServiceFact(name: column[0], state: column[2], detail: column[3])
                }
            },
            containers: rows("containers", How.containers) { lines in
                lines.map { line in
                    let column = columns(line, 5)
                    return ContainerFact(name: column[0], image: column[1], state: column[2],
                                         status: column[3], ports: column[4])
                }
            },
            listeners: rows("listeners", How.listeners) { lines in
                lines.map { line in
                    let column = columns(line, 5)
                    return ListenerFact(address: column[0], port: column[1], program: column[2],
                                        unit: column[4])
                }
            },
            siteNames: rows("sites", How.sites) { lines in
                var seen = Set<String>()
                return lines.compactMap { line in
                    let name = line.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, seen.insert(name).inserted else { return nil }
                    return name
                }
            })
    }

    /// The script writes its reasons unpunctuated; a person reads a sentence.
    private static func sentence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return neverAsked }
        let capitalised = String(first).uppercased() + trimmed.dropFirst()
        return ".!?".contains(capitalised.last ?? " ") ? capitalised : capitalised + "."
    }

    private static func columns(_ row: String, _ count: Int) -> [String] {
        var parts = row.components(separatedBy: "\t")
        while parts.count < count { parts.append("") }
        return Array(parts.prefix(count))
    }
}
