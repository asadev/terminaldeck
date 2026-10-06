import Foundation

// The logic behind the native General, Appearance, Notifications, Advanced,
// Linux and Help (with About) Settings sections — ports of the helpers in
// `renderer/settings/` in their own words, so the sentences cannot drift.

// MARK: - The finish sounds (`notification-sound.ts`)

public enum SettingsSound {
    public enum Wave: String, Sendable { case sine, triangle }

    public struct Tone: Equatable, Sendable {
        public var frequency: Double
        public var at: Double
        public var duration: Double
        public var gain: Double
        public var wave: Wave
    }

    /// The three recipes, synthesised — nothing is read from a sound library.
    public static let recipes: [String: [Tone]] = [
        "chime": [
            Tone(frequency: 880, at: 0, duration: 0.12, gain: 0.5, wave: .sine),
            Tone(frequency: 1174.7, at: 0.1, duration: 0.22, gain: 0.42, wave: .sine),
        ],
        "blip": [Tone(frequency: 987.8, at: 0, duration: 0.09, gain: 0.45, wave: .triangle)],
        "knock": [
            Tone(frequency: 196, at: 0, duration: 0.09, gain: 0.6, wave: .sine),
            Tone(frequency: 146.8, at: 0.075, duration: 0.12, gain: 0.5, wave: .sine),
        ],
    ]

    public static func isSoundId(_ id: String) -> Bool { recipes[id] != nil }

    public static func duration(_ id: String) -> Double {
        (recipes[id] ?? []).reduce(0) { Swift.max($0, $1.at + $1.duration) }
    }

    /// The sound as mono samples: each tone starts at its gain and falls
    /// exponentially to silence over its duration (the web's envelope), mixed
    /// under one master volume.
    public static func samples(_ id: String, sampleRate: Double = 44_100, volume: Double = 0.6) -> [Float] {
        guard let tones = recipes[id] else { return [] }
        let master = Swift.min(1, Swift.max(0, volume))
        let count = Int((duration(id) * sampleRate).rounded(.up))
        var out = [Float](repeating: 0, count: count)
        for tone in tones {
            let start = Int(tone.at * sampleRate)
            let length = Int(tone.duration * sampleRate)
            let floor = 0.0001 / tone.gain
            for index in 0..<length where start + index < count {
                let t = Double(index) / sampleRate
                let envelope = tone.gain * pow(floor, t / tone.duration)
                let phase = 2 * Double.pi * tone.frequency * t
                let wave = tone.wave == .sine ? sin(phase) : (2 / Double.pi) * asin(sin(phase))
                out[start + index] += Float(wave * envelope * master)
            }
        }
        return out.map { Swift.min(1, Swift.max(-1, $0)) }
    }
}

// MARK: - Notifications (`NotificationsSection.tsx`, `notification-check.ts`)

public enum SettingsNotifications {
    public static let osName = "macOS"
    public static let bannerSettings = ["notifications.onNeedsInput", "notifications.onComplete"]

    /// A save that switched a banner on: prove it with one.
    public static func turnedOnABanner(_ patch: [String: CodingAIJSON]) -> Bool {
        bannerSettings.contains { patch[$0] == .bool(true) }
    }

    /// The Sound row's help while nothing would play it.
    public static func soundHelp(playsOnFinish: Bool) -> String? {
        playsOnFinish ? nil : "Nothing plays this while the switch above is off. Test still previews it."
    }

    public enum Tone: String, Sendable { case info, warn, error }

    public struct CheckState: Equatable, Sendable {
        public var text: String
        public var tone: Tone
        public var offerSettings: Bool

        public init(text: String, tone: Tone, offerSettings: Bool) {
            self.text = text
            self.tone = tone
            self.offerSettings = offerSettings
        }
    }

    public enum Verdict: String, Sendable { case delivered, absent, unknown }

    /// `toDeliveryReport`: anything unrecognised is `unknown`, never `delivered`.
    public static func report(_ value: CodingAIJSON) -> (verdict: Verdict, at: String?) {
        let verdict = value["verdict"].string.flatMap(Verdict.init(rawValue:)) ?? .unknown
        return (verdict == .unknown ? .unknown : verdict, value["at"].text)
    }

    /// `toNotificationSupport`.
    public static func support(_ value: CodingAIJSON) -> (settingsPane: Bool, deliveryReadable: Bool) {
        (value["settingsPane"].isTrue, value["deliveryReadable"].isTrue)
    }

    static let whereAllowHides = "If it is asking permission, the request arrives as a banner in the corner and Allow is hidden under its Options button."

