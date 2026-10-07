import Foundation
@preconcurrency import JavaScriptCore
import Testing
@testable import TerminalDeckBackend

@Suite("CJS resolution and explicitly checked ESM grammar")
struct BackendJSCoreModulesTests: Sendable {
    @Test func staticImportsAndImmutableExportsKeepStringsCommentsAndRegexUntouched() throws {
        let source = #"""
        import fs from 'node:fs';
        import { readFileSync as read } from 'node:fs';
        import * as path from 'node:path';
        // export let danger = 1;
        const quoted = "export default danger;";
        const expression = /export\s+default/;
        export const answer = 42;
        export { quoted as sentence };
        export default answer;
        """#
        let result = try BackendJSCoreModulesESM.transform(source)
        #expect(result.contains("// export let danger = 1;"))
        #expect(result.contains(#""export default danger;""#))
        #expect(result.contains(#"/export\s+default/"#))
        #expect(result.contains("__td_import(\"node:fs\")"))
        #expect(result.contains("Object.defineProperty(__td_exports,\"answer\""))
        #expect(result.contains("Object.defineProperty(__td_exports,\"sentence\""))
        #expect(result.contains("Object.defineProperty(__td_exports,\"default\""))
    }
    @Test func unsupportedESMFormsRefuseClearlyRatherThanRegexRewrite() {
        for source in ["export let value = 1;", "export var value = 1;", "export function value() {};", "export * from './other.js';",
                       "export { x } from './other.js';", "const x = await work();", "import('./other.js');", "const x = import.meta.url;",
                       "import x from './x.json' with {type:'json'};", "import x from './x.js'", "const value = `a${x}`; export const x = 1;",
                       "let x=1; export {x};", "import {x} from './x.js'; export {x};"] {
            #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try BackendJSCoreModulesESM.transform(source) }
        }
    }
    @Test func controlConditionRegexCannotInventExportsAndMemberNamedExportStaysAnExpression() throws {
        let regex = "if (true) /;export default 1/.test(''); export const ok=2;"
        let transformed = try BackendJSCoreModulesESM.transform(regex)
        #expect(transformed.contains("/;export default 1/"))
        #expect(!transformed.contains("Object.defineProperty(__td_exports,\"default\""))
        #expect(transformed.contains("Object.defineProperty(__td_exports,\"ok\""))
        let member = try BackendJSCoreModulesESM.transform("const obj={export:1}; export const value=obj.export;")
        #expect(member.contains("const value=obj.export;"))
        #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try BackendJSCoreModulesESM.transform("{} /;export default 1/.test(''); export const ok=2;") }
    }
    @Test func staticImportInitializationIsHoistedBeforeEarlierExecutableStatements() throws {
        let transformed = try BackendJSCoreModulesESM.transform("const before=globalThis.flag; import './dep.mjs'; export {before};")
        let dependency = try #require(transformed.range(of: "__td_import(\"./dep.mjs\")"))
        let body = try #require(transformed.range(of: "const before=globalThis.flag"))
        #expect(dependency.lowerBound < body.lowerBound)
    }
    @MainActor @Test func realCheckedModulesHonorImportSideEffectOrderAndRefuseMissingExportInsteadOfUndefined() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendJSCoreLinking-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), plugin = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("globalThis.flag=42; export const present=1;".utf8).write(to: plugin.appendingPathComponent("dep.mjs"))
        try Data("const before=globalThis.flag; import './dep.mjs'; export {before};".utf8).write(to: plugin.appendingPathComponent("main.mjs"))
        let config = try BackendJSCoreRuntimeConfiguration(entryURL: plugin.appendingPathComponent("main.mjs"), folderURL: plugin, dataURL: data, environment: [:])
        let context = try #require(JSContext()); context.evaluateScript("globalThis.__td_builtins = Object.create(null);")
        let loader = try BackendJSCoreModuleLoader(context: context, configuration: config, files: .init(configuration: config)); try loader.install()
        #expect(try loader.loadEntry().forProperty("before")?.toInt32() == 42)
        loader.dispose()
        try Data("import {absent} from './dep.mjs'; export const value=absent;".utf8).write(to: config.entryURL)
        do { _ = try loader.loadEntry(); Issue.record("A missing named import was silently accepted") }
        catch let error as BackendJSCoreCompatibilityFailure { #expect(error.code == "ERR_JSCORE_ESM_MISSING_EXPORT") }
        loader.dispose()
    }
    @MainActor @Test func commonJSCachingCyclesJSONAndRelativeImportsUseActualModuleExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendJSCoreModules-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), plugin = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("exports.name='a'; exports.b=require('./b').name;".utf8).write(to: plugin.appendingPathComponent("a.js"))
        try Data("exports.name='b'; exports.a=require('./a').name;".utf8).write(to: plugin.appendingPathComponent("b.js"))
        try Data("{\"value\":42}".utf8).write(to: plugin.appendingPathComponent("value.json"))
        try Data("const a=require('./a'); module.exports={a:a.name,b:a.b,same:a===require('./a'),value:require('./value.json').value};".utf8).write(to: plugin.appendingPathComponent("main.cjs"))
        let configuration = try BackendJSCoreRuntimeConfiguration(entryURL: plugin.appendingPathComponent("main.cjs"), folderURL: plugin, dataURL: data, environment: [:])
        let context = try #require(JSContext()); context.evaluateScript("globalThis.__td_builtins = Object.create(null);")
        let loader = try BackendJSCoreModuleLoader(context: context, configuration: configuration, files: .init(configuration: configuration))
        try loader.install(); let result = try loader.loadEntry()
        #expect(result.forProperty("a")?.toString() == "a"); #expect(result.forProperty("b")?.toString() == "b")
        #expect(result.forProperty("same")?.toBool() == true); #expect(result.forProperty("value")?.toInt32() == 42)
        loader.dispose()
    }
    @MainActor @Test func checkedESMCanImportImmutableSiblingButRefusesCyclesAndNativeAddons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendJSCoreESM-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), plugin = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("export const value = 42;".utf8).write(to: plugin.appendingPathComponent("other.mjs"))
        try Data("import {value} from './other.mjs'; export const answer = value;".utf8).write(to: plugin.appendingPathComponent("main.mjs"))
        let config = try BackendJSCoreRuntimeConfiguration(entryURL: plugin.appendingPathComponent("main.mjs"), folderURL: plugin, dataURL: data, environment: [:])
        let context = try #require(JSContext()); context.evaluateScript("globalThis.__td_builtins = Object.create(null);")
        let loader = try BackendJSCoreModuleLoader(context: context, configuration: config, files: .init(configuration: config)); try loader.install()
        #expect(try loader.loadEntry().forProperty("answer")?.toInt32() == 42)
        loader.dispose()
        try Data("import {answer} from './main.mjs'; export const value = answer;".utf8).write(to: plugin.appendingPathComponent("other.mjs"))
        #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try loader.loadEntry() }
        try Data().write(to: plugin.appendingPathComponent("addon.node"))
        #expect(throws: BackendJSCoreCompatibilityFailure.self) { _ = try loader.resolve("./addon.node", from: config.entryURL) }
        loader.dispose()
    }
}
