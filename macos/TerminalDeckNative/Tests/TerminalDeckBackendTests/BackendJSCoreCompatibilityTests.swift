import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("JSCore encoding and source confinement filesystem rules")
struct BackendJSCoreCompatibilityTests: Sendable {
    private func scratch() throws -> (URL, BackendJSCoreCompatibilityFiles) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendJSCoreCompatibility-" + UUID().uuidString)
        let plugin = root.appendingPathComponent("plugin"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let config = try BackendJSCoreRuntimeConfiguration(entryURL: plugin.appendingPathComponent("main.js"), folderURL: plugin, dataURL: data,
            environment: ["OPENAI_API_KEY": "never-inherit", "LANG": "en_US.UTF-8"])
        return (root, .init(configuration: config))
    }
    @Test func actualEncodingsRoundTripAndUnknownEncodingIsExplicit() throws {
        let text = "hello 😀"
        #expect(try BackendJSCoreCompatibility.string(BackendJSCoreCompatibility.bytes(text, encoding: "utf8"), encoding: "utf-8") == text)
        #expect(try BackendJSCoreCompatibility.string(BackendJSCoreCompatibility.bytes(text, encoding: "utf16le"), encoding: "ucs-2") == text)
        #expect(try BackendJSCoreCompatibility.bytes("abxx", encoding: "hex") == Data([171]))
        #expect(try BackendJSCoreCompatibility.bytes("YQ==\n", encoding: "base64") == Data([97]))
        #expect(try BackendJSCoreCompatibility.string(Data([0xff]), encoding: "hex") == "ff")
        #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try BackendJSCoreCompatibility.bytes("hello", encoding: "unknown-encoding") }
    }
    @Test func readsPluginCodeWritesOnlyDataAndRejectsOutsideCanary() throws {
        let (root, files) = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let main = files.configuration.entryURL, data = files.configuration.dataURL.appendingPathComponent("state.json"), outside = root.appendingPathComponent("owner.txt")
        try Data("plugin-code".utf8).write(to: main); try Data("owner-secret".utf8).write(to: outside)
        #expect(try files.read(main.path) == Data("plugin-code".utf8))
        #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try files.read(outside.path) }
        _ = try files.perform("writeFile", params: .object([.init("path", .string(data.path)), .init("data", .string(Data("{}".utf8).base64EncodedString()))]))
        #expect(try files.read(data.path) == Data("{}".utf8))
        #expect(throws: BackendJSCoreCompatibilityFailure.self) {
            _ = try files.perform("writeFile", params: .object([.init("path", .string(main.path)), .init("data", .string("YQ=="))]))
        }
        #expect(files.configuration.environment["OPENAI_API_KEY"] == nil)
    }
    @Test func invalidModesFailWithoutIntegerConversionTraps() throws {
        let (root, files) = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        for value in [Double.greatestFiniteMagnitude, Double.nan, -1, 1.5, 4096] {
            for method in ["writeFile", "mkdir"] {
                let answer = files.response(method, json: NativeRPCValue.object([.init("path", .string(files.configuration.dataURL.appendingPathComponent("mode").path)),
                    .init("data", .string("YQ==")), .init("mode", .number(value))]).compact)
                let parsed = try NativeRPCValue.parseJSON(Data(answer.utf8))
                // Nonfinite values may serialize as null; every invalid mode
                // must still produce a real refusal rather than a conversion trap.
                #expect(parsed["ok"].bool == false)
            }
        }
    }
    @Test func lstatUnlinkRmAndRenamePreserveSymlinkEntriesAndNeverRemoveTheirTarget() throws {
        let (root, files) = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("outside.txt")
        try Data("keep-me".utf8).write(to: target)
        for operation in ["unlink", "rm", "rename"] {
            let link = files.configuration.dataURL.appendingPathComponent(operation + ".link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let info = try files.perform("lstat", params: .object([.init("path", .string(link.path))]))
            #expect(info["isSymbolicLink"].bool == true)
            #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try files.read(link.path) }
            let moved = files.configuration.dataURL.appendingPathComponent(operation + ".moved")
            _ = try files.perform(operation, params: .object([.init("path", .string(link.path)), .init("to", .string(moved.path))]))
            #expect(try Data(contentsOf: target) == Data("keep-me".utf8))
            if operation == "rename" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: moved.path) == target.path) }
        }
    }
    @Test func danglingDataSymlinkCanBeRemovedAndDataRootCannotBeRemoved() throws {
        let (root, files) = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let link = files.configuration.dataURL.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        _ = try files.perform("rm", params: .object([.init("path", .string(link.path)), .init("force", .bool(true))]))
        #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try files.perform("rm", params: .object([.init("path", .string(files.configuration.dataURL.path)), .init("recursive", .bool(true))])) }
    }
}