    /// `deliveryCopy`.
    public static func deliveryCopy(verdict: Verdict, at: String?, test: Bool) -> CheckState {
        switch verdict {
        case .delivered:
            let when = at.map { " at \(String($0.dropFirst(11)))" } ?? ""
            return CheckState(text: test ? "\(osName) recorded a banner\(when). Notifications are working."
                                         : "On, and proven: \(osName) recorded a banner\(when).",
                              tone: .info, offerSettings: false)
        case .absent:
            return CheckState(text: "\(osName) has no record of showing it. Authorisation is most likely still pending or has been refused — the app cannot read which. \(whereAllowHides)",
                              tone: .warn, offerSettings: true)
        case .unknown:
            return CheckState(text: test ? "The banner was handed to \(osName). Whether a banner actually appears is decided by \(osName), and the app cannot read that. If nothing appeared, check there."
                                         : "On. \(osName) may now ask you to allow notifications. \(whereAllowHides)",
                              tone: .warn, offerSettings: true)
        }
    }

    public static let checking = CheckState(
        text: "Waiting to hear whether it arrived — the OS does not record a banner until it leaves the screen.",
        tone: .info, offerSettings: false)

    public static func banner(test: Bool) -> (title: String, body: String) {
        test ? ("Test", "This is what a finished session looks like.")
             : ("Notifications are on", "One of these appears when a session finishes or needs you.")
    }

    public static let refused = "\(osName) refused to show the banner."
    public static let wouldNotOpen = "\(osName) would not open its notification settings."
    public static let noAudio = "No audio output is available to play that on."
    public static let testLabel = "Show a test notification"
    public static let askingLabel = "Asking \(osName)…"
    /// How long a test banner stays when nothing can say whether it arrived.
    public static let bannerSeconds = 6.0
}

// MARK: - Appearance (`AppearanceSection.tsx`)

public enum SettingsAppearance {
    public static let fontSetting = "appearance.terminalFontFamily"
    public static let terminalSettings = ["appearance.terminalScheme", "appearance.terminalFontSize", fontSetting]

    /// The monospace faces the web measures for (`MONO_CANDIDATES`), in its order.
    public static let monoCandidates = [
        "SF Mono", "Menlo", "Monaco", "Andale Mono", "PT Mono", "Courier New", "Cascadia Code", "Cascadia Mono",
        "Consolas", "Lucida Console", "DejaVu Sans Mono", "Liberation Mono", "Ubuntu Mono", "Noto Sans Mono",
        "JetBrains Mono", "Fira Code", "Fira Mono", "IBM Plex Mono", "Source Code Pro", "Roboto Mono", "Hack",
        "Inconsolata", "Iosevka", "Geist Mono", "Berkeley Mono", "MonoLisa", "Operator Mono", "Victor Mono",
        "Space Mono", "Anonymous Pro",
    ]

    /// The font picker: "App default", every installed face, and a chosen face that is
    /// not installed here kept on the list, marked.
    public struct FontChoice: Equatable, Sendable {
        public var options: [String]
        public var missing: Bool
        public var help: String

        public func title(_ name: String, chosen: String) -> String {
            name == chosen && missing ? "\(name) — not installed here" : name
        }
    }

    public static func fontChoice(chosen raw: String, installed: [String]) -> FontChoice {
        let chosen = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = !chosen.isEmpty && !installed.contains(chosen)
        return FontChoice(
            options: missing ? installed + [chosen] : installed,
            missing: missing,
            help: missing
                ? "\(chosen) is not installed on this computer, so sessions are using the app’s own monospace font."
                : "Every monospace font found on this computer.")
    }

    public static let fontMore = "Only fonts this computer actually has are listed — each one is measured before it is offered, so a face on this menu is a face a session will really render in. A font chosen on another computer stays on the list, marked, rather than being silently reset."
    public static let previewLabel = "Preview, at the size sessions use"
    public static let previewText = "npm run dev — 0123456789 illegal1O0"
}

// MARK: - Advanced (`AdvancedSection.tsx`)

public struct SettingsConfigPath: Equatable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var purpose: String
    public var path: String
    public var isFolder: Bool
    public var exists: Bool
    public var id: String { key }

    /// `toConfigPaths`.
    public static func parse(_ value: CodingAIJSON) -> [SettingsConfigPath] {
        (value.array ?? []).compactMap { entry in
            guard entry.isObject, let key = entry["key"].string, let path = entry["path"].string else { return nil }
            return SettingsConfigPath(
                key: key,
                label: entry["label"].text ?? key,
                purpose: entry["purpose"].string ?? "",
                path: path,
                isFolder: entry["kind"].string == "folder",
                exists: entry["exists"].isTrue)
        }
    }

    /// `toOpenPathResult`'s sentence.
    public static func openMessage(_ value: CodingAIJSON) -> String {
        value["message"].text ?? "Nothing happened."
    }
}

// MARK: - About (`AboutSection.tsx`)

public struct SettingsAbout: Equatable, Sendable {
    public struct Updates: Equatable, Sendable {
        public var packaged: Bool
        public var feedPresent: Bool
        public var checkable: Bool
        public var detail: String
    }

    public var name: String
    public var tagline: String
    public var version: String
    public var electron: String
    public var chromium: String
    public var node: String
    public var platform: String
    public var arch: String
    public var license: String?
    public var repository: String?
    public var homepage: String?
    public var updates: Updates?

