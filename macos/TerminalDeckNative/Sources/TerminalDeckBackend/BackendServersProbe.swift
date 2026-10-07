import Foundation

/// POSIX probe is sent through the typed SSH connection on stdin. Nothing in
/// this reader spawns a process; partial answers never become empty success.
public enum BackendServersProbe {
    public static let cutOff = "The server stopped answering before it finished this check."
    public static let neverAsked = "This check did not run."
    private static let identity = "asked the server what it is"
    private static let resources = "asked how much room and memory it has"
    private struct Section { var state: String; var reason: String; var rows: [String] }
    private struct Parsed { var scalars: [String: String] = [:]; var sections: [String: Section] = [:]; var finished = false }
    private static func split(_ stdout: String) -> Parsed {
        var out = Parsed(); var current: String?
        for line in stdout.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                let parts = String(line.dropFirst()).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                if name == "end" { out.finished = true; current = nil; continue }
                out.sections[name] = Section(state: parts.count > 1 ? parts[1] : "", reason: parts.count > 2 ? parts[2] : "", rows: [])
                current = name; continue
            }
            if let current { if !line.isEmpty { out.sections[current]?.rows.append(line) }; continue }
            if let equals = line.firstIndex(of: "="), equals != line.startIndex { out.scalars[String(line[..<equals])] = String(line[line.index(after: equals)...]) }
        }
        return out
    }
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func numeric(_ s: String?) -> Double? {
        guard let s, !trim(s).isEmpty else { return nil }
        let text = trim(s)
        let value: Double?
        // JavaScript Number accepts prefixed integers as well as decimal values.
        if text.lowercased().hasPrefix("0x") { value = UInt64(text.dropFirst(2), radix: 16).map(Double.init) }
        else if text.lowercased().hasPrefix("0b") { value = UInt64(text.dropFirst(2), radix: 2).map(Double.init) }
        else if text.lowercased().hasPrefix("0o") { value = UInt64(text.dropFirst(2), radix: 8).map(Double.init) }
        else { value = Double(text) }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    private static func text(_ p: Parsed, _ key: String, _ at: Double, _ how: String, _ why: String) -> BackendServersFact<String> {
        guard let raw = p.scalars[key], !trim(raw).isEmpty else { return .cannot(measuredAt: at, why: why) }
        return .yes(trim(raw), measuredAt: at, how: how)
    }
    private static func number(_ p: Parsed, _ key: String, _ at: Double, _ why: String) -> BackendServersFact<Double> {
        guard let value = numeric(p.scalars[key]) else { return .cannot(measuredAt: at, why: why) }
        return .yes(value, measuredAt: at, how: resources)
    }
    private static func sentence(_ raw: String) -> String {
        let s = trim(raw); guard let first = s.first else { return neverAsked }
        let capital = String(first).uppercased() + String(s.dropFirst())
        return [".", "!", "?"].contains(String(s.suffix(1))) ? capital : capital + "."
    }
    private static func section<T: Codable & Equatable & Sendable>(_ p: Parsed, _ name: String, _ at: Double, _ how: String, _ build: ([String]) -> T) -> BackendServersFact<T> {
        guard let found = p.sections[name] else { return .cannot(measuredAt: at, why: p.finished ? neverAsked : cutOff) }
        if found.state == "cannot" { return .cannot(measuredAt: at, why: found.reason.isEmpty ? neverAsked : sentence(found.reason)) }
        if found.state == "none" { return .no(measuredAt: at, how: how) }
        return .yes(build(found.rows), measuredAt: at, how: how)
    }
    private static func columns(_ row: String, _ count: Int) -> [String] { Array((row.components(separatedBy: "\t") + Array(repeating: "", count: count)).prefix(count)) }
    private static func pair<A: Codable & Equatable & Sendable, B: Codable & Equatable & Sendable, T: Codable & Equatable & Sendable>(_ a: BackendServersFact<A>, _ b: BackendServersFact<B>, _ combine: (A, B) -> T) -> BackendServersFact<T> {
        if case .yes(let av, _, let how) = a, case .yes(let bv, _, _) = b { return .yes(combine(av, bv), measuredAt: a.measuredAt, how: how) }
        if let why = a.why ?? b.why { return .cannot(measuredAt: a.measuredAt, why: why) }
        return .no(measuredAt: a.measuredAt, how: a.how ?? "no")
    }
    private static func serviceState(_ a: String, _ b: String, _ initSystem: BackendServersInitSystem?) -> BackendServersRunState {
        if initSystem == .openrc { return a == "started" ? .running : a == "crashed" ? .failed : a == "stopped" ? .stopped : .unknown }
        if initSystem == .sysvinit { return a == "+" ? .running : a == "-" ? .stopped : .unknown }
        if b == "running" { return .running }
        if a == "failed" || b == "failed" { return .failed }
        if ["active", "activating", "reloading"].contains(a) { return .running }
        return ["inactive", "deactivating"].contains(a) ? .stopped : .unknown
    }
    public static func parse(_ stdout: String, serverId: String, measuredAt at: Double) -> BackendServersFacts {
        let p = split(stdout); var f = BackendServersFacts(serverId: serverId, measuredAt: at)
        if let v = BackendServersPrivilege(rawValue: p.scalars["root"] ?? "") { f.privilege = .yes(v, measuredAt: at, how: "asked what this sign-in is allowed to do") }
        else { f.privilege = .cannot(measuredAt: at, why: "We could not tell what this sign-in is allowed to do on this server.") }
        if let v = BackendServersInitSystem(rawValue: p.scalars["init"] ?? "") { f.`init` = .yes(v, measuredAt: at, how: "looked for how this server starts and stops things") }
        else { f.`init` = .cannot(measuredAt: at, why: "We could not tell how this server starts and stops the things it runs.") }
        let containerHow = "asked whether this server runs containers"
        switch p.scalars["containers"] {
        case "docker": f.containerRuntime = .yes(.docker, measuredAt: at, how: containerHow)
        case "podman": f.containerRuntime = .yes(.podman, measuredAt: at, how: containerHow)
        case "none": f.containerRuntime = .no(measuredAt: at, how: containerHow)
        case "present-no-permission": f.containerRuntime = .cannot(measuredAt: at, why: "This sign-in is not allowed to ask this server about its containers.")
        default: f.containerRuntime = .cannot(measuredAt: at, why: "We could not tell whether this server runs containers.")
        }
        if let web = p.scalars["web"] { f.webServer = trim(web).isEmpty ? .no(measuredAt: at, how: "looked for a web server") : .yes(trim(web), measuredAt: at, how: "looked for a web server") }
        else { f.webServer = .cannot(measuredAt: at, why: p.finished ? neverAsked : cutOff) }
        let admin = p.sections["adminunits"]; let added = Set(admin?.state == "ok" ? admin?.rows ?? [] : [])
        let initValue = f.`init`.value
        f.services = section(p, "services", at, "asked what it is set up to keep running") { rows in rows.compactMap { row in
            let c = columns(row, 4); guard !c[0].isEmpty else { return nil }
            return BackendServersServiceFact(name: c[0], state: serviceState(c[1], c[2], initValue), description: c[3], addedHere: added.contains(c[0]))
        } }
        f.containers = section(p, "containers", at, containerHow) { rows in rows.compactMap { row in
            let c = columns(row, 5); guard !c[0].isEmpty else { return nil }
            let state: BackendServersRunState = c[2] == "running" ? .running : c[2] == "restarting" || c[2].isEmpty ? .unknown : .stopped
            return BackendServersContainerFact(name: c[0], image: c[1], state: state, status: c[3], ports: c[4])
        } }
        f.listeners = section(p, "listeners", at, "asked what is listening") { rows in rows.compactMap { row in
            let c = columns(row, 5)
            guard let port = numeric(c[1]), port.rounded(.towardZero) == port, port > 0, port < Double(Int.max) else { return nil }
            let rawPid = numeric(c[3]); let pid = rawPid.flatMap { $0 > 0 && $0.rounded(.towardZero) == $0 && $0 < Double(Int.max) ? Int($0) : nil }
            return BackendServersListenerFact(address: c[0], port: Int(port), program: c[2], pid: pid, unit: c[4])
        } }
        f.siteNames = section(p, "sites", at, "read the web server's own settings") { $0.map(trim).filter { !$0.isEmpty } }
        f.agents = section(p, "agents", at, "looked for a coding assistant this sign-in can run") { rows in rows.compactMap { row in
            let c = columns(row, 5); guard let id = BackendServersAgentID(rawValue: c[0]), !c[1].isEmpty else { return nil }
            return BackendServersAgentFact(id: id, path: c[1], version: c[2], signedIn: BackendServersSigninState(rawValue: c[3]) ?? .unknown, account: c[4].isEmpty ? nil : c[4])
        } }
        if let fetch = p.scalars["installer_fetch"] { f.agentInstall = .yes(.init(downloader: trim(fetch), npm: trim(p.scalars["installer_npm"] ?? ""), memoryAvailableKb: numeric(p.scalars["mem_avail_kb"]), homeFreeKb: numeric(p.scalars["home_free_kb"])), measuredAt: at, how: "checked what it would take to put one here") }
        else { f.agentInstall = .cannot(measuredAt: at, why: p.finished ? neverAsked : cutOff) }
        if f.numbersBelongToTheHost {
            f.disk = .cannot(measuredAt: at, why: BackendServersFacts.containerNumbersWhy); f.memory = .cannot(measuredAt: at, why: BackendServersFacts.containerNumbersWhy)
            f.load1 = .cannot(measuredAt: at, why: BackendServersFacts.containerNumbersWhy); f.uptimeSeconds = f.load1
        } else {
            f.disk = pair(number(p, "disk_used_kb", at, "This server did not say how much room it has."), number(p, "disk_total_kb", at, "This server did not say how much room it has.")) { .init(usedKb: $0, totalKb: $1) }
            f.memory = pair(number(p, "memory_total_kb", at, "This server did not say how much memory it has."), number(p, "memory_free_kb", at, "This server did not say how much memory it has.")) { .init(totalKb: $0, freeKb: $1) }
            f.load1 = number(p, "load1", at, "This server does not report how busy it is.")
            f.uptimeSeconds = number(p, "uptime_s", at, "This server does not report how long it has been on.")
        }
        f.os = text(p, "os", at, identity, "This server did not say what it is running.")
        f.kernel = text(p, "kernel", at, identity, "This server did not say what it is running.")
        f.arch = text(p, "arch", at, identity, "This server did not say what kind it is.")
        f.hostname = text(p, "host", at, identity, "This server did not say what it is called.")
        f.user = text(p, "user", at, identity, "This server did not say who we signed in as.")
        f.packageManager = text(p, "packages", at, "looked for how software is installed here", "We do not recognise how software is installed on this server.")
        f.cpus = number(p, "cpus", at, "This server did not say how many processors it has.")
        return f
    }
    public static func gather(_ serverId: String, connections: BackendServersConnections, measuredAt: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 }) async throws -> BackendServersFacts {
        let answer = try await connections.runScript(serverId, script: script)
        return parse(answer.stdout, serverId: serverId, measuredAt: measuredAt())
    }
}

