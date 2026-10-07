import Foundation
import TerminalDeckNativeCore

/// Wire budgets from remote/browser-control.ts. The phone protocol is unchanged.
public enum BackendRemoteServeBrowserLimits {
    public static let windowRows = 32
    public static let sessionRows = 32
    public static let rowText = 160
    public static let rowURL = 512
    public static let shotBytes = 47 * 1024
    public static let shotCharacters = ((shotBytes + 2) / 3) * 4
    public static let wireSteps = 60
    public static let stepText = 160
    public static let shotNote = 400
    public static let pickSelector = 400
    public static let pickWord = 64
    public static let submitGapMilliseconds = 50
}

public struct BackendRemoteServeBrowserWindow: Sendable {
    public let id: String
    public var title: String
    public var url: String
    public var viewID: String?
    public var profile: String
    public var isolated: Bool
    public var recording: Bool
    public var loading: Bool
    public init(id: String, title: String = "", url: String = "", viewID: String? = nil,
                profile: String = "", isolated: Bool = false, recording: Bool = false, loading: Bool = false) {
        self.id = id; self.title = title; self.url = url; self.viewID = viewID; self.profile = profile
        self.isolated = isolated; self.recording = recording; self.loading = loading
    }
}

public struct BackendRemoteServeBrowserSession: Sendable {
    public let id: String
    public let title: String
    public let ended: Bool
    public init(id: String, title: String, ended: Bool = false) { self.id = id; self.title = title; self.ended = ended }
}

public struct BackendRemoteServeBrowserCapture: Sendable {
    public let path: String
    public let width: Int
    public let height: Int
    public let preview: Data
    public init(path: String, width: Int, height: Int, preview: Data) {
        self.path = path; self.width = width; self.height = height; self.preview = preview
    }
}

/// A successful repartition can legitimately have no addressable view yet.
/// A nil move means failure; a move with nil viewID means clear the stale view.
public struct BackendRemoteServeBrowserMove: Sendable {
    public let viewID: String?
    public init(viewID: String?) { self.viewID = viewID }
}

/// No input value or arbitrary page fields can enter this type.
public struct BackendRemoteServeBrowserPicked: Sendable {
    public let found: Bool
    public let moved: Bool
    public let tag: String
    public let selector: String
    public let label: String
    public let labelSource: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let depth: Double
    public let maxUp: Double
    public init(found: Bool, moved: Bool = false, tag: String = "", selector: String = "", label: String = "",
                labelSource: String = "none", x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0,
                depth: Double = 0, maxUp: Double = 0) {
        self.found = found; self.moved = moved; self.tag = tag; self.selector = selector
        self.label = label; self.labelSource = labelSource; self.x = x; self.y = y
        self.width = width; self.height = height; self.depth = depth; self.maxUp = maxUp
    }
}

/// Safari supplies the bounded document-coordinate hit test. Its existing
/// toolbar picker is viewport based and cannot stand in for this operation.
@MainActor
public protocol BackendRemoteServeBrowserDocumentPicking: AnyObject {
    func pickDocumentPoint(tabID: String, x: Double, y: Double, up: Int,
                           context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked
}

/// Host operations, with the real Safari binding store shared with the agent
/// tools. The session supplier excludes Hoot/private sessions before returning.
@MainActor
public protocol BackendRemoteServeBrowserOperations: AnyObject {
    var bindings: BackendBrowserBindings { get }
    var machineID: String { get }
    var canResize: Bool { get }
    var canRepartition: Bool { get }
    var canRecord: Bool { get }
    var canPick: Bool { get }
    func isMine(_ deviceID: String) async -> Bool
    func list(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserWindow]
    func sessions(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession]
    func open(url: String, profile: String, isolated: Bool, context: NativeRPCContext) async throws -> String?
    func whyNotOpen() -> String?
    func go(id: String, url: String, context: NativeRPCContext) async throws
    func history(id: String, move: String, context: NativeRPCContext) async throws
    func close(id: String, context: NativeRPCContext) async throws
    func attach(id: String, sessionID: String, context: NativeRPCContext) async throws -> BrowserBoundWindow
    func detach(id: String, context: NativeRPCContext) async throws
    func resize(id: String, width: Double, height: Double, context: NativeRPCContext) async throws
    func repartition(id: String, isolated: Bool, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserMove?
    func setRecording(id: String, on: Bool, context: NativeRPCContext) async throws
    func recordedSteps(id: String, context: NativeRPCContext) async throws -> [BrowserRecordedStep]
    func capture(id: String, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserCapture
    func pick(id: String, x: Double, y: Double, up: Int, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked
    func write(sessionID: String, data: String, context: NativeRPCContext) async throws
    func now() -> Double
    func wait(milliseconds: Int) async throws
}

public extension BackendRemoteServeBrowserOperations {
    var machineID: String { "" }
    var canResize: Bool { false }
    var canRepartition: Bool { false }
    var canRecord: Bool { false }
    var canPick: Bool { false }
    func whyNotOpen() -> String? { nil }
    func resize(id: String, width: Double, height: Double, context: NativeRPCContext) async throws {
        throw NativeRPCError(code: "unavailable", message: "This machine's browser lays its own windows out, so this one cannot be resized from here.")
    }
    func repartition(id: String, isolated: Bool, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserMove? {
        throw NativeRPCError(code: "unavailable", message: "This machine's browser has one cookie jar and cannot isolate a window.")
    }
    func setRecording(id: String, on: Bool, context: NativeRPCContext) async throws {
        throw NativeRPCError(code: "unavailable", message: "This machine's browser cannot record a click flow.")
    }
    func recordedSteps(id: String, context: NativeRPCContext) async throws -> [BrowserRecordedStep] {
        throw NativeRPCError(code: "unavailable", message: "This machine's browser cannot record a click flow.")
    }
    func pick(id: String, x: Double, y: Double, up: Int, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked {
        throw NativeRPCError(code: "unavailable", message: "This machine's browser cannot point at one thing on a page.")
    }
    func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    func wait(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}

public enum BackendRemoteServeBrowserText {
    /// Keep the existing browser sanitizer and add the TypeScript scan/UTF-16
    /// budgets before any regular expression sees page-controlled text.
    public static func line(_ text: String, maximum: Int) -> String {
        let scan = maximum * 32 + 1024
        let head = String(decoding: Array(text.utf16.prefix(scan)), as: UTF16.self)
        let flat = BrowserLine.sanitize(head, max: scan)
        guard flat.utf16.count > maximum else { return flat }
        return String(decoding: Array(flat.utf16.prefix(maximum)), as: UTF16.self)
            .trimmingCharacters(in: .whitespaces) + "…"
    }
    public static func why(_ error: Error) -> String {
        let message = (error as? NativeRPCError)?.message ?? error.localizedDescription
        let cleaned = line(message, maximum: BackendRemoteServeBrowserLimits.rowText)
        return cleaned.isEmpty ? "it did not say why" : cleaned
    }
    public static func shotLine(_ shot: BackendRemoteServeBrowserCapture, url: String, note: String) -> String {
        let whereAt = url.isEmpty ? "" : " of \(line(url, maximum: BackendRemoteServeBrowserLimits.rowURL))"
        let context = "[browser screenshot\(whereAt): \(shot.path) (\(shot.width) x \(shot.height))]"
        let lead = line(note, maximum: BackendRemoteServeBrowserLimits.shotNote)
        return lead.isEmpty ? context : "\(lead) \(context)"
    }
    public static func replayWrites(_ line: String) -> (String, String) { (line.contains("@") ? line + " " : line, "\r") }
}
