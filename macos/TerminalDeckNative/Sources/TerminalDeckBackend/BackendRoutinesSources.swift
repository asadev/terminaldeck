import Foundation
import CoreServices
import Darwin
import TerminalDeckNativeCore

/// Native filesystem events, one stream per normalized routine folder. No
/// initial scan, write-finish polling, symlink following or duplicate streams.
public final class BackendRoutinesFileWatchers: @unchecked Sendable {
    public typealias StreamFactory = @Sendable (String, @escaping @Sendable (String) -> Void) throws -> @Sendable () -> Void
    public static let neverWatch: Set<String> = [".git", "node_modules", "out", "dist"]
    public static let maxWatchDepth = 10
    private struct Folder { var stop: @Sendable () -> Void; var listeners: [UUID: @Sendable (String) -> Void] }
    private let lock = NSRecursiveLock()
    private var folders: [String: Folder] = [:], stopped = false
    private let stream: StreamFactory
    public init(stream: StreamFactory? = nil) {
        self.stream = stream ?? { root, callback in let native = try BackendRoutinesFileStream(root: root, callback: callback); return { native.stop() } }
    }
    public var count: Int { lock.withLock { folders.count } }
    public func watch(_ folder: String, onChange: @escaping @Sendable (String) -> Void) throws -> @Sendable () -> Void {
        let root = URL(fileURLWithPath: folder).standardizedFileURL.path, id = UUID()
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw NativeRPCError(code: "unavailable", message: "The routine file watcher has stopped.") }
        if folders[root] == nil {
            let dispose = try stream(root) { [weak self] path in self?.changed(root: root, path: path) }
            folders[root] = Folder(stop: dispose, listeners: [:])
        }
        folders[root]?.listeners[id] = onChange
        return { [weak self] in self?.release(root: root, id: id) }
    }
    private func changed(root: String, path: String) {
        let receipt = Self.relative(root: root, path: path) ?? Self.relative(root: URL(fileURLWithPath: root).resolvingSymlinksInPath().path, path: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        guard let relative = receipt, Self.accepts(relative), !Self.crossesSymlink(root: root, relative: relative) else { return }
        let listeners = lock.withLock { folders[root].map { Array($0.listeners.values) } ?? [] }
        for listener in listeners { listener(relative) }
    }
    private func release(root: String, id: UUID) {
        let stop: (@Sendable () -> Void)? = lock.withLock { guard var folder = folders[root] else { return nil }; folder.listeners[id] = nil; if folder.listeners.isEmpty { folders[root] = nil; return folder.stop }; folders[root] = folder; return nil }; stop?()
    }
    public func stop() { let all = lock.withLock { stopped = true; let result = folders.values.map(\.stop); folders.removeAll(); return result }; for off in all { off() } }
    public static func relative(root: String, path: String) -> String? {
        let root = URL(fileURLWithPath: root).standardizedFileURL.path, path = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix), path != root else { return nil }; let relative = String(path.dropFirst(prefix.count)); return relative.hasPrefix("..") ? nil : relative
    }
    public static func accepts(_ relative: String) -> Bool {
        let pieces = relative.split(separator: "/", omittingEmptySubsequences: false)
        // A file under ten nested directories is the deepest chokidar depth 10.
        return !relative.isEmpty && !relative.hasPrefix("/") && !relative.hasPrefix("..") && pieces.count <= maxWatchDepth + 1 && !pieces.contains { neverWatch.contains(String($0)) || $0 == ".." }
    }
    private static func crossesSymlink(root: String, relative: String) -> Bool {
        var path = root
        for piece in relative.split(separator: "/") { path += "/" + piece; var info = stat(); if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return true } }
        return false
    }
}
private final class BackendRoutinesFileStream: @unchecked Sendable {
    private final class Box: @unchecked Sendable { let callback: @Sendable (String) -> Void; init(_ callback: @escaping @Sendable (String) -> Void) { self.callback = callback } }
    private let lock = NSLock(), box: Box
    private var reference: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.terminaldeck.routines.file-events", qos: .utility)
    init(root: String, callback: @escaping @Sendable (String) -> Void) throws {
        box = Box(callback)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in guard let pointer else { return nil }; _ = Unmanaged<Box>.fromOpaque(pointer).retain(); return pointer }, release: { pointer in if let pointer { Unmanaged<Box>.fromOpaque(pointer).release() } }, copyDescription: nil)
        let event: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }; let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                // Meta overflow/dropped events are diagnostics, not fabricated
                // changes. No scan is started to approximate a missing event.
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    FileHandle.standardError.write(Data("[routines] the file event stream dropped events; a rescan was not invented.\n".utf8)); continue
                }
                box.callback(String(cString: names[index]))
            }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, event, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { throw NativeRPCError(code: "unavailable", message: "The routine filesystem event stream could not be created.") }
        reference = stream; FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); throw NativeRPCError(code: "unavailable", message: "The routine filesystem event stream could not be started.") }
    }
    func stop() { let stream = lock.withLock { let result = reference; reference = nil; return result }; if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
    deinit { stop() }
}

