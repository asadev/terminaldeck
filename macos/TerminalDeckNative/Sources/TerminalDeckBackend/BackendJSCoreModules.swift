import Foundation
@preconcurrency import JavaScriptCore
import TerminalDeckNativeCore

/// CommonJS resolution/cache and checked ESM execution inside one helper VM.
/// No network, package downloads, native addon loading or owner-credential path.
public final class BackendJSCoreModuleLoader {
    public static let maximumModules = 5000
    public static let maximumSourceBytes = 64 * 1024 * 1024
    private let context: JSContext
    private let configuration: BackendJSCoreRuntimeConfiguration
    private let files: BackendJSCoreCompatibilityFiles
    private var bytesLoaded = 0
    private var loadingESM = Set<String>()
    private var cachedPaths = Set<String>()
    private let cache: JSValue
    private var mainModule: JSValue?
    private static let nodeModules: Set<String> = ["assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console", "constants", "crypto", "dgram", "diagnostics_channel", "dns", "dns/promises", "domain", "events", "fs", "fs/promises", "http", "https", "http2", "inspector", "module", "net", "os", "path", "path/posix", "path/win32", "perf_hooks", "process", "punycode", "querystring", "readline", "readline/promises", "repl", "stream", "stream/promises", "stream/web", "string_decoder", "timers", "timers/promises", "tls", "trace_events", "tty", "url", "util", "util/types", "v8", "vm", "wasi", "worker_threads", "zlib", "test"]
    public init(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, files: BackendJSCoreCompatibilityFiles) throws {
        precondition(Thread.isMainThread)
        self.context = context; self.configuration = configuration; self.files = files
        guard let cache = context.evaluateScript("Object.create(null)") else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "Module cache could not be created") }
        self.cache = cache
    }
    public func install() throws {
        precondition(Thread.isMainThread)
        guard let builtins = context.objectForKeyedSubscript("__td_builtins"), !builtins.isUndefined else {
            throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "Plugin compatibility globals were not installed")
        }
        let create: @convention(block) (String) -> JSValue? = { [weak self] path in
            guard let self else { return nil }
            do {
                guard path.hasPrefix("/") || path.hasPrefix("file:") else { throw BackendJSCoreCompatibilityFailure("ERR_INVALID_ARG_VALUE", "module.createRequire requires a file URL or absolute filename") }
                let parent = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
                guard let parent, parent.isFileURL else { throw BackendJSCoreCompatibilityFailure("ERR_INVALID_ARG_VALUE", "module.createRequire requires a file URL or absolute filename") }
                _ = try self.files.checkedEntry(parent.path)
                return try self.requireFunction(parent: parent)
            } catch { BackendJSCoreCompatibility.setException(self.context, error); return nil }
        }
        let isBuiltin: @convention(block) (String) -> Bool = { specifier in Self.nodeModules.contains(Self.builtinName(specifier)) }
        let module = JSValue(newObjectIn: context)
        module?.setObject(create, forKeyedSubscript: "createRequire" as NSString)
        module?.setObject(isBuiltin, forKeyedSubscript: "isBuiltin" as NSString)
        module?.setValue(Self.nodeModules.sorted().filter { !$0.contains("/") }, forProperty: "builtinModules")
        builtins.setObject(module, forKeyedSubscript: "module" as NSString)
        if let path = builtins.forProperty("path") { builtins.setObject(path, forKeyedSubscript: "path/posix" as NSString) }
        try BackendJSCoreCompatibility.check(context)
    }
    @discardableResult public func loadEntry() throws -> JSValue {
        try load(configuration.entryURL, importing: false, main: true)
    }
    public func resolve(_ specifier: String, from parent: URL, importing: Bool = false) throws -> URL {
        guard !specifier.isEmpty, specifier.utf8.count <= 4096, !specifier.contains("\0"), !specifier.contains("\\") else {
            throw BackendJSCoreCompatibilityFailure("ERR_INVALID_MODULE_SPECIFIER", "Invalid plugin module specifier: \(specifier)")
        }
        let directory = parent.deletingLastPathComponent()
        if specifier.hasPrefix("./") || specifier.hasPrefix("../") || specifier.hasPrefix("/") {
            let target = specifier.hasPrefix("/") ? URL(fileURLWithPath: specifier) : directory.appendingPathComponent(specifier)
            if let found = try fileOrDirectory(target, importing: importing, depth: 0) { return found }
            throw missing(specifier, parent)
        }
        if specifier.hasPrefix("file:") {
            guard importing, let target = URL(string: specifier), target.isFileURL else { throw BackendJSCoreCompatibilityFailure("ERR_INVALID_MODULE_SPECIFIER", "Only ESM file: imports are supported") }
            if let found = try fileOrDirectory(target, importing: true, depth: 0) { return found }
            throw missing(specifier, parent)
        }
        guard !specifier.contains(":") else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "URL module imports are not supported: \(specifier)") }
        let parts = specifier.split(separator: "/", omittingEmptySubsequences: false)
        let packageCount = specifier.hasPrefix("@") ? 2 : 1
        guard parts.count >= packageCount, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BackendJSCoreCompatibilityFailure("ERR_INVALID_MODULE_SPECIFIER", "Invalid package specifier: \(specifier)") }
        let name = parts.prefix(packageCount).joined(separator: "/")
        let subpath = parts.count == packageCount ? "." : "./" + parts.dropFirst(packageCount).joined(separator: "/")
        var current = directory.standardizedFileURL
        let root = configuration.folderURL.standardizedFileURL.path
        while current.path == root || current.path.hasPrefix(root + "/") {
            let package = current.appendingPathComponent("node_modules").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: package.path) {
                let manifest = try packageJSON(package)
                if manifest["exports"] != .missing {
                    let selected: NativeRPCValue
                    if let fields = manifest["exports"].fields, fields.contains(where: { $0.key.hasPrefix(".") }) {
                        if fields.contains(where: { $0.key.contains("*") }) { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "Package export patterns are not supported: \(name)") }
                        selected = manifest["exports"][subpath]
                    } else { selected = subpath == "." ? manifest["exports"] : .missing }
                    guard let target = try exportTarget(selected, importing: importing), target.hasPrefix("./"), !target.split(separator: "/").contains("..") else {
                        throw BackendJSCoreCompatibilityFailure("ERR_PACKAGE_PATH_NOT_EXPORTED", "Package subpath \(subpath) is not supported/exported by \(name)")
                    }
                    if let result = try fileOrDirectory(package.appendingPathComponent(String(target.dropFirst(2))), importing: importing, depth: 0) { return result }
                    throw missing(specifier, parent)
                }
                let candidate = subpath == "." ? package : package.appendingPathComponent(String(subpath.dropFirst(2)))
                if let result = try fileOrDirectory(candidate, importing: importing, depth: 0) { return result }
            }
            if current.path == root { break }; current.deleteLastPathComponent()
        }
        throw missing(specifier, parent)
    }
    private func fileOrDirectory(_ target: URL, importing: Bool, depth: Int) throws -> URL? {
        guard depth <= 24 else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "Package main resolution exceeds 24 folders") }
        let checked = try files.checked(target.standardizedFileURL.path)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: checked.path, isDirectory: &directory), !directory.boolValue { return try validateExtension(checked) }
        for suffix in ["js", "cjs", "mjs", "json", "node"] {
            let candidate = URL(fileURLWithPath: checked.path + "." + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { return try validateExtension(candidate) }
        }
        guard directory.boolValue else { return nil }
        let manifest = try packageJSON(checked)
        if let main = manifest["main"].string, !main.isEmpty {
            guard !main.hasPrefix("/"), !main.split(separator: "/").contains(".."), !main.contains("\\") else { throw BackendJSCoreCompatibilityFailure("ERR_INVALID_PACKAGE_CONFIG", "Package main must remain inside its own package folder") }
            if let result = try fileOrDirectory(checked.appendingPathComponent(main), importing: importing, depth: depth + 1) { return result }
        }
        for suffix in ["js", "cjs", "mjs", "json", "node"] {
            let candidate = checked.appendingPathComponent("index." + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { return try validateExtension(candidate) }
        }
        return nil
    }
    private func validateExtension(_ file: URL) throws -> URL {
        let ext = file.pathExtension.lowercased()
        guard ext != "node" else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_NATIVE_ADDON", "Native Node addon cannot run in JavaScriptCore: \(file.lastPathComponent)") }
        guard ["js", "mjs", "cjs", "json"].contains(ext) else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "Unsupported plugin module extension: .\(ext)") }
        return file
    }
    private func packageJSON(_ directory: URL) throws -> NativeRPCValue {
        let path = directory.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return .object([]) }
        guard let value = try? NativeRPCValue.parseJSON(files.read(path.path), maximumBytes: 65536), value.fields != nil else {
            throw BackendJSCoreCompatibilityFailure("ERR_INVALID_PACKAGE_CONFIG", "Invalid/oversized package.json: \(path.path)")
        }
        return value
    }
    private func exportTarget(_ value: NativeRPCValue, importing: Bool) throws -> String? {
        if let string = value.string { return string }
        if value == .missing || value == .null { return nil }
        guard let fields = value.fields else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "Package exports arrays and nonliteral targets are not supported") }
        for field in fields where ["node", importing ? "import" : "require", "default"].contains(field.key) {
            if let result = try exportTarget(field.value, importing: importing) { return result }
        }
        return nil
    }
    private func esm(_ file: URL) throws -> Bool {
        if file.pathExtension.lowercased() == "mjs" { return true }
        if file.pathExtension.lowercased() == "cjs" { return false }
        var directory = file.deletingLastPathComponent()
        let root = configuration.folderURL.path
        while directory.path == root || directory.path.hasPrefix(root + "/") {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path) { return try packageJSON(directory)["type"].string == "module" }
            if directory.path == root { break }; directory.deleteLastPathComponent()
        }
        return false
    }
    private func requireFunction(parent: URL) throws -> JSValue {
        let require: @convention(block) (String) -> JSValue? = { [weak self] specifier in
            guard let self else { return nil }
            do { return try self.required(specifier, parent: parent, importing: false) }
            catch { BackendJSCoreCompatibility.setException(self.context, error); return nil }
        }
        guard let value = JSValue(object: require, in: context) else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "require function could not be created") }
        let resolve: @convention(block) (String) -> String = { [weak self] specifier in
            guard let self else { return "" }
            do {
                if Self.nodeModules.contains(Self.builtinName(specifier)) { return specifier }
                return try self.resolve(specifier, from: parent).path
            } catch { BackendJSCoreCompatibility.setException(self.context, error); return "" }
        }
        value.setObject(resolve, forKeyedSubscript: "resolve" as NSString)
        value.setValue(cache, forProperty: "cache"); value.setValue(mainModule, forProperty: "main")
        return value
    }
    private func required(_ specifier: String, parent: URL, importing: Bool) throws -> JSValue {
        let name = Self.builtinName(specifier)
        if Self.nodeModules.contains(name) || specifier.hasPrefix("node:") {
            guard let value = context.objectForKeyedSubscript("__td_builtins")?.forProperty(name), !value.isUndefined else {
                throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "Node module \(specifier) is not supported by the JavaScriptCore plugin runtime")
            }
            if importing { return try namespace(value) }; return value
        }
        let url = try resolve(specifier, from: parent, importing: importing)
        if importing && url.pathExtension.lowercased() == "json" {
            throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_ESM_UNSUPPORTED", "ESM JSON import attributes are not supported; CommonJS JSON require is supported")
        }
        let value = try load(url, importing: importing)
        if importing, !(try esm(url)), url.pathExtension != "json" { return try namespace(value) }
        return value
    }
    private func namespace(_ value: JSValue) throws -> JSValue {
        let factory = context.evaluateScript("(function(value){const ns=Object.create(null); Object.defineProperty(ns,'default',{value,enumerable:true}); if(value&&(typeof value==='object'||typeof value==='function'))for(const key of Object.keys(value))if(key!=='default')Object.defineProperty(ns,key,{value:value[key],enumerable:true});return Object.freeze(ns);})")
        guard let result = factory?.call(withArguments: [value]) else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "Module namespace could not be created") }
        try BackendJSCoreCompatibility.check(context); return result
    }
    private func load(_ url: URL, importing: Bool, main: Bool = false) throws -> JSValue {
        precondition(Thread.isMainThread)
        let path = url.standardizedFileURL.path
        if loadingESM.contains(path) { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_ESM_CYCLE", "Cyclic ESM imports are not supported: \(url.lastPathComponent)") }
        if let record = cache.forProperty(path), !record.isUndefined, let value = record.forProperty("exports") { return value }
        cachedPaths.remove(path) // A plugin may have deleted require.cache[path].
        guard cachedPaths.count < Self.maximumModules else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "At most \(Self.maximumModules) plugin modules may be cached") }
        let data = try files.read(path)
        guard bytesLoaded + data.count <= Self.maximumSourceBytes else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "Plugin module sources exceed \(Self.maximumSourceBytes) bytes") }
        bytesLoaded += data.count
        let isESM = try esm(url)
        guard let module = JSValue(newObjectIn: context), let exports = context.evaluateScript(isESM ? "Object.create(null)" : "({})") else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "Module could not be allocated") }
        module.setValue(path, forProperty: "id"); module.setValue(path, forProperty: "filename"); module.setValue(exports, forProperty: "exports"); module.setValue(false, forProperty: "loaded")
        cache.setValue(module, forProperty: path)
        cachedPaths.insert(path)
        if main { mainModule = module }
        do {
            if url.pathExtension.lowercased() == "json" {
                guard let text = String(data: data, encoding: .utf8), let parse = context.objectForKeyedSubscript("JSON")?.forProperty("parse"), let value = parse.call(withArguments: [text]) else { throw BackendJSCoreCompatibilityFailure("ERR_INVALID_PACKAGE_CONFIG", "Invalid JSON module") }
                try BackendJSCoreCompatibility.check(context); module.setValue(value, forProperty: "exports")
            } else {
                guard var text = String(data: data, encoding: .utf8) else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "Plugin module must be UTF-8 JavaScript: \(url.lastPathComponent)") }
                if text.hasPrefix("\u{feff}") { text.removeFirst() }
                if text.hasPrefix("#!") { text = text.firstIndex(of: "\n").map { String(text[$0...]) } ?? "" }
                if isESM {
                    loadingESM.insert(path); defer { loadingESM.remove(path) }
                    let transformed = try BackendJSCoreModulesESM.transform(text)
                    let importer: @convention(block) (String) -> JSValue? = { [weak self] specifier in
                        guard let self else { return nil }
                        do { return try self.required(specifier, parent: url, importing: true) }
                        catch { BackendJSCoreCompatibility.setException(self.context, error); return nil }
                    }
                    let wrapper = context.evaluateScript("(function(__td_import,__td_exports){'use strict';\n" + transformed + "\nreturn Object.freeze(__td_exports);})", withSourceURL: url)
                    try BackendJSCoreCompatibility.check(context)
                    guard let result = wrapper?.call(withArguments: [importer, exports]) else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "ESM module could not be evaluated") }
                    try BackendJSCoreCompatibility.check(context); module.setValue(result, forProperty: "exports")
                } else {
                    let require = try requireFunction(parent: url)
                    let candidate = context.evaluateScript("(function(exports,require,module,__filename,__dirname){\n" + text + "\n})", withSourceURL: url)
                    try BackendJSCoreCompatibility.check(context)
                    guard let wrapper = candidate, wrapper.call(withArguments: [exports, require, module, path, url.deletingLastPathComponent().path]) != nil else {
                        try BackendJSCoreCompatibility.check(context)
                        throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "CommonJS module could not be evaluated")
                    }
                    try BackendJSCoreCompatibility.check(context)
                }
            }
            module.setValue(true, forProperty: "loaded")
            return module.forProperty("exports") ?? exports
        } catch { _ = cache.deleteProperty(path); cachedPaths.remove(path); throw error }
    }
    public func dispose() {
        precondition(Thread.isMainThread); loadingESM.removeAll(); mainModule = nil
        for path in cachedPaths { _ = cache.deleteProperty(path) }; cachedPaths.removeAll()
    }
    private static func builtinName(_ value: String) -> String { value.hasPrefix("node:") ? String(value.dropFirst(5)) : value }
    private func missing(_ name: String, _ parent: URL) -> BackendJSCoreCompatibilityFailure { .init("MODULE_NOT_FOUND", "Cannot find module '\(name)' from \(parent.lastPathComponent)") }
}
