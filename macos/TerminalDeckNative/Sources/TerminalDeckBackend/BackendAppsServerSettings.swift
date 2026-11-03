import Foundation
import TerminalDeckNativeCore

/// Settings that live ON the server (root-only files under /etc/<base>).
/// Secrets are written once and only ever come back as "set"/masked.
public enum BackendAppsServerSettings {
    public static let mask = "••••••••"
    public static let secretKeys = ["botToken", "password", "secret", "token"]
    public static let defaultCleanupSchedule = "Sun *-*-* 04:00:00"

    // MARK: alerts

    /// Validates an alerts request. Secret fields that are omitted, null or the
    /// mask keep the server's saved value (merged on the server, never read here).
    public static func alerts(_ request: NativeRPCValue) throws -> NativeRPCValue {
        let allowed: Set<String> = ["serverId", "enabled", "channels", "thresholds", "remindMinutes", "watch"]
        guard let fields = request.fields, fields.allSatisfy({ allowed.contains($0.key) }) else { throw NativeRPCError.invalidArguments("Alert settings contain unsupported fields.") }
        var result: [(String, NativeRPCValue)] = [("enabled", .bool(request["enabled"].bool ?? true))]
        let channels = request["channels"].isNullish ? [] : try request["channels"].requireArray("Alert channels")
        guard channels.count <= 10 else { throw NativeRPCError.invalidArguments("Use at most 10 alert channels.") }
        var ids = Set<String>(), cleaned: [NativeRPCValue] = []
        for channel in channels {
            let value = try alertChannel(channel)
            guard ids.insert(value["id"].string!).inserted else { throw NativeRPCError.invalidArguments("Each alert channel needs its own name.") }
            cleaned.append(value)
        }
        result.append(("channels", .array(cleaned)))
        let thresholds = request["thresholds"]
        result.append(("thresholds", BackendAppsValidation.object([
            ("diskPercent", .number(Double(try bounded(thresholds["diskPercent"], 85, 50...99, "disk limit")))),
            ("memoryPressure", .number(Double(try bounded(thresholds["memoryPressure"], 20, 1...100, "memory limit")))),
            ("certDays", .number(Double(try bounded(thresholds["certDays"], 14, 1...60, "certificate warning"))))
        ])))
        result.append(("remindMinutes", .number(Double(try bounded(request["remindMinutes"], 1440, 10...10_080, "reminder interval")))))
        let watched = request["watch"]["containers"].isNullish ? [] : try request["watch"]["containers"].requireArray("Watched containers")
        guard watched.count <= 50 else { throw NativeRPCError.invalidArguments("Watch at most 50 other containers.") }
        let names = try watched.map { value -> NativeRPCValue in
            let name = try value.requireString("container name", nonempty: true)
            guard name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Container names may use letters, numbers, dots, dashes and underscores.") }
            return .string(name)
        }
        result.append(("watch", BackendAppsValidation.object([("containers", .array(names))])))
        return BackendAppsValidation.object(result)
    }

