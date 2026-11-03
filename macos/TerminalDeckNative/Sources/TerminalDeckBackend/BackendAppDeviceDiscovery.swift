import Foundation
import TerminalDeckNativeCore

/// Device ids as people and agents type them (13 Oct): adb's serial ("emulator-5554"), a bare simulator
/// UDID, an AVD name with underscores or spaces. One spelling in, the listed id out.
public enum BackendAppDeviceIDs {
    public static func normalize(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = text.firstIndex(of: ":") {
            let prefix = text[..<colon].lowercased(), payload = String(text[text.index(after: colon)...])
            if prefix == "ios" { return "ios:" + (UUID(uuidString: payload) != nil ? payload.uppercased() : payload) }
            if prefix == "android" || prefix == "avd" { return prefix + ":" + payload }
            return text
        }
        if text.range(of: #"^emulator-\d{1,5}$"#, options: .regularExpression) != nil { return "android:" + text }
        if UUID(uuidString: text) != nil { return "ios:" + text.uppercased() }
        return text
    }
    /// Names compare ignoring case, underscores and repeated spaces ("IMATCH_Pixel8" is "imatch pixel8").
    public static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "_", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// A listed row answers to its id (any spelling above), its name, or the AVD a running emulator was started from.
    public static func matches(_ row: NativeRPCValue, _ wanted: String) -> Bool {
        let id = row["id"].string ?? "", text = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if !id.isEmpty, id == normalize(text) { return true }
        let bare = text.lowercased().hasPrefix("avd:") ? String(text.dropFirst(4)) : text
        for name in [row["avd"].string, row["name"].string, id.hasPrefix("avd:") ? String(id.dropFirst(4)) : nil].compactMap({ $0 }) where !name.isEmpty {
            if fold(name) == fold(bare) { return true }
        }
        return false
    }
}

/// Where the Android SDK and its tools are, for any user with no setup: ANDROID_HOME, ANDROID_SDK_ROOT,
/// the folder Android Studio itself was told to use, the default ~/Library/Android/sdk, Homebrew's
/// command-line tools, and finally adb or emulator on the login PATH. A GUI app never sees the shell's
/// ANDROID_HOME, so Android Studio's own setting is what finds a moved SDK.
public enum BackendAppDeviceAndroidSDK {
    public struct Files: Sendable {
        public let isExecutable: @Sendable (String) -> Bool
        public let entries: @Sendable (String) -> [String]?
        public let read: @Sendable (String) -> String?
        public let resolve: @Sendable (String) -> String
        public init(isExecutable: @escaping @Sendable (String) -> Bool, entries: @escaping @Sendable (String) -> [String]?,
                    read: @escaping @Sendable (String) -> String?, resolve: @escaping @Sendable (String) -> String) {
            self.isExecutable = isExecutable; self.entries = entries; self.read = read; self.resolve = resolve
        }
        public static let disk = Files(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            entries: { try? FileManager.default.contentsOfDirectory(atPath: $0) },
            read: { try? String(contentsOfFile: $0, encoding: .utf8) },
            resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    }
    public static let adb = "platform-tools/adb", emulator = "emulator/emulator"
    static func expand(_ raw: String, home: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "$USER_HOME$", with: home)
        if text == "~" { return home }; if text.hasPrefix("~/") { text = home + String(text.dropFirst()) }
        return text
    }
    /// Android Studio's own SDK setting, newest Studio first (options/android.sdk.path.xml, or other.xml in older ones).
    public static func studioPaths(home: String, files: Files = .disk) -> [String] {
        let google = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Google").path
        let folders = (files.entries(google) ?? []).filter { $0.hasPrefix("AndroidStudio") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        var found: [String] = []
        for folder in folders {
            let options = URL(fileURLWithPath: google).appendingPathComponent(folder).appendingPathComponent("options")
            for (file, pattern) in [("android.sdk.path.xml", #"name="androidSdkAbsolutePath"\s+value="([^"]+)""#),
                                    ("other.xml", #"name="android\.sdk\.path"\s+value="([^"]+)""#),
                                    ("other.xml", #""android\.sdk\.path"\s*:\s*"([^"]+)""#)] {
                guard let text = files.read(options.appendingPathComponent(file).path),
                      let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let r = Range(m.range(at: 1), in: text) else { continue }
                found.append(expand(String(text[r]), home: home))
            }
        }
        return found
    }
    /// Every place an SDK may be, in the order it is trusted; empty and repeated entries dropped.
    public static func candidates(environment: [String: String], home: String, files: Files = .disk) -> [String] {
        let fixed = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }.map { expand($0, home: home) }
        let defaults = [URL(fileURLWithPath: home).appendingPathComponent("Library/Android/sdk").path,
                        "/opt/homebrew/share/android-commandlinetools", "/usr/local/share/android-commandlinetools",
                        "/opt/homebrew/share/android-sdk", "/usr/local/share/android-sdk"]
        var seen = Set<String>(), result: [String] = []
        for path in fixed + studioPaths(home: home, files: files) + defaults where !path.isEmpty {
            let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            if seen.insert(clean).inserted { result.append(clean) }
        }
        return result
    }
    /// One tool ("platform-tools/adb", "emulator/emulator"): the first SDK that has it, else the login PATH.
    public static func tool(_ relative: String, environment: [String: String], home: String, files: Files = .disk) -> String? {
        for root in candidates(environment: environment, home: home, files: files) {
            let path = URL(fileURLWithPath: root).appendingPathComponent(relative).path
            if files.isExecutable(path) { return path }
        }
        let name = (relative as NSString).lastPathComponent
        for dir in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where !dir.isEmpty {
            let path = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if files.isExecutable(path) { return path }
        }
        return nil
    }
    /// The SDK folder itself: the first candidate holding adb or the emulator, else the folder adb on PATH belongs to.
    public static func root(environment: [String: String], home: String, files: Files = .disk) -> String? {
        let all = candidates(environment: environment, home: home, files: files)
        for root in all {
            if [adb, emulator].contains(where: { files.isExecutable(URL(fileURLWithPath: root).appendingPathComponent($0).path) }) { return root }
        }
        // An SDK folder without adb or the emulator yet (only cmdline-tools, say) still counts, as it always did.
        if let existing = all.first(where: { files.entries($0) != nil }) { return existing }
        for dir in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where !dir.isEmpty {
            let onPath = URL(fileURLWithPath: dir).appendingPathComponent("adb").path
            guard files.isExecutable(onPath) else { continue }
            let folder = URL(fileURLWithPath: files.resolve(onPath)).deletingLastPathComponent()
            return folder.lastPathComponent == "platform-tools" ? folder.deletingLastPathComponent().path : nil
        }
        return nil
    }
    /// What every device command is told, so the Android tools find the same SDK this app found (ANDROID_HOME
    /// and ANDROID_SDK_ROOT), with a UTF-8 character type so the text typed or pasted into a phone keeps its
    /// letters (`DeviceToolEnvironment`). Values already set are never replaced.
    public static func engineEnvironment(_ environment: [String: String], home: String, files: Files = .disk) -> [String: String] {
        var result = DeviceToolEnvironment.utf8(environment)
        if (result["ANDROID_HOME"] ?? "").isEmpty && (result["ANDROID_SDK_ROOT"] ?? "").isEmpty, let sdk = root(environment: environment, home: home, files: files) {
            result["ANDROID_HOME"] = sdk; result["ANDROID_SDK_ROOT"] = sdk
        }
        return result
    }
}

/// Emulators that are already running, read without touching them: the process list (`ps`, headless
/// `-no-window` ones included) and adb's own answers. Nothing here starts, stops or restarts an emulator.
public enum BackendAppDeviceRunningEmulators {
    static let avdPattern = #"^[A-Za-z0-9._-]{1,120}$"#
    /// AVD names from `ps -axo command=`: each qemu-system… or emulator process started with `-avd NAME` or `@NAME`.
    public static func avds(processList: String) -> Set<String> {
        var names = Set<String>()
        for line in processList.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // The program is the first word, or a later one when its folder had a space in it ("/Volumes/My Drive/…").
            guard let start = words.firstIndex(where: { word in
                let program = (word as NSString).lastPathComponent
                return (program.hasPrefix("qemu-system") || program == "emulator") && (word == words.first || word.contains("/"))
            }) else { continue }
            for (index, word) in words.enumerated() where index > start {
                var name: String?
                if word == "-avd", index + 1 < words.count { name = words[index + 1] } else if word.hasPrefix("@"), word.count > 1 { name = String(word.dropFirst()) }
                if let name, name.range(of: avdPattern, options: .regularExpression) != nil { names.insert(name) }
            }
        }
        return names
    }
    /// The AVD name from `adb emu avd name` ("NAME\nOK") or `getprop ro.boot.qemu.avd_name`; "" when it is not one.
    public static func avdName(output: String) -> String {
        let first = (output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }) ?? ""
        guard first != "OK", !first.hasPrefix("KO"), first.range(of: avdPattern, options: .regularExpression) != nil else { return "" }
        return first
    }
    /// adb's `devices` table: serial → state ("device", "offline", "unauthorized").
    public static func serials(adbDevices: String) -> [(serial: String, state: String)] {
        adbDevices.components(separatedBy: "\n").compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            return (words[0], words[1])
        }
    }
    /// A row for an emulator adb sees but the device listing did not answer about (slow or failed listing).
    public static func adoptedRow(serial: String, avd: String) -> NativeRPCValue {
        BackendAppDeviceParsing.object([("id", .string("android:" + serial)), ("platform", .string("android")), ("kind", .string("emulator")), ("state", .string("ready")),
            ("available", .bool(true)), ("name", .string(avd.isEmpty ? serial : avd.replacingOccurrences(of: "_", with: " "))), ("avd", .string(avd)), ("runtime", .string("")),
            ("canBoot", .bool(false)), ("canShutDown", .bool(true)), ("buttons", .array([])), ("keys", .array([])), ("text", .string("none")), ("canRotate", .bool(false)),
            ("note", .string("")), ("checking", .bool(true))])
    }
}

/// Why a device list came back empty, in plain words, from what is really on this Mac.
public struct BackendAppDeviceDiagnosis: Sendable, Equatable {
    public var simulatorTool: Bool       // xcrun finds simctl, so Xcode (with its simulators) is installed
    public var simulatorsOnDisk: Int     // folders under ~/Library/Developer/CoreSimulator/Devices
    public var sdk: String?              // the Android SDK folder found, if any
    public var adb: Bool                 // adb found (in the SDK or on PATH)
    public var avds: Int                 // emulators made in Android Studio (running or not)
    public var engineAnswered: Bool      // the device listing answered in time
    public init(simulatorTool: Bool, simulatorsOnDisk: Int, sdk: String?, adb: Bool, avds: Int, engineAnswered: Bool) {
        self.simulatorTool = simulatorTool; self.simulatorsOnDisk = simulatorsOnDisk; self.sdk = sdk; self.adb = adb; self.avds = avds; self.engineAnswered = engineAnswered
    }
    public func sentence(home: String) -> String {
        func shown(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path }
        var parts: [String] = []
        if simulatorsOnDisk > 0 { parts.append("this Mac has \(simulatorsOnDisk) iOS Simulator\(simulatorsOnDisk == 1 ? "" : "s"), but they could not be read just now") }
        else if simulatorTool { parts.append("Xcode is installed but has no iOS Simulator yet (add one in Xcode › Window › Devices and Simulators)") }
        else { parts.append("there is no iOS Simulator because Xcode is not installed (simulators come with Xcode)") }
        if let sdk {
            if !adb { parts.append("the Android SDK at \(shown(sdk)) has no adb, so running emulators and phones cannot be seen (install Platform Tools in Android Studio’s SDK Manager)") }
            else if avds == 0 { parts.append("the Android SDK is at \(shown(sdk)) but no Android emulator has been made yet (Android Studio › Device Manager)") }
            else { parts.append("\(avds) Android emulator\(avds == 1 ? " is" : "s are") set up but could not be read just now") }
        } else if adb { parts.append("adb is installed but the Android emulator is not, so there is no Android emulator (install Android Studio)") }
        else { parts.append("there is no Android emulator because Android Studio’s SDK was not found (looked at ANDROID_HOME, ANDROID_SDK_ROOT, Android Studio’s own setting and ~/Library/Android/sdk)") }
        if adb { parts.append("no Android phone is plugged in with USB debugging on and this computer allowed") }
        var text = parts.joined(separator: "; ") + "."
        if !engineAnswered { text += " adb did not answer in time, so running Android devices may be missing: list again in a moment." }
        return text
    }
}
