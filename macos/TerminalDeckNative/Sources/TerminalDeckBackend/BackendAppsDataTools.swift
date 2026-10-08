import Foundation
import TerminalDeckNativeCore

/// DKA appends these additions to its existing Apps MCP catalogue. The eight
/// migrated data tools already exist there and must not be registered twice.
public enum BackendAppsDataTools {
    /// Upload omission preserves saved settings; JSON null removes them. The
    /// existing small schema validator has no anyOf support, so DKA also calls
    /// validateBackupUpload before consent when this argument is present.
    public static var backupUploadSchema: NativeRPCValue {
        .object([.init("anyOf", .array([
            .object([.init("type", .string("null"))]), uploadObjectSchema
        ]))])
    }

    private static var uploadObjectSchema: NativeRPCValue {
        let string = NativeRPCValue.object([.init("type", .string("string")), .init("minLength", .number(1)), .init("maxLength", .number(4096))])
        return .object([
            .init("type", .string("object")),
            .init("properties", .object([
                .init("endpoint", string.setting("maxLength", .number(512))),
                .init("bucket", string.setting("maxLength", .number(63))),
                .init("prefix", string.setting("minLength", .number(0)).setting("maxLength", .number(256))),
                .init("accessKey", string.setting("maxLength", .number(256))), .init("secretKey", string)
            ])),
            .init("required", .array([.string("endpoint"), .string("bucket")])),
            .init("additionalProperties", .bool(false))
        ])
    }

    public static func validateBackupUpload(_ value: NativeRPCValue) throws {
        if value == .null { return }
        try BackendDockerMCPArguments.validate(value, schema: uploadObjectSchema)
        guard value.has("accessKey") == value.has("secretKey") else {
            throw NativeRPCError.invalidArguments("Replace both S3 credentials together, or leave both unchanged.")
        }
        let endpoint = try value["endpoint"].requireString("upload endpoint", nonempty: true)
        let bucket = try value["bucket"].requireString("upload bucket", nonempty: true)
        let prefix = value["prefix"].string ?? "terminaldeck"
        try BackendAppsDataS3Upload.validatePublic(endpoint: endpoint, bucket: bucket, prefix: prefix)
        if value.has("accessKey") { _ = try BackendAppsDataS3Upload(value) }
    }

    public static func definitions() -> [BackendAppsMCPCatalogue.Definition] {
        let identifier = NativeRPCValue.object([
            .init("type", .string("string")), .init("minLength", .number(1)), .init("maxLength", .number(256))
        ])
        let appID = identifier.setting("maxLength", .number(48))
            .setting("pattern", .string("^[a-z][a-z0-9-]{0,47}$"))
        return [.init(
            id: "apps.databases.connection", channel: "apps:databases:connection", tier: .read,
            description: "Read a managed database's private host, port, database and username. The password stays masked; no public database port is opened.",
            properties: .object([.init("serverId", identifier), .init("appId", appID)]),
            required: ["serverId", "appId"], destructive: false
        ), .init(
            id: "apps.databases.bind", channel: "apps:databases:bind", tier: .alter,
            description: "Save a managed database connection in another app's protected settings on the same server, without revealing credentials. Replaces the selected setting; deploy the app afterward to apply it. Requires the person's approval.",
            properties: .object([
                .init("serverId", identifier), .init("appId", appID), .init("targetAppId", appID),
                .init("key", identifier.setting("maxLength", .number(128)).setting("pattern", .string("^[A-Za-z_][A-Za-z0-9_]{0,127}$")))
            ]),
            required: ["serverId", "appId", "targetAppId"], destructive: false
        )]
    }
}