    static func alertChannel(_ value: NativeRPCValue) throws -> NativeRPCValue {
        guard let fields = value.fields else { throw NativeRPCError.invalidArguments("Each alert channel must be an object.") }
        let kind = try value["kind"].requireString("channel kind", nonempty: true)
        let allowed: [String: Set<String>] = [
            "telegram": ["botToken", "chatId"], "email": ["smtpUrl", "username", "password", "from", "to"],
            "webhook": ["url", "secret"], "receiver": ["url", "token"]
        ]
        guard let own = allowed[kind] else { throw NativeRPCError.invalidArguments("Alert channels can be telegram, email, webhook or receiver.") }
        guard fields.allSatisfy({ own.union(["id", "kind", "enabled", "name"]).contains($0.key) }) else { throw NativeRPCError.invalidArguments("The \(kind) channel has unsupported fields.") }
        let id = try value["id"].requireString("channel name", nonempty: true)
        guard id.range(of: #"\A[A-Za-z0-9_-]{1,48}\z"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Channel names may use letters, numbers, dashes and underscores.") }
        var out: [(String, NativeRPCValue)] = [("id", .string(id)), ("kind", .string(kind)), ("enabled", .bool(value["enabled"].bool ?? true))]
        func text(_ key: String, _ pattern: String, _ message: String, required: Bool = true) throws {
            if value[key].isNullish { if required { throw NativeRPCError.invalidArguments(message) }; return }
            let string = try value[key].requireString(key)
            guard string.range(of: pattern, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments(message) }
            out.append((key, .string(string)))
        }
        func secret(_ key: String, _ pattern: String, _ message: String) throws {
            guard let string = value[key].string, string != mask, !string.isEmpty else { return }
            guard string.range(of: pattern, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments(message) }
            out.append((key, .string(string)))
        }
        switch kind {
        case "telegram":
            try secret("botToken", #"\A[0-9]{5,16}:[A-Za-z0-9_-]{30,64}\z"#, "That Telegram bot token does not look right.")
            try text("chatId", #"\A(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})\z"#, "Use the numeric Telegram chat ID or @channel name.")
        case "email":
            try text("smtpUrl", #"\Asmtps?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?/?\z"#, "Use an smtp:// or smtps:// server address.")
            try text("username", #"\A[^\x00-\x1f\x7f]{1,256}\z"#, "The email user name is invalid.", required: false)
            try secret("password", #"\A[^\x00-\x1f\x7f]{1,256}\z"#, "The email password is invalid.")
            try text("from", #"\A[^\s<>,@]{1,64}@[A-Za-z0-9.-]{1,253}\z"#, "Use a plain sender email address.")
            let to = try value["to"].requireArray("recipients")
            guard (1...10).contains(to.count) else { throw NativeRPCError.invalidArguments("Send email alerts to 1–10 addresses.") }
            out.append(("to", .array(try to.map { item in
                let address = try item.requireString("recipient", nonempty: true)
                guard address.range(of: #"\A[^\s<>,@]{1,64}@[A-Za-z0-9.-]{1,253}\z"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("One recipient address is invalid.") }
                return .string(address)
            })))
        case "webhook":
            try text("url", #"\A(https://[^\s"\\]{4,2000}|http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/[^\s"\\]*)?)\z"#, "Webhooks must use an https:// address.")
            try secret("secret", #"\A[^\x00-\x1f\x7f]{8,256}\z"#, "The webhook signing secret must be 8–256 characters.")
        default:
            try text("url", #"\Ahttps://[^\s"\\]{4,2000}\z"#, "The Receiver address must use https://.")
            try secret("token", #"\A[A-Za-z0-9_.~-]{16,256}\z"#, "The Receiver secret does not look right.")
        }
        return BackendAppsValidation.object(out)
    }

    /// The server returns secret fields as "set" or ""; this keeps them masked.
    public static func publicAlerts(_ value: NativeRPCValue) -> NativeRPCValue {
        let channels = (value["channels"].elements ?? []).map { channel -> NativeRPCValue in
            var result = channel
            for key in secretKeys where channel.has(key) {
                let set = channel[key].string == "set"
                result = result.setting(key, set ? .string(mask) : .null).setting("has" + key.prefix(1).uppercased() + String(key.dropFirst()), .bool(set))
            }
            return result
        }
        return value.setting("channels", .array(channels))
    }

    /// jq run ON the server: keep omitted secrets from the saved channel with the same id.
    public static let alertsMergeFilter = #"""
    (($old[0].channels // [])) as $o
    | .channels |= map(. as $c | ([$o[] | select(.id == $c.id and .kind == $c.kind)] | .[0]) as $p
        | reduce ("botToken","password","secret","token") as $k ($c; if (.[$k] == null) and ($p != null) and ($p[$k] != null) then .[$k] = $p[$k] else . end))
    """#
    public static let alertsCompleteFilter = #"""
    all(.channels[]; (.kind != "telegram" or ((.botToken // "") != "")) and (.kind != "receiver" or ((.token // "") != "")))
    """#
    public static let alertsMaskFilter = #"""
    .channels |= map(with_entries(if (.key == "botToken" or .key == "password" or .key == "secret" or .key == "token") then .value = (if ((.value // "") | length) > 0 then "set" else "" end) else . end))
    """#

    // MARK: cleanup

    public static func cleanup(_ request: NativeRPCValue) throws -> NativeRPCValue {
        let allowed: Set<String> = ["serverId", "enabled", "schedule", "removeOldVersions", "keepVersions", "buildCache", "unnamedStorage"]
        guard let fields = request.fields, fields.allSatisfy({ allowed.contains($0.key) }) else { throw NativeRPCError.invalidArguments("Cleanup settings contain unsupported fields.") }
        let schedule = request["schedule"].isNullish ? defaultCleanupSchedule : try calendar(request["schedule"])
        func flag(_ key: String) throws -> Bool {
            if request[key].isNullish { return false }
            guard let value = request[key].bool else { throw NativeRPCError.invalidArguments("Choose on or off for \(key).") }
            return value
        }
        return BackendAppsValidation.object([
            ("enabled", .bool(request["enabled"].bool ?? true)), ("schedule", .string(schedule)),
            ("removeOldVersions", .bool(try flag("removeOldVersions"))),
            ("keepVersions", .number(Double(try bounded(request["keepVersions"], 3, 1...50, "versions to keep")))),
            ("buildCache", .bool(try flag("buildCache"))), ("unnamedStorage", .bool(try flag("unnamedStorage")))
        ])
    }

    // MARK: jobs

    public static func job(_ request: NativeRPCValue) throws -> NativeRPCValue {
        let jobID = try BackendAppsValidation.id(try request["jobId"].requireString("job ID", nonempty: true))
        let name = request["name"].string ?? jobID
        guard name.count <= 80, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw NativeRPCError.invalidArguments("Use a short job name on one line.") }
        let command = try request["command"].requireString("command", nonempty: true)
        guard command.utf8.count <= 4096, !command.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else { throw NativeRPCError.invalidArguments("Use a command on one line, up to 4096 characters.") }
        return BackendAppsValidation.object([
            ("id", .string(jobID)), ("name", .string(name)), ("schedule", .string(try calendar(request["schedule"]))),
            ("command", .string(command)), ("timeoutSeconds", .number(Double(try bounded(request["timeoutSeconds"], 600, 10...86_400, "time limit")))),
            ("enabled", .bool(request["enabled"].bool ?? true))
        ])
    }

    /// A systemd calendar expression; the server also runs `systemd-analyze calendar`.
    public static func calendar(_ value: NativeRPCValue) throws -> String {
        let text = try value.requireString("schedule", nonempty: true)
        guard text.range(of: #"\A[A-Za-z0-9 *:,./~+-]{1,128}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Use a schedule such as daily, hourly, \"Mon *-*-* 03:00:00\" or \"*-*-* 02:30:00\".")
        }
        return text
    }

    static func bounded(_ value: NativeRPCValue, _ fallback: Int, _ range: ClosedRange<Int>, _ label: String) throws -> Int {
        if value.isNullish { return fallback }
        guard let number = NativeNumber.integer(value.number, in: range) else {
            throw NativeRPCError.invalidArguments("Choose a \(label) between \(range.lowerBound) and \(range.upperBound).")
        }
        return number
    }

    /// Random URL-safe secret from the system generator (never derived).
    public static func randomToken(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func randomHex(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