    /// `toAbout`: nil without a name.
    public static func parse(_ value: CodingAIJSON) -> SettingsAbout? {
        guard value.isObject, let name = value["name"].string else { return nil }
        let updates = value["updates"]
        return SettingsAbout(
            name: name,
            tagline: value["tagline"].string ?? "",
            version: value["version"].string ?? "",
            electron: value["electron"].string ?? "",
            chromium: value["chromium"].string ?? "",
            node: value["node"].string ?? "",
            platform: value["platform"].string ?? "",
            arch: value["arch"].string ?? "",
            license: value["license"].string,
            repository: value["repository"].string,
            homepage: value["homepage"].string,
            updates: updates.isObject
                ? Updates(packaged: updates["packaged"].isTrue, feedPresent: updates["feedPresent"].isTrue,
                          checkable: updates["checkable"].isTrue, detail: updates["detail"].string ?? "")
                : nil)
    }

    /// `buildLine`: one line for a bug report.
    public var buildLine: String {
        let platformLine = "\(platform) \(arch)".trimmingCharacters(in: .whitespaces)
        let parts = [
            electron.isEmpty ? nil : "Electron \(electron)",
            chromium.isEmpty ? nil : "Chromium \(chromium)",
            node.isEmpty ? nil : "Node \(node)",
            platform.isEmpty ? nil : platformLine,
        ].compactMap { $0 }
        return parts.isEmpty ? "Not reported by this build." : parts.joined(separator: " · ")
    }

    /// `updateNote`.
    public static func updateNote(_ about: SettingsAbout?, checkable: Bool) -> String {
        guard let about else { return "Not while the build details cannot be read." }
        if let detail = about.updates?.detail, !detail.isEmpty { return detail }
        return checkable ? "Press the button to check." : "This build cannot tell whether an update exists."
    }

    /// `releasesUrl`: GitHub repositories have a releases page.
    public static func releasesURL(_ repository: String?) -> String? {
        guard let repository, let url = URL(string: repository), url.scheme != nil, url.host == "github.com" else { return nil }
        let trimmed = repository.hasSuffix("/") ? String(repository.dropLast()) : repository
        return "\(trimmed)/releases"
    }

    public static let licenceMore = "The agent CLIs are separate programs under their own licences — nothing here bundles or modifies them."
    public static let buildMore = "Paste this line into a bug report. It is what the four separate rows here used to say, and it changes only when the app is rebuilt."
    public static let notRecorded = "Not recorded in package.json."
    public static let unreadable = "The build details are not readable here."
}

// MARK: - Linux (`LinuxSection.tsx`)

public struct SettingsWslDistro: Equatable, Sendable, Identifiable {
    public var name: String
    public var version: Double
    public var running: Bool
    public var isDefault: Bool
    public var id: String { name }

    public var note: String {
        running ? "Running now." : "Not running — it starts when you open a session in it."
    }
}

public struct SettingsWslSnapshot: Equatable, Sendable {
    public enum State: String, Sendable { case absent, noDistros = "no-distros", ready }
    public var supported: Bool
    public var state: State
    public var distros: [SettingsWslDistro]
    public var chosen: String?
    public var active: String?
    public var home: String?
    public var detail: String?
    public var read: Bool

    /// `toSnapshot`.
    public static func parse(_ value: CodingAIJSON) -> SettingsWslSnapshot? {
        guard value.isObject else { return nil }
        let distros: [SettingsWslDistro] = (value["distros"].array ?? []).compactMap { row in
            guard row.isObject, let name = row["name"].text else { return nil }
            return SettingsWslDistro(name: name, version: row["version"].number ?? 0,
                                     running: row["running"].isTrue, isDefault: row["isDefault"].isTrue)
        }
        let state: State = value["state"].string == "ready" ? .ready : value["state"].string == "no-distros" ? .noDistros : .absent
        return SettingsWslSnapshot(supported: value["supported"].isTrue, state: state, distros: distros,
                                   chosen: value["chosen"].text, active: value["active"].text,
                                   home: value["home"].text, detail: value["detail"].text, read: value["read"].isTrue)
    }

    public static let installDocs = "https://learn.microsoft.com/windows/wsl/install"

    public static func intro(_ here: String) -> String {
        "A session opens where its folder is: a project inside Linux runs inside Linux, a project on this \(here)’s own drive runs on Windows."
    }
    public static let unwired = "This build cannot read the Linux side yet."
    public static func checking(_ here: String) -> String { "Checking what this \(here) has…" }
    public static func absent(_ here: String) -> String {
        "Windows Subsystem for Linux is not installed on this \(here), so every session runs on Windows."
    }
    public static let noDistros = "Windows Subsystem for Linux has no Linux installed in it."
    public static func remembered(_ active: String, _ here: String) -> String {
        "Sessions in a Linux folder use \(active), remembered for this \(here)."
    }
}
