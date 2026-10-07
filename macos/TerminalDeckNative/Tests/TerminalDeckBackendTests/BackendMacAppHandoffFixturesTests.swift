import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

func BackendMacAppHandoffObject(_ fields: [String: NativeRPCValue]) -> NativeRPCValue { .object(fields.map { .init($0.key, $0.value) }) }
func BackendMacAppHandoffContext() -> NativeRPCContext { .init(caller: .nativeApp, ownerID: "window") }
struct BackendMacAppHandoffTestError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
actor BackendMacAppHandoffFakeDesktop: BackendMacAppHandoffLinkDesktop {
    var alive = true, window = true
    var opened: [String] = [], copied: [String] = [], pushed: [(String, NativeRPCValue)] = []
    var items: [BackendMacAppHandoffLinkMenuItem] = []
    func ownerAlive(_ ownerID: String) -> Bool { alive }
    func hasWindow(_ ownerID: String) -> Bool { window }
    func push(_ ownerID: String, channel: String, value: NativeRPCValue) { pushed.append((channel, value)) }
    func openSystem(_ url: String) { opened.append(url) }
    func copyLink(_ text: String) { copied.append(text) }
    func menu(_ ownerID: String, items: [BackendMacAppHandoffLinkMenuItem]) { self.items = items }
    func set(alive: Bool = true, window: Bool = true) { self.alive = alive; self.window = window }
    func press(_ label: String) async throws { guard let item = items.first(where: { $0.label == label }) else { throw BackendMacAppHandoffTestError(message: "no menu item \(label)") }; try await item.click() }
    func result() -> (opened: [String], copied: [String], pushed: [(String, NativeRPCValue)], labels: [String]) { (opened, copied, pushed, items.map(\.label)) }
}
actor BackendMacAppHandoffFakeFiles: BackendMacAppHandoffAttachFiles, BackendMacAppHandoffShimFiles {
    var data: [String: Data] = [:]
    var infoByPath: [String: BackendMacAppHandoffFileInfo] = [:]
    var directoryRows: [String: [String]] = [:]
    var modes: [String: Int] = [:]
    var made: [String] = [], removed: [String] = []
    var failWrite = false
    var openerExists = true
    func seed(_ path: String, bytes: Data = Data(), directory: Bool = false, modified: Double = 0) { data[path] = bytes; infoByPath[path] = .init(isDirectory: directory, modifiedMS: modified) }
    func rows(_ directory: String, _ names: [String]) { directoryRows[directory] = names }
    func fail(_ value: Bool) { failWrite = value }
    func exists(_ path: String) -> Bool { path == "/usr/bin/open" ? openerExists : data[path] != nil || made.contains(path) }
    func remove(_ path: String) { removed.append(path); data = data.filter { !$0.key.hasPrefix(path + "/") && $0.key != path }; made.removeAll { $0 == path } }
    func makeDirectory(_ path: String) { made.append(path) }
    func write(_ path: String, text: String, mode: Int) throws { if failWrite { throw BackendMacAppHandoffTestError(message: "disk full") }; data[path] = Data(text.utf8); modes[path] = mode }
    func info(_ path: String) throws -> BackendMacAppHandoffFileInfo { guard let value = infoByPath[path] else { throw BackendMacAppHandoffTestError(message: "not present") }; return value }
    func entries(_ directory: String) throws -> [String] { guard let names = directoryRows[directory] else { throw BackendMacAppHandoffTestError(message: "not present") }; return names }
    func makePasteDirectory(_ directory: String) { made.append(directory); modes[directory] = 0o700 }
    func writePNG(_ path: String, bytes: Data) throws { if failWrite { throw BackendMacAppHandoffTestError(message: "disk full") }; data[path] = bytes; modes[path] = 0o600 }
    func removeFile(_ path: String) { removed.append(path); data[path] = nil }
    func snapshot() -> (data: [String: Data], modes: [String: Int], made: [String], removed: [String]) { (data, modes, made, removed) }
}
actor BackendMacAppHandoffFakeClipboard: BackendMacAppHandoffAttachClipboard {
    let formats: [String: String]
    let png: Data?
    let failing: Set<String>
    var reads: [String] = []
    var imageReads = 0
    init(_ formats: [String: String] = [:], png: Data? = nil, failing: Set<String> = []) { self.formats = formats; self.png = png; self.failing = failing }
    func read(_ format: String) throws -> String { reads.append(format); if failing.contains(format) { throw BackendMacAppHandoffTestError(message: "unknown format") }; return formats[format] ?? "" }
    func imagePNG() -> Data? { imageReads += 1; return png }
    func imageReadCount() -> Int { imageReads }
}
actor BackendMacAppHandoffFakePanels: BackendMacAppHandoffAttachPanels {
    var available = false
    var cancelled = false
    var paths: [String] = []
    var options: NativeRPCValue = .missing
    func windowAvailable(_ ownerID: String) -> Bool { available }
    func open(ownerID: String, options: NativeRPCValue) -> (cancelled: Bool, paths: [String]) { self.options = options; return (cancelled, paths) }
    func set(paths: [String], cancelled: Bool = false) { self.paths = paths; self.cancelled = cancelled }
    func seen() -> NativeRPCValue { options }
}
struct BackendMacAppHandoffFakeBoundaries: BackendMacAppHandoffAttachBoundary {
    let values: [String: BackendDeviceBoundary]
    func boundary(_ sessionID: String, context: NativeRPCContext) -> BackendDeviceBoundary? { values[sessionID] }
}
actor BackendMacAppHandoffFakeBringIn: BackendMacAppHandoffBringIn {
    let answers: [String: String]
    var calls: [(String, String)] = []
    init(_ answers: [String: String] = [:]) { self.answers = answers }
    func bringOne(source: String, folder: String, context: NativeRPCContext) -> String? { calls.append((source, folder)); return answers[source] }
    func count() -> Int { calls.count }
}

func BackendMacAppHandoffNormalized(_ value: NativeRPCValue) -> NativeRPCValue {
    if let fields = value.fields { return .object(fields.sorted { $0.key < $1.key }.map { .init($0.key, BackendMacAppHandoffNormalized($0.value)) }) }
    if let array = value.elements { return .array(array.map(BackendMacAppHandoffNormalized)) }; return value
}
func BackendMacAppHandoffEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T,
                                          _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try left(), b = try right()
        if T.self == NativeRPCValue?.self { XCTAssertEqual((a as! NativeRPCValue?).map(BackendMacAppHandoffNormalized), (b as! NativeRPCValue?).map(BackendMacAppHandoffNormalized), message(), file: file, line: line) }
        else if let a = a as? NativeRPCValue, let b = b as? NativeRPCValue { XCTAssertEqual(BackendMacAppHandoffNormalized(a), BackendMacAppHandoffNormalized(b), message(), file: file, line: line) }
        else if let a = a as? [NativeRPCValue], let b = b as? [NativeRPCValue] { XCTAssertEqual(a.map(BackendMacAppHandoffNormalized), b.map(BackendMacAppHandoffNormalized), message(), file: file, line: line) }
        else { XCTAssertEqual(a, b, message(), file: file, line: line) }
    } catch { XCTFail(error.localizedDescription, file: file, line: line) }
}
