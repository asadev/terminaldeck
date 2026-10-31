import Foundation
import TerminalDeckNativeCore

/// Upload secrets are sent only in protected stdin payloads. They never enter shell argv or public records.
public struct BackendAppsDataS3Upload: Sendable {
    public let endpoint: String
    public let bucket: String
    public let prefix: String
    private let accessKey: String
    private let secretKey: String

    public init(_ value: NativeRPCValue) throws {
        _ = try value.requireObject("backup upload")
        endpoint = try value["endpoint"].requireString("upload endpoint", nonempty: true)
        bucket = try value["bucket"].requireString("upload bucket", nonempty: true)
        prefix = value["prefix"].string ?? "terminaldeck"
        accessKey = try value["accessKey"].requireString("upload access key", nonempty: true)
        secretKey = try value["secretKey"].requireString("upload secret key", nonempty: true)
        try Self.validatePublic(endpoint: endpoint, bucket: bucket, prefix: prefix)
        guard accessKey.range(of: #"\A[A-Za-z0-9/+_=.-]{1,256}\z"#, options: .regularExpression) != nil,
              secretKey.range(of: #"\A[A-Za-z0-9/+_=.-]{1,4096}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Use single-line S3 credentials without spaces or configuration syntax.")
        }
    }

    public var publicValue: NativeRPCValue {
        BackendAppsValidation.object([("endpoint", .string(endpoint)), ("bucket", .string(bucket)), ("prefix", .string(prefix))])
    }

    /// The caller writes this through the existing protected server-file mechanism, never tool output.
    public var protectedCredentials: Data {
        Data("[terminaldeck]\naws_access_key_id = \(accessKey)\naws_secret_access_key = \(secretKey)\n".utf8)
    }

    public static func fromProtectedFile(publicValue: NativeRPCValue, bytes: Data) throws -> BackendAppsDataS3Upload {
        guard let text = String(data: bytes, encoding: .utf8), bytes.count <= 8192 else {
            throw NativeRPCError(code: "state-failed", message: "The saved backup credentials are damaged. Enter new credentials.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count == 3, lines[0] == "[terminaldeck]",
              lines[1].hasPrefix("aws_access_key_id = "), lines[2].hasPrefix("aws_secret_access_key = ") else {
            throw NativeRPCError(code: "state-failed", message: "The saved backup credentials are damaged. Enter new credentials.")
        }
        let access = String(lines[1].dropFirst("aws_access_key_id = ".count))
        let secret = String(lines[2].dropFirst("aws_secret_access_key = ".count))
        do { return try .init(publicValue.setting("accessKey", .string(access)).setting("secretKey", .string(secret))) }
        catch { throw NativeRPCError(code: "state-failed", message: "The saved backup credentials are damaged. Enter new credentials.") }
    }

    public static func validatePublic(endpoint: String, bucket: String, prefix: String) throws {
        guard endpoint.utf8.count <= 512, let components = URLComponents(string: endpoint),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              !endpoint.contains("\n"), !endpoint.contains("\r"), !endpoint.contains("\0"),
              components.port == nil || (1...65535).contains(components.port!),
              !components.path.split(separator: "/").contains(".."),
              bucket.range(of: #"\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z"#, options: .regularExpression) != nil,
              !bucket.contains(".."), !bucket.contains(".-"), !bucket.contains("-."),
              bucket.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) == nil,
              prefix.utf8.count <= 256,
              prefix.isEmpty || prefix.range(of: #"\A[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Use an HTTPS S3 endpoint, a valid bucket and a simple folder prefix.")
        }
    }

    /// HEAD metadata is not proof of content. Read back the object and compare its actual SHA-256 and size.
    public static let uploadAndVerifyScript = #"""
    test ! -L "$dir/.backup-s3-credentials" && test -f "$dir/.backup-s3-credentials"
    test "$(stat -c %a "$dir/.backup-s3-credentials")" = 600
    test "$(stat -c %u "$dir/.backup-s3-credentials")" = "$(id -u)"
    endpoint=$(jq -er '.upload.endpoint' "$dir/backup-policy.json")
    bucket=$(jq -er '.upload.bucket' "$dir/backup-policy.json")
    path=$(jq -er '.upload.prefix' "$dir/backup-policy.json")
    key="${path:+$path/}$app/$id/data"
    export AWS_SHARED_CREDENTIALS_FILE="$dir/.backup-s3-credentials" AWS_CONFIG_FILE=/dev/null
    export AWS_EC2_METADATA_DISABLED=true AWS_DEFAULT_REGION=us-east-1 AWS_PAGER=""
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    aws --profile terminaldeck --endpoint-url "$endpoint" s3api put-object --bucket "$bucket" --key "$key" --body "$work/data" --metadata "sha256=$sum" > "$work/upload-result.json" 2>/dev/null
    version=$(jq -r '.VersionId // empty' "$work/upload-result.json")
    if [ -n "$version" ]; then
      aws --profile terminaldeck --endpoint-url "$endpoint" s3api get-object --bucket "$bucket" --key "$key" --version-id "$version" "$work/upload-check" > /dev/null 2>&1
    else
      aws --profile terminaldeck --endpoint-url "$endpoint" s3api get-object --bucket "$bucket" --key "$key" "$work/upload-check" > /dev/null 2>&1
    fi
    test "$(sha256sum "$work/upload-check" | cut -d ' ' -f 1)" = "$sum"
    test "$(wc -c < "$work/upload-check" | tr -d ' ')" = "$bytes"
    rm -- "$work/upload-check" "$work/upload-result.json"
    uploaded=true
    """#
}

public struct BackendAppsDataBackupPolicy: Sendable {
    public let enabled: Bool
    public let schedule: String?
    public let retention: Int?
    public let upload: BackendAppsDataS3Upload?

    public init(request: NativeRPCValue, preserving existing: BackendAppsDataS3Upload? = nil, previous: NativeRPCValue = .missing, allowUnresolvedPreservation: Bool = false) throws {
        _ = try request.requireObject("backup policy")
        guard let enabled = request["enabled"].bool else { throw NativeRPCError.invalidArguments("Choose whether scheduled backups are enabled.") }
        self.enabled = enabled
        if enabled {
            let schedule = try request["schedule"].requireString("backup schedule", nonempty: true)
            guard Self.validSchedule(schedule), let count = request["retention"].number,
                  count.isFinite, count.rounded() == count, (1...365).contains(count) else {
                throw NativeRPCError.invalidArguments("Choose a systemd calendar and keep between 1 and 365 backups.")
            }
            self.schedule = schedule
            retention = Int(count)
        } else {
            let saved = try Self.publicSaved(previous)
            schedule = saved["schedule"].string
            retention = saved["retention"].number.map(Int.init)
        }
        let requestedUpload = request["upload"]
        if requestedUpload == .missing { upload = existing }
        else if requestedUpload == .null { upload = nil }
        else if requestedUpload["accessKey"] == .missing && requestedUpload["secretKey"] == .missing {
            _ = try requestedUpload.requireObject("backup upload")
            let endpoint = try requestedUpload["endpoint"].requireString("upload endpoint", nonempty: true)
            let bucket = try requestedUpload["bucket"].requireString("upload bucket", nonempty: true)
            let prefix = requestedUpload["prefix"].string ?? "terminaldeck"
            try BackendAppsDataS3Upload.validatePublic(endpoint: endpoint, bucket: bucket, prefix: prefix)
            if let existing {
                guard existing.endpoint == endpoint, existing.bucket == bucket, existing.prefix == prefix else {
                    throw NativeRPCError.invalidArguments("Changing the backup destination needs both new S3 credentials.")
                }
                upload = existing
            } else if allowUnresolvedPreservation { upload = nil }
            else { throw NativeRPCError.invalidArguments("The backup destination needs both S3 credentials.") }
        } else { upload = try BackendAppsDataS3Upload(requestedUpload) }
    }

    public var publicValue: NativeRPCValue {
        var value = BackendAppsValidation.object([("enabled", .bool(enabled))])
        if let schedule, let retention {
            value = value.setting("schedule", .string(schedule)).setting("retention", .number(Double(retention)))
        }
        if let upload { value = value.setting("upload", upload.publicValue) }
        return value
    }

    public static func validSchedule(_ text: String) -> Bool {
        text.utf8.count <= 128 && text.range(of: #"\A[A-Za-z0-9 *,:/._+~\-]+\z"#, options: .regularExpression) != nil
    }

    /// Rebuild a whitelist rather than trusting previously persisted public data or nested credentials.
    public static func publicSaved(_ value: NativeRPCValue) throws -> NativeRPCValue {
        if value.isNullish { return BackendAppsValidation.object([("enabled", .bool(false))]) }
        guard let enabled = value["enabled"].bool else { throw NativeRPCError(code: "state-failed", message: "The saved backup policy is damaged.") }
        var result = BackendAppsValidation.object([("enabled", .bool(enabled))])
        if enabled || !value["schedule"].isNullish || !value["retention"].isNullish {
            guard let schedule = value["schedule"].string, validSchedule(schedule),
                  let retention = value["retention"].number, retention.isFinite, retention.rounded() == retention,
                  (1...365).contains(retention) else { throw NativeRPCError(code: "state-failed", message: "The saved backup policy is damaged.") }
            result = result.setting("schedule", .string(schedule)).setting("retention", .number(retention))
        }
        if !value["upload"].isNullish {
            guard let endpoint = value["upload"]["endpoint"].string, let bucket = value["upload"]["bucket"].string,
                  let prefix = value["upload"]["prefix"].string else { throw NativeRPCError(code: "state-failed", message: "The saved backup upload settings are damaged.") }
            do { try BackendAppsDataS3Upload.validatePublic(endpoint: endpoint, bucket: bucket, prefix: prefix) }
            catch { throw NativeRPCError(code: "state-failed", message: "The saved backup upload settings are damaged.") }
            result = result.setting("upload", BackendAppsValidation.object([("endpoint", .string(endpoint)), ("bucket", .string(bucket)), ("prefix", .string(prefix))]))
        }
        return result
    }
}
