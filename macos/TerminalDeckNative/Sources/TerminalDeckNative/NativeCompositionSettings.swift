import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Native metadata and UI services for the same settings actor used by core
/// and by the transitional Node settings storage facade.
@MainActor
enum NativeCompositionSettings {
    static func environment(backend: BackendCompositionRoot, configuration: EngineConfiguration,
                            browser: (any BackendAppSettingsBrowserData)? = nil) -> BackendAppSettingsEnvironment {
        let bundle = Bundle.main
        var node = "", package: [String: Any] = [:]
        // Node-free app (D14): no Node version; the build stages the root
        // package.json's public fields as web/package.json for About.
        if case .nativeOnly(let web) = configuration.source {
            if let data = try? Data(contentsOf: web.resourcesRoot.appendingPathComponent("web/package.json")), data.count <= 1024 * 1024 {
                package = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
        }
        let recordedRepository = BackendAppSettingsChannels.repositoryURL((try? NativeRPCValue.fromFoundation(package["repository"])) ?? .missing)
        let nodeVersion = node
        let recordedLicense = package["license"] as? String
        let recordedHomepage = package["homepage"] as? String
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let packaged = bundle.bundleURL.pathExtension == "app"
        let recordedFeed = bundle.object(forInfoDictionaryKey: "TDNativeUpdateFeed") as? String
        let registry = backend.registry
        return .init(userData: backend.dataRoot, logs: backend.dataRoot.appendingPathComponent("logs", isDirectory: true),
            trace: backend.dataRoot.appendingPathComponent("ipc-trace.log"), browser: browser,
            about: {
                let update = await MainActor.run { () -> (phase: String, reason: String?) in
                    let state = NativeAppUpdater.shared.rawState
                    return (state["phase"] as? String ?? "", state["reason"] as? String ?? state["message"] as? String)
                }
                let phase = update.phase, reason = update.reason
                return .object([.init("name", .string(BackendSharedBrand.name)), .init("tagline", .string(BackendSharedBrand.tagline)),
                    .init("version", .string(version)), .init("electron", .string("")), .init("chrome", .string("")),
                    .init("chromium", .string("")), .init("node", .string(nodeVersion)), .init("v8", .string("")),
                    .init("packaged", .bool(packaged)), .init("platform", .string("darwin")),
                    .init("arch", .string(NativeCompositionSettings.architecture)),
                    .init("license", recordedLicense.map(NativeRPCValue.string) ?? .null),
                    .init("repository", recordedRepository.map(NativeRPCValue.string) ?? .null),
                    .init("homepage", recordedHomepage.map(NativeRPCValue.string) ?? .null),
                    .init("updates", .object([.init("packaged", .bool(packaged)), .init("feedPresent", .bool(recordedFeed != nil)),
                        .init("checkable", .bool(packaged && phase != "unsupported")),
                        .init("detail", .string(reason ?? "The native updater checks the configured release feed; downloads remain explicit."))]))])
            }, publish: { channel, value in
                do { try await registry.publish(channel, arguments: [value]) }
                catch { NSLog("[native settings] saved; event delivery failed: %@", error.localizedDescription) }
            })
    }
    nonisolated static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x64"
        #else
        "unknown"
        #endif
    }
}
