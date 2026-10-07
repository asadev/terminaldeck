import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Port of src/main/remote/panels/artifacts.ts. Artifact viewer row IDs carry token, kind, bytes,
/// port.secret (or -), and the host absolute path. Prose/source stay in Files; a tap requests preview.
/// Every dependency the TS takes as `ArtifactsPanelDeps` is a seam here, with a real default.
public enum BackendRemotePanelArtifacts {
    public static let maxRows = 200, scanArtifacts = 600, maxSessionScopes = 12

    /// artifacts.ts:`ArtifactsPanelDeps` + `ArtifactPreviews`. The production supplier fills these from the real index/preview actors.
    public struct Seams: Sendable {
        public var list: @Sendable (String, BackendArtifactScanOptions, NativeRPCContext) async throws -> NativeRPCValue
        public var current: @Sendable (String) async throws -> BackendArtifactsPreview.Handle?
        public var serve: @Sendable (String, NativeRPCContext) async throws -> Void
        public var link: @Sendable (String, String, String) async throws -> Void
        public var stop: @Sendable (String) async throws -> Void
        public var sessionNames: (@Sendable () async throws -> [String: String])?
        /// `deps.scan`: the host's own scan options. The panel still forces the breadth (and the 600 budget unless the host set its own).
        public var scan: BackendArtifactScanOptions?
        public var now: @Sendable () -> Double
        public var log: @Sendable (String) -> Void
        public init(list: @escaping @Sendable (String, BackendArtifactScanOptions, NativeRPCContext) async throws -> NativeRPCValue,
                    current: @escaping @Sendable (String) async throws -> BackendArtifactsPreview.Handle?,
                    serve: @escaping @Sendable (String, NativeRPCContext) async throws -> Void,
                    link: @escaping @Sendable (String, String, String) async throws -> Void,
                    stop: @escaping @Sendable (String) async throws -> Void,
                    sessionNames: (@Sendable () async throws -> [String: String])? = nil,
                    scan: BackendArtifactScanOptions? = nil,
                    now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                    log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(("[remote] " + $0 + "\n").utf8)) }) {
            self.list = list; self.current = current; self.serve = serve; self.link = link; self.stop = stop
            self.sessionNames = sessionNames; self.scan = scan; self.now = now; self.log = log
        }
    }

    public static func provider(index: BackendArtifactsIndex, previews: BackendArtifactsPreview,
                                sessionNames: (@Sendable () async -> [String: String])? = nil) -> BackendRemotePanelProvider {
        provider(Seams(list: { project, options, context in try await index.list(project: project, options: options, context: context) },
                       current: { await previews.current(root: $0) },
                       serve: { root, context in _ = try await previews.serve(root: root, context: context) },
                       link: { root, token, relative in try await previews.link(root: root, token: token, relative: relative) },
                       stop: { await previews.stop(root: $0) },
                       sessionNames: sessionNames))
    }

    public static func provider(_ seams: Seams) -> BackendRemotePanelProvider {
        struct Looked { let payload: NativeRPCValue; let artifacts: [NativeRPCValue]; let root: String }
        @Sendable func look(_ request: BackendRemotePanelRequest, _ context: NativeRPCContext) async -> Looked {
            let scope = Scope(parseScope(request.scope)), now = seams.now()
            var names: [String: String] = [:]
            if let supplier = seams.sessionNames { names = (try? await supplier()) ?? [:] }
            var options = seams.scan ?? { var o = BackendArtifactScanOptions(); o.maxArtifacts = scanArtifacts; return o }()
            if seams.scan != nil, options.maxArtifacts == BackendArtifactScanOptions().maxArtifacts { options.maxArtifacts = scanArtifacts }
            options.scope = scope.all ? .all : .project
            let found: NativeRPCValue
            do { found = try await seams.list(request.path, options, context) }
            catch {
                return Looked(payload: .object([.init("path", .string(request.path)), .init("note", .string("This project's history could not be read: \(error.localizedDescription)")),
                    .init("scopes", .array(scopes(scope, sessions: [], names: names, now: now))), .init("rows", .array([]))]), artifacts: [], root: request.path)
            }
            // onlyArtifacts
            let root = found["root"].string ?? request.path, all = found["artifacts"].elements ?? []
            let artifacts = all.filter(isArtifactValue), hidden = all.count - artifacts.count
            var sessions = found["sessions"].elements ?? []
            if hidden > 0 {
                var files: [String: Int] = [:]
                for artifact in artifacts { for id in artifact["sessionIds"].elements?.compactMap(\.string) ?? [] { files[id, default: 0] += 1 } }
                sessions = sessions.filter { files[$0["sessionId"].string ?? ""] != nil }.map { $0.setting("files", .number(Double(files[$0["sessionId"].string ?? ""] ?? 0))) }
            }
            let needle = (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ofKind = artifacts.filter { (($0["writes"].number ?? 0) > 0) == (scope.kind == "made") }
            let matched = ofKind.filter { artifact in
                if let session = scope.session, !(artifact["sessionIds"].elements ?? []).contains(.string(session)) { return false }
                return needle.isEmpty || (artifact["relPath"].string ?? "").lowercased().contains(needle)
            }
            let kept = Array(matched.prefix(maxRows))
            if kept.count < matched.count { seams.log("artifacts panel: \(matched.count) rows for \(root) cut to \(maxRows)") }
            let handle = (try? await seams.current(root)) ?? nil
            let handleValue = handle?.wireValue
            let note = noteFor(root: root, sessionsScanned: Int(found["sessionsScanned"].number ?? 0), outside: Int(found["outsideProject"].number ?? 0), truncated: found["truncated"].bool == true,
                               artifactCount: artifacts.count, sessionCount: sessions.count, scope: scope, shown: kept.count, ofKind: ofKind.count,
                               filtered: !needle.isEmpty || scope.session != nil, cut: matched.count - kept.count, hidden: hidden)
            var payload = NativeRPCValue.object([.init("path", .string(request.path)), .init("note", .string(note)),
                .init("scopes", .array(scopes(scope, sessions: sessions, names: names, now: now)))])
            if handle != nil {
                payload = payload.setting("actions", .array([.object([.init("id", .string("stop")), .init("label", .string("Stop serving")), .init("kind", .string("destructive")),
                    .init("confirm", .string("Anything looking at a prototype from this project stops loading."))])]))
            }
            payload = payload.setting("rows", .array(kept.map { row($0, names: names, now: now, root: root, handle: handleValue) }))
            return Looked(payload: payload, artifacts: kept, root: root)
        }
        return .init(read: { request, context in await look(request, context).payload }, act: { request, context in
            let first = await look(request.panel, context), payload = first.payload
            if request.action == "stop" {
                do { try await seams.stop(first.root) } catch { return payload.setting("notice", .string("That server could not be stopped: \(error.localizedDescription)")) }
                return await look(request.panel, context).payload.setting("notice", .string("Nothing is being served now."))
            }
            guard request.action == "preview" else { return payload.setting("notice", .string("This panel has nothing called \(request.action).")) }
            let named = request.id ?? ""
            guard let artifact = first.artifacts.first(where: { tokenFor($0["relPath"].string ?? "") == named }) else {
                return payload.setting("notice", .string("\(named.isEmpty ? "That file" : named) is not in this list any more."))
            }
            let relative = artifact["relPath"].string ?? ""
            if artifact["onDisk"] == .null { return payload.setting("notice", .string("\(relative) is no longer on disk.")) }
            do { try await seams.serve(first.root, context); try await seams.link(first.root, tokenFor(relative), relative) }
            catch { return payload.setting("notice", .string("\(relative) could not be served: \(error.localizedDescription)")) }
            return await look(request.panel, context).payload.setting("notice", .string("Serving \(relative) from this machine."))
        })
    }

    // MARK: scope (artifacts.ts parseScope / encodeScope)
    private struct Scope {
        let kind: String; let all: Bool; let session: String?
        init(_ value: NativeRPCValue) { kind = value["kind"].string ?? "made"; all = value["breadth"].string != "project"; session = value["session"].string }
        var breadth: String { all ? "all" : "project" }
        var sessionToken: String { session.map { "session:" + $0 } ?? "session:*" }
    }
    public static func parseScope(_ input: String?) -> NativeRPCValue {
        var kind = "made", breadth = "all", session: String?
        var kindSeen = false, breadthSeen = false, sessionSeen = false
        for part in (input ?? "").split(whereSeparator: \.isWhitespace).map(String.init) {
            if !kindSeen && (part == "made" || part == "changed") { kind = part; kindSeen = true }
            else if !breadthSeen && (part == "project" || part == "all") { breadth = part; breadthSeen = true }
            else if !sessionSeen && part.hasPrefix("session:") { let id = String(part.dropFirst(8)); session = id.isEmpty || id == "*" ? nil : id; sessionSeen = true }
        }
        return .object([.init("kind", .string(kind)), .init("breadth", .string(breadth)), .init("session", session.map(NativeRPCValue.string) ?? .null)])
    }
    public static func encodeScope(_ state: NativeRPCValue, _ lead: String) -> String {
        let scope = Scope(state); var rest: [String] = []
        if !(lead == "made" || lead == "changed") { rest.append(scope.kind) }
        if !(lead == "project" || lead == "all") { rest.append(scope.breadth) }
        if !lead.hasPrefix("session:") { rest.append(scope.sessionToken) }
        return ([lead] + rest).joined(separator: " ")
    }
    private static func scopes(_ scope: Scope, sessions: [NativeRPCValue], names: [String: String], now: Double) -> [NativeRPCValue] {
        let state = NativeRPCValue.object([.init("kind", .string(scope.kind)), .init("breadth", .string(scope.breadth)), .init("session", scope.session.map(NativeRPCValue.string) ?? .null)])
        func chip(_ token: String, _ label: String) -> NativeRPCValue {
            .object([.init("id", .string(encodeScope(state, token))), .init("label", .string(label)), .init("on", .bool(token == scope.kind || token == scope.breadth || token == scope.sessionToken))])
        }
        var result = [chip("made", "Made here"), chip("changed", "Changed"), chip("project", "This project's sessions"), chip("all", "Every session")]
        let offered = Array(sessions.filter { !($0["sessionId"].string ?? "").contains(where: \.isWhitespace) }.prefix(maxSessionScopes))
        if sessions.count > 1 || scope.session != nil {
            result.append(chip("session:*", "All sessions"))
            if let chosen = scope.session, !offered.contains(where: { $0["sessionId"].string == chosen }) { result.append(chip("session:" + chosen, names[chosen] ?? "session " + shortSession(chosen))) }
            for entry in offered {
                let id = entry["sessionId"].string ?? "", files = Int(entry["files"].number ?? 0)
                result.append(chip("session:" + id, "\(names[id] ?? whenLabel(entry["at"].number ?? 0, now: now)) · \(plural(files, "file"))"))
            }
        }
        return result
    }

    // MARK: kinds, tokens, rows
    private static let pageExtensions: Set<String> = ["html", "htm", "xhtml"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "heic", "heif", "svg"]
    private static let mediaExtensions: Set<String> = ["pdf", "mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "aac", "flac", "ogg"]
    private static let opaqueExtensions: Set<String> = ["zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar", "jar", "war", "exe", "dll", "dylib", "so", "a", "o", "bin", "wasm", "class", "pyc",
        "db", "sqlite", "sqlite3", "realm", "pack", "idx", "docx", "xlsx", "pptx", "doc", "xls", "ppt", "odt", "ods", "key", "pages", "numbers",
        "psd", "ai", "sketch", "fig", "blend", "dmg", "pkg", "iso", "img", "woff", "woff2", "ttf", "otf", "eot"]
    private static func pathKind(_ relPath: String) -> String {
        let name = relPath.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? relPath
        let ext: String = { guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }; return name[name.index(after: dot)...].lowercased() }()
        if pageExtensions.contains(ext) { return "page" }; if imageExtensions.contains(ext) { return "image" }
        if mediaExtensions.contains(ext) { return "media" }; if opaqueExtensions.contains(ext) { return "other" }; return "text"
    }
    public static func kindOf(_ artifact: NativeRPCValue) -> String { artifact["onDisk"] == .null ? "gone" : pathKind(artifact["relPath"].string ?? "") }
    public static func isArtifact(_ artifact: NativeRPCValue) -> Bool { isArtifactValue(artifact) }
    private static func isArtifactValue(_ artifact: NativeRPCValue) -> Bool { ["page", "image", "media"].contains(pathKind(artifact["relPath"].string ?? "")) }
    public static func tokenFor(_ relative: String) -> String {
        let bad = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(31))).union(CharacterSet(charactersIn: "\u{7f}"))
        if !relative.isEmpty, relative.utf8.count <= 120, relative.rangeOfCharacter(from: bad) == nil { return relative }
        let hash = Data(Insecure.SHA1.hash(data: Data(relative.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "#" + String(hash.prefix(16))
    }
    public static func rowIDFor(_ artifact: NativeRPCValue, _ root: String, _ handle: NativeRPCValue?) -> String {
        let kind = kindOf(artifact), relative = artifact["relPath"].string ?? ""
        let bytes = artifact["onDisk"] == .null ? -1 : Int(artifact["onDisk"]["bytes"].number ?? 0)
        let preview = kind == "gone" || handle == nil ? "-" : "\(Int(handle?["port"].number ?? 0)).\(handle?["secret"].string ?? "")"
        return [tokenFor(relative), kind, String(bytes), preview, URL(fileURLWithPath: root).appendingPathComponent(relative).path].joined(separator: " ")
    }
    private static func row(_ artifact: NativeRPCValue, names: [String: String], now: Double, root: String, handle: NativeRPCValue?) -> NativeRPCValue {
        let relative = artifact["relPath"].string ?? "", ids = artifact["sessionIds"].elements?.compactMap(\.string) ?? []
        var detail: [String] = []
        if let newest = ids.first { detail.append(names[newest] ?? "session " + shortSession(newest)); if ids.count > 1 { detail.append("+\(ids.count - 1) more") } }
        if artifact["onDisk"] == .null { detail.append("not on disk") }
        var row = NativeRPCValue.object([.init("title", .string(relative.contains("/") ? relative : artifact["name"].string ?? relative))])
        if !detail.isEmpty { row = row.setting("detail", .string(detail.joined(separator: " · "))) }
        let when = whenLabel(artifact["lastAt"].number ?? 0, now: now); if !when.isEmpty { row = row.setting("value", .string(when)) }
        return row.setting("status", .string((artifact["writes"].number ?? 0) > 0 ? "made" : "changed")).setting("id", .string(rowIDFor(artifact, root, handle)))
    }
    private static func shortSession(_ id: String) -> String { id.count <= 8 ? id : String(id.prefix(8)) }
    private static func plural(_ count: Int, _ one: String) -> String { "\(count) \(one)\(count == 1 ? "" : "s")" }
    public static func whenLabel(_ at: Double, now: Double) -> String {
        guard at != 0, at.isFinite else { return "" }
        let delta = now - at
        if delta < 60_000 { return "just now" }
        if delta < 3_600_000 { return "\(Int((delta / 60_000).rounded()))m ago" }
        if delta < 86_400_000 { return "\(Int((delta / 3_600_000).rounded()))h ago" }
        if delta < 30 * 86_400_000 { return "\(Int((delta / 86_400_000).rounded()))d ago" }
        return String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at / 1000)).prefix(10))
    }
    private static func noteFor(root: String, sessionsScanned: Int, outside: Int, truncated: Bool, artifactCount: Int, sessionCount: Int, scope: Scope,
                                shown: Int, ofKind: Int, filtered: Bool, cut: Int, hidden: Int) -> String {
        if artifactCount == 0 {
            if hidden > 0 { return "No prototypes in \(root) — \(plural(hidden, "file")) of prose or source, which is what Files is for." }
            let widen = !scope.all ? " Only the sessions started in this folder were read — Every session also reads agents launched from a parent folder." : ""
            let where_ = "Nothing written or edited in \(root)"
            if sessionsScanned == 0 { return "\(where_) — no sessions have been recorded for it yet.\(widen)" }
            return "\(where_) — \(plural(sessionsScanned, "session")) read\(outside > 0 ? ", \(plural(outside, "change")) to files outside it" : "").\(widen)"
        }
        if shown == 0 {
            if filtered { return "Nothing matches that filter." }
            return scope.kind == "made" ? "No agent has made an artifact here yet. What it edited is under Changed." : "Every artifact here was made by an agent rather than edited into."
        }
        var parts = [shown == ofKind ? "\(shown) \(scope.kind == "made" ? "made here" : "changed")" : "\(shown) of \(ofKind) \(scope.kind == "made" ? "made here" : "changed")", plural(sessionCount, "session")]
        if cut > 0 { parts.append("\(cut) older match\(cut == 1 ? "" : "es") not sent to this phone") }
        if truncated { parts.append("older work not read") }
        return parts.joined(separator: " · ")
    }
}
