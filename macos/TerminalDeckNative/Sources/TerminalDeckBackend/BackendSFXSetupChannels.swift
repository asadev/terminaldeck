import Foundation
import TerminalDeckNativeCore

public enum BackendSFXSetupChannels {
    public static let channels = [SFXSetupWire.preview, SFXSetupWire.prepare, SFXSetupWire.apply]
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendSFXSetupService) async throws {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                try context.require(channel == SFXSetupWire.preview ? "fixed.read" : "fixed.write")
                let root = try BackendStaysFixedWhere.folder(context.argument(0, in: args))
                if channel == SFXSetupWire.apply {
                    let token = try context.argument(1, in: args).requireString("setup preview token", nonempty: true)
                    return try await service.apply(root, token: token)
                }
                let options = context.argument(1, in: args)
                if !options.isNullish {
                    guard options.fields != nil, options.fields!.allSatisfy({ $0.key == "checkCommand" }), options["checkCommand"].isNullish || options["checkCommand"].string != nil else {
                        throw NativeRPCError.invalidArguments("Setup options must contain only an optional checkCommand string.")
                    }
                }
                return try await service.preview(root, checkCommand: options["checkCommand"].string, prepareRuntime: channel == SFXSetupWire.prepare)
            }
        }
    }
}