/// Reuses the file/Git owner's status watch and its reference counts, even
/// while the Git panel is closed. No private git process or second poller.
public protocol BackendRoutinesGitWatching: Sendable {
    func observeGit(_ callback: @escaping @Sendable (String, NativeRPCValue) async -> Void) async -> UUID
    func removeObserver(_ id: UUID) async
    func watchGit(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func unwatch(cwd: String, ownerID: String) async
}
extension BackendFileWatchService: BackendRoutinesGitWatching {}
public enum BackendRoutinesSources {
    /// Wire into the alerts owner's existing on-report callback. The exact
    /// produced report is also returned to its caller; no scan is added here.
    public static func alertObserver(for engine: BackendRoutinesEngine) -> @Sendable (NativeRPCValue) async -> Void { { report in await engine.noteAlertReport(report) } }
}
public final class BackendRoutinesGitSources: @unchecked Sendable {
    private let shared: any BackendRoutinesGitWatching
    private let context: @Sendable (String) -> NativeRPCContext
    private let problem: @Sendable (String) async -> Void
    public init(shared: any BackendRoutinesGitWatching, context: @escaping @Sendable (String) -> NativeRPCContext,
                problem: @escaping @Sendable (String) async -> Void) { self.shared = shared; self.context = context; self.problem = problem }
    public func watch(_ folder: String, onChange: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let root = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path, context = self.context(folder), live = BackendRoutinesSourceLease(), shared = self.shared, problem = self.problem
        let task = Task {
            let observer = await shared.observeGit { cwd, _ in if live.active, URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path == root { onChange() } }
            do { _ = try await shared.watchGit(cwd: root, context: context) }
            catch { await problem("Could not watch git in \(root): \(error.localizedDescription)") }
            return observer
        }
        return { guard live.release() else { return }; Task { let observer = await task.value; await shared.removeObserver(observer); await shared.unwatch(cwd: root, ownerID: context.ownerID) } }
    }
}
private final class BackendRoutinesSourceLease: @unchecked Sendable {
    private let lock = NSLock(); private var released = false
    var active: Bool { lock.withLock { !released } }
    func release() -> Bool { lock.withLock { guard !released else { return false }; released = true; return true } }
}

/// picomatch-style path globbing with dot files enabled. Regexes are compiled
/// once and cached behind a bounded lock; paths keep Mac slash semantics.
public enum BackendRoutinesGlob {
    private final class Cache: @unchecked Sendable { let lock = NSLock(); var patterns: [String: NSRegularExpression] = [:] }
    private static let cache = Cache()
    public static func matches(_ pattern: String, path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if pattern == path { return true }
        let expression: NSRegularExpression? = cache.lock.withLock {
            if let found = cache.patterns[pattern] { return found }
            var input = utf16Units(pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern), bangs = 0
            while input.hasPrefix("!"), !input.hasPrefix("!(") { bangs += 1; input.removeFirst() }
            var parser = Parser(Array(input)); let body = parser.read(until: [])
            let suffix = input.hasSuffix("*") || input.hasSuffix("]") ? "/?" : ""
            let regex = bangs % 2 == 1 ? "^(?!(?:" + body + suffix + ")$).*$" : "^(?:" + body + suffix + ")$"
            guard let compiled = try? NSRegularExpression(pattern: regex) else { return nil }
            if cache.patterns.count > 200 { cache.patterns.removeAll() }; cache.patterns[pattern] = compiled; return compiled
        }
        guard let expression else { return false }
        let units = utf16Units(path)
        return expression.firstMatch(in: units, range: NSRange(units.startIndex..<units.endIndex, in: units)) != nil
    }
    /// ECMAScript regexes without `u` match one UTF16 unit per ?. ICU matches
    /// Unicode scalars. Map surrogate units into reserved supplementary PUA
    /// scalars on both sides; every original astral scalar is mapped, so it
    /// cannot collide with an original filename using that private-use range.
    private static func utf16Units(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for unit in text.utf16 { result.append(UnicodeScalar((0xD800...0xDFFF).contains(unit) ? 0xF0000 + UInt32(unit - 0xD800) : UInt32(unit))!) }
        return String(result)
    }
    private struct Parser {
        let text: [Character]; var at = 0, groupDepth = 0
        init(_ text: [Character]) { self.text = text }
        mutating func read(until endings: Set<Character>) -> String {
            var result = ""
            while at < text.count, !endings.contains(text[at]) {
                let start = at, c = text[at]; at += 1
                if "@+*?!".contains(c), at < text.count, text[at] == "(" {
                    at += 1; var alternatives: [String] = [], raw: [String] = []
                    repeat { let begin = at; alternatives.append(read(until: ["|", ")"])); raw.append(String(text[begin..<at])); if at < text.count, text[at] == "|" { at += 1 } else { break } } while true
                    if at < text.count, text[at] == ")" { at += 1 }
                    if c == "+" || c == "*", let safe = Self.repeated(raw) { result += safe.isEmpty ? NSRegularExpression.escapedPattern(for: String(text[start..<at])) : safe; continue }
                    let body = "(?:" + alternatives.joined(separator: "|") + ")"
                    switch c {
                    case "!":
                        var tail = self; let rest = tail.read(until: ["/"])
                        let suffix = at < text.count && text[at] == "." ? rest : ""
                        let star = raw.joined().contains("/") ? "(?:(?!\\.{1,2}(?:/|$))[^/]+(?:/|$))*" : "[^/]*"
                        result += "(?!(?:" + alternatives.joined(separator: "|") + ")" + suffix + "(?:/|$))" + star
                    case "@": result += body
                    default: result += body + String(c)
                    }
                } else if c == "*" {
                    while at < text.count, text[at] == "*" { at += 1 }
                    let segmentStart = start == 0 || "/({,|".contains(text[start - 1]), segmentEnd = at == text.count || "/)},|".contains(text[at])
                    let noDots = segmentStart ? "(?!\\.{1,2}(?:/|$))" : ""
                    if at - start >= 2 && segmentStart && segmentEnd {
                        if at < text.count, text[at] == "/" { at += 1; result += "(?:(?!\\.{1,2}(?:/|$))[^/]+/)*" }
                        else if start > 0, text[start - 1] == "/", result.hasSuffix("/") { result.removeLast(result.hasSuffix("\\/") ? 2 : 1); result += "(?:/(?:(?!\\.{1,2}(?:/|$))[^/]+(?:/|$))*)?" }
                        else { result += "(?:(?!\\.{1,2}(?:/|$))[^/]+(?:/|$))*" }
                    } else { result += noDots + "[^/]*" }
                } else if c == "?" { result += start > 0 && text[start - 1] == ")" ? "?" : "[^/]" }
                else if c == "+" && (groupDepth > 0 || (start > 0 && "])}".contains(text[start - 1]))) { result += "+" }
                else if c == "{" {
                    let contentStart = at
                    var alternatives: [String] = []
                    repeat { alternatives.append(read(until: [",", "}"])); if at < text.count, text[at] == "," { at += 1 } else { break } } while true
                    let closed = at < text.count && text[at] == "}", raw = String(text[contentStart..<at])
                    if closed { at += 1 }
                    let range = raw.components(separatedBy: "..")
                    if closed, alternatives.count == 1, range.count > 1 {
                        // picomatch's default expandRange sorts endpoints and
                        // emits a character class (it does not enumerate ints).
                        let value = "[" + range.sorted().joined(separator: "-") + "]"
                        result += (try? NSRegularExpression(pattern: value)) == nil ? range.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\.\\.") : value
                    } else if closed, alternatives.count > 1 { result += "(?:" + alternatives.joined(separator: "|") + ")" }
                    else { result += "\\{" + NSRegularExpression.escapedPattern(for: raw) + (closed ? "\\}" : "") }
                } else if c == "[" {
                    let begin = at; var body = "", posix = false
                    while at < text.count, text[at] != "]" {
                        if text[at] == "[", at + 1 < text.count, text[at + 1] == ":", let end = text[(at + 2)...].firstIndex(of: "]"), end > at + 2, text[end - 1] == ":" {
                            let key = String(text[(at + 2)..<(end - 1)])
                            if let source = Self.posix[key] { body += source; at = end + 1; posix = true; continue }
                        }
                        body.append(text[at]); at += 1
                    }
                    if at < text.count {
                        at += 1; if body.hasPrefix("^"), !body.contains("/") { body += "/" }
                        let expression = "[" + body + "]"
                        if !posix && !body.contains(where: { "-^\\".contains($0) }) { result += "(?:" + NSRegularExpression.escapedPattern(for: "[" + body + "]") + "|" + expression + ")" }
                        else { result += expression }
                    } else { result += "\\[" + NSRegularExpression.escapedPattern(for: String(text[begin..<at])) }
                } else if c == "(" {
                    var opening = "(?:"
                    if at < text.count, text[at] == "?" {
                        let rest = String(text[at...])
                        if let marker = ["?<=", "?<!", "?=", "?!", "?:"].first(where: { rest.hasPrefix($0) }) { opening = "(" + marker; at += marker.count }
                        else if rest.hasPrefix("?<"), let end = text[at...].firstIndex(of: ">") { opening = "(" + String(text[at...end]); at = end + 1 }
                    }
                    groupDepth += 1; let body = read(until: [")"]); groupDepth -= 1
                    if at < text.count { at += 1; result += opening + body + ")" } else { result += "\\(" + body }
                }
                else if c == "|" { result += "|" }
                else if c == "\"" { while at < text.count, text[at] != "\"" { result += NSRegularExpression.escapedPattern(for: String(text[at])); at += 1 }; if at < text.count { at += 1 } }
                else if c == "\\", at < text.count { result += NSRegularExpression.escapedPattern(for: String(text[at])); at += 1 }
                else { result += NSRegularExpression.escapedPattern(for: String(c)) }
            }
            return result
        }
        private static let posix = ["alnum": "a-zA-Z0-9", "alpha": "a-zA-Z", "ascii": "\\x00-\\x7F", "blank": " \\t", "cntrl": "\\x00-\\x1F\\x7F", "digit": "0-9", "graph": "\\x21-\\x7E", "lower": "a-z", "print": "\\x20-\\x7E ", "punct": ##"\-!"#$%&'()\*+,./:;<=>?@[\]^_`{|}~"##, "space": " \\t\\r\\n\\v\\f", "upper": "A-Z", "word": "A-Za-z0-9_", "xdigit": "A-Fa-f0-9"]
        private static func simple(_ raw: String) -> String? {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasPrefix("@("), text.hasSuffix(")"), !text.dropFirst(2).dropLast().contains(where: { "\\()[]{}|".contains($0) }) { text = String(text.dropFirst(2).dropLast()) }
            var result = "", escaped = false
            for c in text { if escaped { result.append(c); escaped = false } else if c == "\\" { escaped = true } else if "?*+@!()[]{}".contains(c) { return nil } else { result.append(c) } }
            return result
        }
        /// Matches picomatch's default maxExtglobRecursion=0 safeguards: risky
        /// repeated groups become literal; safe nested single-char stars flatten.
        private static func repeated(_ branches: [String]) -> String? {
            let branches = branches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if branches.count > 1, branches.contains(where: { $0.isEmpty || $0.allSatisfy { "*?".contains($0) } }) { return "" }
            let values = branches.compactMap(simple)
            for (index, a) in values.enumerated() { for b in values.dropFirst(index + 1) { if let char = a.first, !a.isEmpty, a.allSatisfy({ $0 == char }), b.allSatisfy({ $0 == char }), a.hasPrefix(b) || b.hasPrefix(a) { return "" } } }
            var chars: [Character] = [], star = false, combinable = true, nested = false
            for branch in branches {
                if branch.hasPrefix("*(") { var rest = branch, found: [Character] = []
                    while rest.hasPrefix("*("), let end = rest.firstIndex(of: ")"), let plain = simple(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end])), plain.count == 1 { found.append(plain.first!); rest = String(rest[rest.index(after: end)...]) }
                    if rest.isEmpty, !found.isEmpty { chars += found; star = true; continue }
                }
                if let plain = simple(branch), plain.count == 1 { chars.append(plain.first!); continue }
                combinable = false; if (branch.hasPrefix("*(") || branch.hasPrefix("+(")), branch.hasSuffix(")") { nested = true }
            }
            if star { return combinable ? "[" + Set(chars).sorted().map { NSRegularExpression.escapedPattern(for: String($0)) }.joined() + "]*" : "" }
            return nested ? "" : nil
        }
    }
}