// The project's emitted POSIX bytes, including tabs and final blank line.
extension BackendServersProbe {
    public static var script: String {
        #"""
        LC_ALL=C
        export LC_ALL
        p() { printf '%s=%s\n' "$1" "$2"; }
        have() { command -v "$1" >/dev/null 2>&1; }
        sec() { printf '#%s %s%s\n' "$1" "$2" "${3:+ $3}"; }
        
        p schema 1
        p os      "$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || uname -s 2>/dev/null )"
        p kernel  "$(uname -sr 2>/dev/null)"
        p arch    "$(uname -m 2>/dev/null)"
        p host    "$(hostname 2>/dev/null || uname -n 2>/dev/null)"
        p user    "$(id -un 2>/dev/null)"
        
        if   [ "$(id -u 2>/dev/null)" = "0" ];      then p root yes
        elif have sudo && sudo -n true 2>/dev/null; then p root sudo-nopasswd
        elif have sudo;                             then p root sudo-password
        else                                             p root no; fi
        
        if   [ -d /run/systemd/system ];            then INIT=systemd
        elif have rc-status;                        then INIT=openrc
        elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then INIT=launchd
        elif [ -f /etc/inittab ] && have service;   then INIT=sysvinit
        elif [ -f /.dockerenv ] || grep -qa 'docker\|containerd\|lxc' /proc/1/cgroup 2>/dev/null; then INIT=container-none
        else                                             INIT=unknown; fi
        p init "$INIT"
        
        if   have docker && docker info >/dev/null 2>&1; then CTR=docker
        elif have podman && podman info >/dev/null 2>&1; then CTR=podman
        elif have docker || have podman;                 then CTR=present-no-permission
        else                                                  CTR=none; fi
        p containers "$CTR"
        
        PKG=
        for m in apt-get dnf yum apk pacman zypper pkg brew; do have "$m" && { PKG=$m; break; }; done
        p packages "$PKG"
        
        WEB=
        for w in nginx apache2 httpd caddy lighttpd; do have "$w" && { WEB=$w; break; }; done
        p web "$WEB"
        
        AW="$PATH"
        for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.claude/local" "$HOME/.npm-global/bin" \
                 "$HOME/.volta/bin" "$HOME/.bun/bin" "$HOME/.asdf/shims" \
                 "$HOME/.local/share/mise/shims" /usr/local/bin /opt/homebrew/bin /snap/bin; do
          [ -d "$d" ] && AW="$AW:$d"
        done
        for d in "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin \
                 "$HOME"/.local/share/fnm/node-versions/*/installation/bin; do
          [ -d "$d" ] && AW="$AW:$d"
        done
        
        FETCH=
        for f in curl wget; do have "$f" && { FETCH=$f; break; }; done
        p installer_fetch "$FETCH"
        p installer_npm "$(PATH="$AW" command -v npm 2>/dev/null)"
        p mem_avail_kb "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
        p home_free_kb "$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
        
        p cpus "$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
        p disk_used_kb  "$(df -Pk / 2>/dev/null | awk 'NR==2{print $3}')"
        p disk_total_kb "$(df -Pk / 2>/dev/null | awk 'NR==2{print $2}')"
        p memory_total_kb "$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
        p memory_free_kb  "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
        p load1     "$(awk '{print $1}' /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
        p uptime_s  "$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)"
        
        case "$INIT" in
          systemd)
            if have systemctl; then
              sec services ok
              systemctl list-units --type=service --all --no-legend --no-pager --plain 2>/dev/null |
                awk '$2=="loaded"{n=$1;a=$3;s=$4;$1=$2=$3=$4="";sub(/^ +/,"");printf "%s\t%s\t%s\t%s\n",n,a,s,$0}' | head -n 400
            else
              sec services cannot "this server has no way to be asked what it keeps running"
            fi ;;
          openrc)
            sec services ok
            rc-status -s 2>/dev/null | awk -F'[][]' 'NF>1{n=$1;gsub(/^[ \t]+|[ \t]+$/,"",n);s=$2;gsub(/^[ \t]+|[ \t]+$/,"",s);if(n!="")printf "%s\t%s\t%s\t\n",n,s,s}' | head -n 200 ;;
          sysvinit)
            sec services ok
            service --status-all 2>/dev/null | awk '{m=$2;n=$4;if(n!="")printf "%s\t%s\t%s\t\n",n,m,m}' | head -n 200 ;;
          container-none)
            sec services cannot "this is running inside a container, which has nothing of its own that keeps programs running" ;;
          *)
            sec services cannot "we could not tell how this server starts and stops things" ;;
        esac
        
        case "$CTR" in
          docker|podman)
            sec containers ok
            $CTR ps -a --no-trunc --format '{{.Names}}	{{.Image}}	{{.State}}	{{.Status}}	{{.Ports}}' 2>/dev/null ||
              $CTR ps -a --no-trunc --format '{{.Names}}	{{.Image}}		{{.Status}}	{{.Ports}}' 2>/dev/null ;;
          present-no-permission)
            sec containers cannot "this sign-in is not allowed to ask this server about its containers" ;;
          *)
            sec containers none ;;
        esac
        
        owners() {
          while IFS='	' read -r addr port prog pid; do
            unit=
            if [ -n "$pid" ] && [ -r "/proc/$pid/cgroup" ]; then
              while IFS= read -r cl; do
                case "$cl" in *.service|*.scope|*.slice) unit=${cl##*/} ;; esac
              done < "/proc/$pid/cgroup"
            fi
            printf '%s\t%s\t%s\t%s\t%s\n' "$addr" "$port" "$prog" "$pid" "$unit"
          done
        }
        
        if have ss; then
          sec listeners ok
          ss -H -tlnp 2>/dev/null | awk '{la=$4;n=split(la,a,":");port=a[n];addr=substr(la,1,length(la)-length(port)-1);prog="";pid="";if(match($0,/"[^"]+"/))prog=substr($0,RSTART+1,RLENGTH-2);if(match($0,/pid=[0-9]+/))pid=substr($0,RSTART+4,RLENGTH-4);printf "%s\t%s\t%s\t%s\n",addr,port,prog,pid}' | head -n 200 | owners
        elif have netstat; then
          sec listeners ok
          netstat -tlnp 2>/dev/null | awk '/LISTEN/{la=$4;n=split(la,a,":");port=a[n];addr=substr(la,1,length(la)-length(port)-1);prog="";pid="";if($NF ~ /\//){split($NF,b,"/");pid=b[1];prog=b[2]}printf "%s\t%s\t%s\t%s\n",addr,port,prog,pid}' | head -n 200 | owners
        else
          sec listeners cannot "this server has no tool installed for listing what is listening"
        fi
        
        case "$WEB" in
          caddy)
            if [ -r /etc/caddy/Caddyfile ]; then
              sec sites ok
              awk '/^[^ \t#{}].*\{[ \t]*$/{l=$0;sub(/[ \t]*\{[ \t]*$/,"",l);n=split(l,a,/[ \t]*,[ \t]*/);for(i=1;i<=n;i++)if(a[i]!="")printf "%s\n",a[i]}' /etc/caddy/Caddyfile | head -n 100
            else
              sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
            fi ;;
          nginx)
            if nginx -T >/dev/null 2>&1; then
              sec sites ok
              nginx -T 2>/dev/null | awk '/^[ \t]*server_name[ \t]/{for(i=2;i<=NF;i++){g=$i;sub(/;$/,"",g);if(g!=""&&g!="_")print g}}' | sort -u | head -n 100
            elif cat /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf >/dev/null 2>&1; then
              sec sites ok
              cat /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf 2>/dev/null |
                awk '/^[ \t]*server_name[ \t]/{for(i=2;i<=NF;i++){g=$i;sub(/;$/,"",g);if(g!=""&&g!="_")print g}}' | sort -u | head -n 100
            else
              sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
            fi ;;
          apache2|httpd)
            if ${WEB}ctl -S >/dev/null 2>&1; then
              sec sites ok
              ${WEB}ctl -S 2>&1 | awk '/namevhost/{print $4}' | sort -u | head -n 100
            else
              sec sites cannot "this sign-in is not allowed to read the web server's settings on this server"
            fi ;;
          "")
            sec sites none ;;
          *)
            sec sites cannot "we do not know how to read this web server's settings" ;;
        esac
        if [ "$INIT" = systemd ] && [ -d /etc/systemd/system ]; then
          sec adminunits ok
          for f in /etc/systemd/system/*.service; do
            [ -e "$f" ] || continue
            printf '%s\n' "${f##*/}"
          done | head -n 200
        else
          sec adminunits cannot "we can only tell which programs were added by hand on a server that keeps them this way"
        fi
        
        ALOGIN=$("${SHELL:-/bin/sh}" -lc 'command -v claude; command -v codex; command -v gemini; \#(BackendServersAgentSignin.agentEnvProbe)' 2>/dev/null)
        \#(BackendServersAgentSignin.readAgentEnv(from: "ALOGIN", codexHome: "CXH", geminiEnv: "GENV"))
        sec agents ok
        for a in claude codex gemini; do
          ab=$(PATH="$AW" command -v "$a" 2>/dev/null)
          [ -n "$ab" ] || ab=$(printf '%s\n' "$ALOGIN" | grep "/$a$" 2>/dev/null | head -n 1)
          [ -n "$ab" ] || continue
          av=$("$ab" --version 2>/dev/null | head -n 1 | awk '\#(BackendServersAgentSignin.agentVersionAWK)')
          ai=unknown
          ae=
          if [ -n "$av" ]; then
        \#(BackendServersAgentSignin.signInCases(agentVar: "a", binary: "ab", state: "ai", account: "ae", codexHome: "CXH", geminiEnv: "GENV"))
          fi
          printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$ab" "$av" "$ai" "$ae"
        done
        printf '#end ok\n'
        
        
        """#
    }
}
