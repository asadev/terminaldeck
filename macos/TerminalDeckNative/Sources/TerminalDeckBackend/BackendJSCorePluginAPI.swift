import Foundation
@preconcurrency import JavaScriptCore

/// The existing plugin API is protocol-1 NDJSON over stdio, not a published SDK
/// module. This bootstrap connects those same bytes to BackendPluginsProcess;
/// BackendPluginsHost.answer remains the only domain permission dispatcher.
public final class BackendJSCorePluginBootstrap: BackendJSCoreRuntimeBootstrap, @unchecked Sendable {
    private var loader: BackendJSCoreModuleLoader?
    public init() {}
    public func install(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws {
        precondition(Thread.isMainThread)
        let files = BackendJSCoreCompatibilityFiles(configuration: configuration)
        try BackendJSCoreCompatibility.install(context: context, configuration: configuration, bridge: bridge, files: files)
        let loader = try BackendJSCoreModuleLoader(context: context, configuration: configuration, files: files)
        try loader.install(); self.loader = loader
        bridge.setInputHandlers(data: { [weak context] bytes in
            _ = context?.objectForKeyedSubscript("__td_input")?.call(withArguments: [bytes.base64EncodedString()])
        }, end: { [weak context] in _ = context?.objectForKeyedSubscript("__td_end")?.call(withArguments: []) })
    }
    public func loadEntry(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws {
        precondition(Thread.isMainThread)
        guard let loader else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_PLUGIN", "The plugin compatibility layer is not installed") }
        _ = try loader.loadEntry()
    }
    public func shutdown(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) {
        precondition(Thread.isMainThread)
        _ = context.objectForKeyedSubscript("__td_dispose")?.call(withArguments: [])
        loader?.dispose(); loader = nil
        for name in ["__td_fs", "__td_encode", "__td_decode", "__td_output", "__td_exit", "__td_timer", "__td_cancel", "__td_input", "__td_end", "__td_dispose", "__td_builtins", "__td_configuration"] {
            _ = context.globalObject.deleteProperty(name)
        }
    }
}
