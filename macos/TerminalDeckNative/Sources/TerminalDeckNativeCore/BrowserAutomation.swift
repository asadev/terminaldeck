import Foundation

// Browser 27 (Asad, 4 Nov 2026): "Check all the capabilities of our browser and
// compare with Playwright … as much automation as possible, so you or any other
// session can use the browser to do any kind of things."
//
// The pure half of the page automation the in-app browser (WKWebView) can do:
// key chords, which files may be handed to a website, what the network log
// hides, the HAR it writes, and the page-world hooks (console, network,
// emulation) with the scripts that read them. The app side runs these through
// WebKit's public API only (evaluateJavaScript / callAsyncJavaScript, user
// scripts, content rule lists, the UI delegate).

// MARK: - Keys

/// A key the agent names: `Enter`, `a`, `F5`, `Control+A`, `Meta+Shift+K`.
public struct BrowserKeyChord: Equatable, Sendable {
    public let key: String
    public let spec: BrowserKeySpec
    public let shift: Bool
    public let control: Bool
    public let alt: Bool
    public let meta: Bool

    public var hasModifiers: Bool { shift || control || alt || meta }
    /// Copy, cut and paste chords: they reach the person's clipboard.
    public static func usesClipboard(_ chord: BrowserKeyChord) -> Bool {
        ((chord.meta || chord.control) && ["v", "c", "x"].contains(chord.key.lowercased())) || ((chord.shift || chord.control) && chord.key == "Insert") || (chord.shift && chord.key == "Delete")
    }
    /// For the scripted fallback (`scriptedInput` reads `modifiers`).
    public var modifierFlags: [String: Bool] { ["shift": shift, "control": control, "alt": alt, "meta": meta] }

    /// Named keys beyond the original nine (Mac virtual key codes; AppKit's
    /// function-key characters).
    public static let named: [String: BrowserKeySpec] = BrowserKeySpec.pressable.merging([
        "Space": BrowserKeySpec(keyCode: 49, characters: " "),
        "Home": BrowserKeySpec(keyCode: 115, characters: "\u{F729}"),
        "End": BrowserKeySpec(keyCode: 119, characters: "\u{F72B}"),
        "PageUp": BrowserKeySpec(keyCode: 116, characters: "\u{F72C}"),
        "PageDown": BrowserKeySpec(keyCode: 121, characters: "\u{F72D}"),
        "Insert": BrowserKeySpec(keyCode: 114, characters: "\u{F727}"),
        "F1": BrowserKeySpec(keyCode: 122, characters: "\u{F704}"), "F2": BrowserKeySpec(keyCode: 120, characters: "\u{F705}"),
        "F3": BrowserKeySpec(keyCode: 99, characters: "\u{F706}"), "F4": BrowserKeySpec(keyCode: 118, characters: "\u{F707}"),
        "F5": BrowserKeySpec(keyCode: 96, characters: "\u{F708}"), "F6": BrowserKeySpec(keyCode: 97, characters: "\u{F709}"),
        "F7": BrowserKeySpec(keyCode: 98, characters: "\u{F70A}"), "F8": BrowserKeySpec(keyCode: 100, characters: "\u{F70B}"),
        "F9": BrowserKeySpec(keyCode: 101, characters: "\u{F70C}"), "F10": BrowserKeySpec(keyCode: 109, characters: "\u{F70D}"),
        "F11": BrowserKeySpec(keyCode: 103, characters: "\u{F70E}"), "F12": BrowserKeySpec(keyCode: 111, characters: "\u{F70F}"),
    ]) { old, _ in old }

    /// US-layout key codes for letters, digits and common punctuation, so a
    /// chord like Meta+A reaches WebKit as the key a person would press.
    static let characterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    public static func parse(_ raw: String) throws(BrowserDriverRefusal) -> BrowserKeyChord {
        let said = raw.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty, said.count <= 40 else { throw BrowserDriverRefusal("name a key, like Enter, a, F5 or Control+A") }
        // "+" alone, or a chord ending in "++" (Shift++), is the plus key.
        let parts: [String]
        if said == "+" { parts = ["+"] }
        else if said.hasSuffix("++") { parts = String(said.dropLast(2)).components(separatedBy: "+") + ["+"] }
        else { parts = said.components(separatedBy: "+") }
        guard let keyName = parts.last, !keyName.isEmpty else { throw BrowserDriverRefusal("\(raw) does not end in a key") }
        var shift = false, control = false, alt = false, meta = false
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "shift": shift = true
            case "control", "ctrl": control = true
            case "alt", "option", "opt": alt = true
            case "meta", "command", "cmd": meta = true
            default: throw BrowserDriverRefusal("\(modifier) is not a modifier. Use Shift, Control, Alt (Option) or Meta (Command).")
            }
        }
        if let name = named.keys.first(where: { $0 == keyName }) ?? named.keys.first(where: { $0.lowercased() == keyName.lowercased() }), keyName.count > 1 || named[keyName] != nil {
            return BrowserKeyChord(key: name, spec: named[name]!, shift: shift, control: control, alt: alt, meta: meta)
        }
        guard keyName.count == 1, let character = keyName.first else {
            let known = (BrowserKeySpec.pressableNames + ["Space", "Home", "End", "PageUp", "PageDown", "Insert", "F1…F12"]).joined(separator: ", ")
            throw BrowserDriverRefusal("\(keyName) is not a key this can press. It presses one character, or one of: \(known), with Shift, Control, Alt or Meta in front (Control+A).")
        }
        let lower = Character(character.lowercased())
        let code = characterCodes[lower] ?? 0
        // A letter is the letter key: Shift makes it a capital, anything else keeps it small (Control+A is Control+a).
        let typed = character.isLetter ? (shift ? String(character).uppercased() : String(character).lowercased()) : String(character)
        return BrowserKeyChord(key: typed, spec: BrowserKeySpec(keyCode: code, characters: typed),
                               shift: shift, control: control, alt: alt, meta: meta)
    }
}

// MARK: - Files handed to a website

/// Which files an agent may put into a page's file field. A website upload is a
/// change on that site (asked like any other step); these are the files no
/// upload should ever carry: keys, keychains, cloud credentials and this app's
/// own data.
public enum BrowserUploadPolicy {
    public static let maxFiles = 20
    public static let maxFileBytes = 50 * 1024 * 1024
    /// Files travel into the page as bytes (setInputFiles); keep that bounded.
    public static let maxScriptBytes = 25 * 1024 * 1024

    /// Nil when allowed; else the sentence the agent reads.
    public static func refusal(path: String, resolved: String, home: String, protectedRoots: [String]) -> String? {
        guard path.hasPrefix("/"), resolved.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !resolved.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "This is not a full path, or it contains control characters. Give each upload file as an absolute path without control characters."
        }
        // Check both spellings: a symlink may point into a private folder, or
        // give a private-looking name to otherwise ordinary bytes.
        for candidate in [path, resolved] {
            let real = (candidate as NSString).standardizingPath
            let comparable = real.lowercased()
            let components = comparable.split(separator: "/").map(String.init)
            let name = components.last ?? ""
            let homeBase = (home as NSString).standardizingPath.lowercased()
            if comparable.hasPrefix(homeBase + "/") {
                let inside = String(comparable.dropFirst(homeBase.count + 1))
                if inside.hasPrefix(".") { return "This file is in a hidden home folder where sign-ins live. It was not uploaded." }
                for kept in ["Library/Keychains", "Library/Cookies", "Library/Application Support/terminaldeck", "Library/Application Support/Terminal Deck",
                             "Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers/com.apple.Safari", "Library/Accounts", "Library/Group Containers",
                             "Library/Application Support/Firefox", "Library/Application Support/LibreWolf", "Library/Application Support/Waterfox",
                             "Library/Application Support/Zen", "Library/Application Support/Thunderbird", "Library/Application Support/Google/Chrome",
                             "Library/Application Support/Chromium", "Library/Application Support/Microsoft Edge", "Library/Application Support/BraveSoftware",
                             "Library/Application Support/Arc", "Library/Application Support/Company/The Browser Company/Arc",
                             "Library/Application Support/Dia", "Library/Application Support/Vivaldi", "Library/Application Support/com.operasoftware.Opera"] {
                    let relative = inside.lowercased(), base = kept.lowercased()
                    if relative == base || relative.hasPrefix(base + "/") || relative.hasPrefix(base + " ") {
                        return "This private home folder is never uploaded."
                    }
                }
            }
            for root in protectedRoots where !root.isEmpty {
                let base = (root as NSString).standardizingPath.lowercased()
                if comparable == base || comparable.hasPrefix(base.hasSuffix("/") ? base : base + "/") { return "This app's own records are never uploaded." }
            }
            for prefix in ["/etc/", "/private/etc/", "/private/var/", "/var/", "/library/keychains/"] where comparable.hasPrefix(prefix) {
                return "System files are never uploaded."
            }
            let privateFolders: Set<String> = [".ssh", ".aws", ".claude", ".codex", ".gemini", ".gnupg", ".kube", ".azure", ".docker",
                                               "credentials", "credential", "secrets", "secret", "keychains", "gcloud", ".mozilla", ".librewolf", ".thunderbird"]
            if components.dropLast().contains(where: { privateFolders.contains($0) }) {
                return "Files in credential or private agent folders are never uploaded."
            }
            let shapes = [#"^\.env($|\.)"#, #"^\.envrc$"#, #"^(\.npmrc|\.yarnrc\.yml|\.pypirc|\.netrc|_netrc|\.pgpass|\.htpasswd|\.git-credentials|\.credentials\.json|\.vault-token)$"#,
                          #"^id_(rsa|dsa|ecdsa|ed25519)(_sk)?$"#, #"\.(pem|key|p8|p12|pfx|jks|keystore|asc|ppk|keychain|keychain-db)$"#,
                          #"\.(tfvars(\.json)?|tfstate(\.backup)?)$"#, #"^(secrets?\.(json|ya?ml|toml|env)|.*\.secrets?\.(json|ya?ml|toml))$"#,
                          #"^service-account.*\.json$"#, #"^(credentials?|.*credentials?\.(json|ya?ml|toml|ini|txt))$"#,
                          #"^(cookies(\.(sqlite|binarycookies))?|login data( for account)?|web data)(-(journal|wal|shm))?$"#,
                          #"^(local state|logins\.json|key[34]\.db|cert[89]\.db|sessionstore\.jsonlz4)(-(journal|wal|shm))?$"#]
            if shapes.contains(where: { name.range(of: $0, options: .regularExpression) != nil }) {
                return "This looks like a key, environment or sign-in file. It was not uploaded."
            }
        }
        return nil
    }
}

// MARK: - What the network log never shows

public enum BrowserNetworkScrub {
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token"]
    static let secretKey = try! NSRegularExpression(pattern: #"^(password|passwd|pwd|pass|passcode|secret|client_secret|api_?key|access_?token|refresh_?token|id_?token|auth_?token|session_?token|token|otp|one_time_code|totp|cvv|cvc|csc|card_?number|cc_?number|cardnumber|pin|ssn)$"#, options: [.caseInsensitive])

    public static func headers(_ raw: Any?) -> (value: [String: String], hidden: Int) {
        guard let fields = raw as? [String: Any] else { return ([:], 0) }
        var out: [String: String] = [:], hidden = 0
        for (key, value) in fields {
            let name = key.lowercased()
            if secretHeaders.contains(name) { out[name] = "[hidden]"; hidden += 1 }
            else { out[name] = String(describing: value).prefix(2_000).description }
        }
        return (out, hidden)
    }

    static func isSecretKey(_ key: String) -> Bool {
        secretKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    /// JSON and form bodies with secret-looking fields replaced; anything else as is.
    public static func body(_ text: String?) -> (value: String?, hidden: Int) {
        guard let text, !text.isEmpty else { return (text, 0) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            var hidden = 0
            let cleaned = scrub(object, hidden: &hidden)
            guard hidden > 0 else { return (text, 0) }
            let out = (try? JSONSerialization.data(withJSONObject: cleaned, options: [.fragmentsAllowed, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
            return (out ?? "[hidden]", hidden)
        }
        if !trimmed.contains(" "), trimmed.contains("="), !trimmed.contains("<") {
            var hidden = 0
            let pairs = trimmed.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts.first ?? "").removingPercentEncoding ?? String(parts.first ?? "")
                if parts.count == 2, isSecretKey(key) { hidden += 1; return "\(parts[0])=[hidden]" }
                return String(pair)
            }
            return (hidden > 0 ? pairs.joined(separator: "&") : text, hidden)
        }
        return (text, 0)
    }

    static func scrub(_ value: Any, hidden: inout Int) -> Any {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in object {
                if isSecretKey(key), !(inner is [String: Any]), !(inner is [Any]) { out[key] = "[hidden]"; hidden += 1 }
                else { out[key] = scrub(inner, hidden: &hidden) }
            }
            return out
        }
        if let list = value as? [Any] { return list.map { scrub($0, hidden: &hidden) } }
        return value
    }
}

// MARK: - HAR

/// A HAR 1.2 log from the page's network entries (fetch/XHR with headers and
/// bodies, and resource timing for the rest) — what Playwright's recordHar gives,
/// limited to what a page can see of itself.
public enum BrowserHAR {
    public static func make(pageURL: String, title: String, entries: [[String: Any]], resources: [[String: Any]], creator: String = "Terminal Deck") -> [String: Any] {
        func iso(_ ms: Double) -> String {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        func pairs(_ raw: Any?) -> [[String: String]] {
            let fields = (raw as? [String: Any]) ?? [:]
            return fields.keys.sorted().map { ["name": $0, "value": String(describing: fields[$0] ?? "")] }
        }
        func query(_ url: String) -> [[String: String]] {
            (URLComponents(string: url)?.queryItems ?? []).map { ["name": $0.name, "value": $0.value ?? ""] }
        }
        var rows: [[String: Any]] = []
        for entry in entries {
            let url = (entry["url"] as? String) ?? ""
            let start = (entry["start"] as? NSNumber)?.doubleValue ?? 0
            let end = (entry["end"] as? NSNumber)?.doubleValue ?? start
            let headers = (entry["responseHeaders"] as? [String: Any]) ?? [:]
            let mime = (headers["content-type"] as? String) ?? ""
            var request: [String: Any] = ["method": entry["method"] as? String ?? "GET", "url": url, "httpVersion": "HTTP/1.1",
                                          "headers": pairs(entry["requestHeaders"]), "queryString": query(url), "cookies": [],
                                          "headersSize": -1, "bodySize": -1]
            if let body = entry["requestBody"] as? String {
                let type = ((entry["requestHeaders"] as? [String: Any])?["content-type"] as? String) ?? "text/plain"
                request["postData"] = ["mimeType": type, "text": body]
            }
            var content: [String: Any] = ["size": (entry["responseBody"] as? String)?.utf8.count ?? -1, "mimeType": mime]
            if let body = entry["responseBody"] as? String { content["text"] = body }
            let response: [String: Any] = ["status": (entry["status"] as? NSNumber)?.intValue ?? 0, "statusText": entry["statusText"] as? String ?? "",
                                           "httpVersion": "HTTP/1.1", "headers": pairs(entry["responseHeaders"]), "cookies": [],
                                           "content": content, "redirectURL": "", "headersSize": -1, "bodySize": -1]
            var row: [String: Any] = ["startedDateTime": iso(start), "time": max(0, end - start), "request": request, "response": response,
                                      "cache": [:], "timings": ["send": 0, "wait": max(0, end - start), "receive": 0]]
            if let failed = entry["failed"] as? String { row["_error"] = failed }
            if entry["mocked"] as? Bool == true { row["_mocked"] = true }
            row["_initiator"] = entry["kind"] as? String ?? "fetch"
            rows.append(row)
        }
        for resource in resources {
            let start = (resource["start"] as? NSNumber)?.doubleValue ?? 0
            let duration = (resource["duration"] as? NSNumber)?.doubleValue ?? 0
            let url = (resource["url"] as? String) ?? ""
            rows.append(["startedDateTime": iso(start), "time": duration,
                         "request": ["method": "GET", "url": url, "httpVersion": "HTTP/1.1", "headers": [], "queryString": query(url), "cookies": [], "headersSize": -1, "bodySize": -1],
                         "response": ["status": (resource["status"] as? NSNumber)?.intValue ?? 0, "statusText": "", "httpVersion": "HTTP/1.1", "headers": [], "cookies": [],
                                      "content": ["size": (resource["size"] as? NSNumber)?.intValue ?? -1, "mimeType": ""], "redirectURL": "", "headersSize": -1, "bodySize": -1],
                         "cache": [:], "timings": ["send": 0, "wait": duration, "receive": 0], "_initiator": resource["type"] as? String ?? "other",
                         "_timingOnly": true])
        }
        rows.sort { ($0["startedDateTime"] as? String ?? "") < ($1["startedDateTime"] as? String ?? "") }
        return ["log": ["version": "1.2", "creator": ["name": creator, "version": "browser-27"],
                        "pages": [["startedDateTime": rows.first?["startedDateTime"] ?? iso(Date().timeIntervalSince1970 * 1000), "id": "page_1", "title": title.isEmpty ? pageURL : title, "pageTimings": [:]]],
                        "entries": rows.map { var row = $0; row["pageref"] = "page_1"; return row }]]
    }
}

// MARK: - Page-world hooks

/// Scripts that live in the page's own world (they must see the page's console
/// and fetch). Each keeps its state behind a Symbol key, never an enumerable
/// global, and is installed once per document.
public enum BrowserPageHooks {
    public static let consoleKey = "td.console.v1"
    public static let networkKey = "td.network.v1"
    public static let emulateKey = "td.emulate.v1"

    /// Console messages, page errors and failed resource loads. `auto` installs it
    /// only on this machine's and the local network's pages (where a developer's
    /// own app runs); armed explicitly, it runs on any page of that tab.
    public static func console(auto: Bool) -> String {
        consoleSource.replacingOccurrences(of: "/*AUTO*/false", with: auto ? "true" : "false")
    }

    public static let readConsole = "(function(){var h=window[Symbol.for('td.console.v1')];return h?h.read(/*ARG*/null):null})()"
    public static let clearConsole = "(function(){var h=window[Symbol.for('td.console.v1')];if(h)h.clear();return !!h})()"
    public static let readNetwork = "(function(){var h=window[Symbol.for('td.network.v1')];return h?h.read(/*ARG*/null):null})()"
    public static let clearNetwork = "(function(){var h=window[Symbol.for('td.network.v1')];if(h)h.clear();return !!h})()"
    public static let networkIdle = "(function(){var h=window[Symbol.for('td.network.v1')];return h?h.idle():null})()"

    static let argToken = "/*ARG*/null"

    public static func with(_ template: String, argument: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [argument], options: [.sortedKeys, .fragmentsAllowed])) ?? Data("[null]".utf8)
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return template.replacingOccurrences(of: argToken, with: "(\(json))[0]")
    }

    /// Re-applies a network configuration (routes, bodies, headers, offline) to a
    /// document whose hook is already in.
    public static func configureNetwork(_ config: [String: Any]) -> String {
        with("(function(){var h=window[Symbol.for('td.network.v1')];return h?h.configure(/*ARG*/null):null})()", argument: config)
    }

    public static func network(config: [String: Any]) -> String {
        with(networkSource, argument: config)
    }

    public static func emulate(_ config: [String: Any]) -> String {
        with(emulateSource, argument: config)
    }

    static let consoleSource = #"""
    (function () {
      var KEY = Symbol.for('td.console.v1');
      if (window[KEY]) return;
      var AUTO = /*AUTO*/false;
      var host = String(location.hostname || '');
      var local = location.protocol === 'file:' || host === 'localhost' || /\.(localhost|local)$/.test(host) || /^127\./.test(host) ||
        /^10\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host) || host === '[::1]' || host === '::1';
      if (AUTO && !local) return;
      var buf = [], dropped = 0, seq = 0, MAX = 1000;
      var fmt = function (v, depth) {
        try {
          if (typeof v === 'string') return v;
          if (v instanceof Error) return (v.name || 'Error') + ': ' + v.message;
          if (v === undefined) return 'undefined';
          if (typeof v === 'function') return '[function ' + (v.name || 'anonymous') + ']';
          if (typeof Node !== 'undefined' && v instanceof Node) return '<' + String(v.nodeName || '').toLowerCase() + (v.id ? '#' + v.id : '') + '>';
          if (typeof v === 'object' && v !== null && depth < 1) { var s = JSON.stringify(v); if (s !== undefined) return s.length > 2000 ? s.slice(0, 2000) + '…' : s }
          return String(v);
        } catch (e) { try { return String(v) } catch (e2) { return '[unprintable]' } }
      };
      var push = function (level, parts, extra) {
        var textOut = parts.map(function (p) { return fmt(p, 0) }).join(' ');
        if (textOut.length > 4000) textOut = textOut.slice(0, 4000) + '…';
        var entry = { seq: ++seq, level: level, text: textOut, time: Date.now(), url: String(location.href) };
        if (extra) for (var k in extra) if (extra[k]) entry[k] = extra[k];
        if (buf.length >= MAX) { buf.shift(); dropped++ }
        buf.push(entry);
      };
      var nativeToString = Function.prototype.toString;
      ['log', 'info', 'warn', 'error', 'debug', 'trace', 'assert'].forEach(function (m) {
        var orig = console[m]; if (typeof orig !== 'function') return;
        var wrapped = function () {
          try {
            var list = Array.prototype.slice.call(arguments);
            if (m === 'assert') { if (!list[0]) push('assert', list.slice(1).length ? list.slice(1) : ['Assertion failed']) }
            else push(m, list);
          } catch (e) {}
          return orig.apply(this, arguments);
        };
        try { Object.defineProperty(wrapped, 'name', { value: orig.name }) } catch (e) {}
        try { Object.defineProperty(wrapped, 'toString', { value: function () { return nativeToString.call(orig) } }) } catch (e) {}
        console[m] = wrapped;
      });
      window.addEventListener('error', function (e) {
        var t = e.target;
        if (t && t !== window && t.nodeType === 1) { push('resource', ['Failed to load ' + String(t.localName) + ' ' + String(t.currentSrc || t.src || t.href || '')]); return }
        push('pageerror', [e.message || fmt(e.error, 0)], { source: e.filename ? e.filename + ':' + e.lineno + ':' + e.colno : '', stack: e.error && e.error.stack ? String(e.error.stack).slice(0, 2000) : '' });
      }, true);
      window.addEventListener('unhandledrejection', function (e) {
        push('pageerror', ['Unhandled promise rejection: ' + fmt(e.reason, 0)], { stack: e.reason && e.reason.stack ? String(e.reason.stack).slice(0, 2000) : '' });
      });
      Object.defineProperty(window, KEY, { enumerable: false, configurable: false, value: {
        read: function (since) { since = Number(since) || 0; return { entries: buf.filter(function (x) { return x.seq > since }), dropped: dropped, last: seq } },
        clear: function () { buf = []; dropped = 0; return true }
      } });
    })()
    """#

    static let networkSource = #"""
    (function (config) {
      var KEY = Symbol.for('td.network.v1');
      if (window[KEY]) { window[KEY].configure(config || {}); return }
      var log = [], timing = [], seq = 0, dropped = 0, MAX = 500, inflight = 0, lastActivity = Date.now();
      var cfg = { bodies: false, maxBody: 262144, routes: [], headers: {}, offline: false };
      var origFetch = window.fetch, OrigXHR = window.XMLHttpRequest, nativeToString = Function.prototype.toString;
      var absUrl = function (u) { try { return new URL(String(u), location.href).href } catch (e) { return String(u) } };
      var globRe = function (pattern) {
        var p = String(pattern || '');
        var rx = /^\/([\s\S]+)\/([a-z]*)$/.exec(p);
        if (rx) { try { return new RegExp(rx[1], rx[2].replace('g', '')) } catch (e) { return /^$/ } }
        if (p.indexOf('*') === -1 && p.indexOf('?') === -1) return { test: function (u) { return u.indexOf(p) !== -1 } };
        var out = '';
        for (var i = 0; i < p.length; i++) {
          var c = p.charAt(i);
          if (c === '*') { if (p.charAt(i + 1) === '*') { out += '.*'; i++ } else out += '[^/]*' }
          else if (c === '?') out += '.';
          else out += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
        }
        return new RegExp('^' + out + '$');
      };
      var routeFor = function (url, method) {
        for (var i = cfg.routes.length - 1; i >= 0; i--) { var r = cfg.routes[i]; if (r.re.test(url) && (!r.method || r.method === method)) return r }
        return null;
      };
      var sameOrigin = function (u) { try { return new URL(u).origin === location.origin } catch (e) { return false } };
      var textual = function (ct) { return /json|text|xml|javascript|x-www-form-urlencoded|graphql|csv/i.test(ct || '') };
      var record = function (entry) { if (log.length >= MAX) { log.shift(); dropped++ } log.push(entry) };
      var headersObj = function (h) {
        var o = {};
        try {
          if (h && typeof h.forEach === 'function' && !(Array.isArray(h))) h.forEach(function (v, k) { o[String(k).toLowerCase()] = String(v) });
          else if (Array.isArray(h)) h.forEach(function (pair) { o[String(pair[0]).toLowerCase()] = String(pair[1]) });
          else if (h) for (var k in h) o[k.toLowerCase()] = String(h[k]);
        } catch (e) {}
        return o;
      };
      var bodyText = function (b) {
        try {
          if (b == null) return null;
          if (typeof b === 'string') return b.slice(0, 65536);
          if (typeof URLSearchParams !== 'undefined' && b instanceof URLSearchParams) return b.toString().slice(0, 65536);
          if (typeof FormData !== 'undefined' && b instanceof FormData) { var parts = []; b.forEach(function (v, k) { parts.push(encodeURIComponent(k) + '=' + (typeof v === 'string' ? encodeURIComponent(v) : '[file ' + (v.name || '') + ']')) }); return parts.join('&').slice(0, 65536) }
          if (typeof Blob !== 'undefined' && b instanceof Blob) return '[blob ' + b.size + ' bytes]';
          if (b instanceof ArrayBuffer || ArrayBuffer.isView(b)) return '[binary ' + b.byteLength + ' bytes]';
        } catch (e) {}
        return '[body]';
      };
      var readBody = function (response, entry) {
        try {
          var ct = response.headers.get('content-type') || '';
          if (!textual(ct) || !response.body) return;
          var reader = response.body.getReader(), chunks = [], size = 0;
          var pump = function () {
            return reader.read().then(function (part) {
              if (part.value) { chunks.push(part.value); size += part.value.length }
              if (!part.done && size < cfg.maxBody) return pump();
              if (!part.done) { entry.bodyTruncated = true; try { reader.cancel() } catch (e) {} }
              var all = new Uint8Array(Math.min(size, cfg.maxBody)), off = 0;
              for (var i = 0; i < chunks.length && off < all.length; i++) { var c = chunks[i].subarray(0, all.length - off); all.set(c, off); off += c.length }
              entry.responseBody = new TextDecoder().decode(all);
            });
          };
          pump().catch(function (e) { entry.bodyError = String(e && e.message || e) });
        } catch (e) { entry.bodyError = String(e && e.message || e) }
      };
      var activity = function (d) { inflight = Math.max(0, inflight + d); lastActivity = Date.now() };
      var fetchWrapper = function (input, init) {
        var req = (typeof Request !== 'undefined' && input instanceof Request) ? input : null;
        var url = absUrl(req ? req.url : input), method = String((init && init.method) || (req && req.method) || 'GET').toUpperCase();
        var entry = { seq: ++seq, kind: 'fetch', method: method, url: url, requestHeaders: headersObj((init && init.headers) || (req && req.headers)),
                      requestBody: bodyText(init && init.body), start: Date.now(), status: 0 };
        record(entry);
        var route = routeFor(url, method);
        if (cfg.offline || (route && route.action === 'abort')) {
          entry.failed = cfg.offline ? 'offline' : 'blocked by a route'; entry.end = Date.now();
          return Promise.reject(new TypeError('Load failed'));
        }
        if (route && route.action === 'fulfill') {
          var headers = Object.assign({ 'content-type': route.contentType || 'text/plain' }, route.headers || {});
          entry.status = route.status || 200; entry.responseHeaders = headers; entry.mocked = true; entry.end = Date.now();
          if (cfg.bodies) entry.responseBody = String(route.body || '').slice(0, cfg.maxBody);
          return Promise.resolve(new Response(route.body == null ? '' : String(route.body), { status: route.status || 200, headers: headers }));
        }
        var extra = cfg.headers && Object.keys(cfg.headers).length && sameOrigin(url) ? cfg.headers : null;
        if (extra) {
          init = Object.assign({}, init || {});
          var merged = new Headers((init && init.headers) || (req && req.headers) || {});
          for (var k in extra) merged.set(k, extra[k]);
          init.headers = merged;
        }
        activity(1);
        return origFetch.call(this, input, init).then(function (response) {
          activity(-1);
          entry.status = response.status; entry.statusText = response.statusText; entry.type = response.type;
          entry.responseHeaders = headersObj(response.headers); entry.end = Date.now(); entry.redirected = response.redirected;
          if (response.url && response.url !== url) entry.finalUrl = response.url;
          if (cfg.bodies) { try { readBody(response.clone(), entry) } catch (e) {} }
          return response;
        }, function (error) { activity(-1); entry.failed = String(error && error.message || error); entry.end = Date.now(); throw error });
      };
      try { Object.defineProperty(fetchWrapper, 'toString', { value: function () { return nativeToString.call(origFetch) } }) } catch (e) {}
      try { Object.defineProperty(fetchWrapper, 'name', { value: 'fetch' }) } catch (e) {}
      window.fetch = fetchWrapper;
      var P = OrigXHR.prototype, open = P.open, send = P.send, setHeader = P.setRequestHeader;
      P.open = function (method, url) {
        this.__tdEntry = { seq: 0, kind: 'xhr', method: String(method || 'GET').toUpperCase(), url: absUrl(url), requestHeaders: {} };
        return open.apply(this, arguments);
      };
      P.setRequestHeader = function (k, v) {
        try { if (this.__tdEntry) this.__tdEntry.requestHeaders[String(k).toLowerCase()] = String(v) } catch (e) {}
        return setHeader.apply(this, arguments);
      };
      P.send = function (body) {
        var xhr = this, entry = xhr.__tdEntry;
        if (!entry) return send.apply(this, arguments);
        entry.seq = ++seq; entry.start = Date.now(); entry.status = 0; entry.requestBody = bodyText(body); record(entry);
        var route = routeFor(entry.url, entry.method);
        var later = function (names) { setTimeout(function () { names.forEach(function (n) { try { xhr.dispatchEvent(new ProgressEvent(n)) } catch (e) {} }) }, 0) };
        if (cfg.offline || (route && route.action === 'abort')) {
          entry.failed = cfg.offline ? 'offline' : 'blocked by a route'; entry.end = Date.now();
          later(['error', 'loadend']); return;
        }
        if (route && route.action === 'fulfill') {
          var heads = Object.assign({ 'content-type': route.contentType || 'text/plain' }, route.headers || {});
          var bodyOut = route.body == null ? '' : String(route.body);
          var define = function (name, value) { try { Object.defineProperty(xhr, name, { configurable: true, get: function () { return value } }) } catch (e) {} };
          var parsed = bodyOut; if (xhr.responseType === 'json') { try { parsed = JSON.parse(bodyOut) } catch (e) { parsed = null } }
          define('readyState', 4); define('status', route.status || 200); define('statusText', 'OK'); define('responseText', bodyOut);
          define('response', parsed); define('responseURL', entry.url);
          xhr.getAllResponseHeaders = function () { return Object.keys(heads).map(function (k) { return k + ': ' + heads[k] }).join('\r\n') };
          xhr.getResponseHeader = function (n) { var v = heads[String(n).toLowerCase()]; return v == null ? null : v };
          entry.status = route.status || 200; entry.responseHeaders = heads; entry.mocked = true; entry.end = Date.now();
          if (cfg.bodies) entry.responseBody = bodyOut.slice(0, cfg.maxBody);
          setTimeout(function () { try { xhr.dispatchEvent(new Event('readystatechange')); if (typeof xhr.onreadystatechange === 'function') {} } catch (e) {} }, 0);
          later(['load', 'loadend']); return;
        }
        var extra = cfg.headers && Object.keys(cfg.headers).length && sameOrigin(entry.url) ? cfg.headers : null;
        if (extra) for (var k in extra) { try { setHeader.call(xhr, k, extra[k]); entry.requestHeaders[k.toLowerCase()] = extra[k] } catch (e) {} }
        activity(1);
        xhr.addEventListener('loadend', function () {
          activity(-1);
          entry.status = xhr.status; entry.statusText = xhr.statusText; entry.end = Date.now();
          if (xhr.responseURL && xhr.responseURL !== entry.url) entry.finalUrl = xhr.responseURL;
          try {
            var hs = {};
            String(xhr.getAllResponseHeaders() || '').trim().split(/[\r\n]+/).forEach(function (l) { var i = l.indexOf(':'); if (i > 0) hs[l.slice(0, i).trim().toLowerCase()] = l.slice(i + 1).trim() });
            entry.responseHeaders = hs;
          } catch (e) {}
          if (!xhr.status) entry.failed = entry.failed || 'network error';
          if (cfg.bodies) {
            try {
              if (xhr.responseType === '' || xhr.responseType === 'text') entry.responseBody = String(xhr.responseText || '').slice(0, cfg.maxBody);
              else if (xhr.responseType === 'json') entry.responseBody = JSON.stringify(xhr.response).slice(0, cfg.maxBody);
              else entry.responseBody = '[' + xhr.responseType + ' body]';
            } catch (e) {}
          }
        });
        return send.apply(this, arguments);
      };
      try {
        new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (e) {
            lastActivity = Date.now();
            if (e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest') return;
            if (timing.length >= 1000) timing.shift();
            timing.push({ url: e.name, type: e.initiatorType, duration: Math.round(e.duration), size: e.transferSize || e.encodedBodySize || 0,
                          status: e.responseStatus || 0, start: Math.round(performance.timeOrigin + e.startTime) });
          });
        }).observe({ type: 'resource', buffered: true });
      } catch (e) {}
      var onlineDesc = Object.getOwnPropertyDescriptor(Navigator.prototype, 'onLine');
      try { Object.defineProperty(Navigator.prototype, 'onLine', { configurable: true, enumerable: true, get: function () { return cfg.offline ? false : (onlineDesc && onlineDesc.get ? onlineDesc.get.call(this) : true) } }) } catch (e) {}
      Object.defineProperty(window, KEY, { enumerable: false, configurable: false, value: {
        read: function (since) { since = Number(since) || 0; return { entries: log.filter(function (x) { return x.seq > since }), resources: timing.slice(-500), inflight: inflight, idleFor: Date.now() - lastActivity, dropped: dropped, last: seq, ready: document.readyState } },
        clear: function () { log = []; timing = []; dropped = 0; return true },
        idle: function () { return { inflight: inflight, idleFor: Date.now() - lastActivity, ready: document.readyState } },
        configure: function (next) {
          next = next || {};
          if (Array.isArray(next.routes)) cfg.routes = next.routes.map(function (r) { return { url: String(r.url || ''), method: r.method ? String(r.method).toUpperCase() : '', action: r.action === 'fulfill' ? 'fulfill' : 'abort', status: Number(r.status) || 200, body: r.body, contentType: r.contentType, headers: r.headers, re: globRe(r.url) } });
          if ('bodies' in next) cfg.bodies = !!next.bodies;
          if (next.headers && typeof next.headers === 'object') cfg.headers = next.headers;
          if ('offline' in next && !!next.offline !== cfg.offline) {
            cfg.offline = !!next.offline;
            try { window.dispatchEvent(new Event(cfg.offline ? 'offline' : 'online')) } catch (e) {}
          }
          return { bodies: cfg.bodies, routes: cfg.routes.length, offline: cfg.offline, headers: Object.keys(cfg.headers || {}) };
        }
      } });
      window[KEY].configure(config || {});
    })(/*ARG*/null)
    """#

    static let emulateSource = #"""
    (function (cfg) {
      var KEY = Symbol.for('td.emulate.v1');
      var state = window[KEY];
      if (state) { state.cfg = cfg || {}; return true }
      state = { cfg: cfg || {} };
      Object.defineProperty(window, KEY, { value: state, enumerable: false, configurable: false });
      var nav = Navigator.prototype;
      var langDesc = Object.getOwnPropertyDescriptor(nav, 'language'), langsDesc = Object.getOwnPropertyDescriptor(nav, 'languages');
      try { Object.defineProperty(nav, 'language', { configurable: true, enumerable: true, get: function () { return state.cfg.locale || (langDesc && langDesc.get ? langDesc.get.call(this) : 'en-US') } }) } catch (e) {}
      try { Object.defineProperty(nav, 'languages', { configurable: true, enumerable: true, get: function () { return state.cfg.locale ? Object.freeze([state.cfg.locale]) : (langsDesc && langsDesc.get ? langsDesc.get.call(this) : ['en-US']) } }) } catch (e) {}
      ['DateTimeFormat', 'NumberFormat', 'Collator', 'PluralRules', 'RelativeTimeFormat', 'ListFormat'].forEach(function (name) {
        var C = Intl[name]; if (typeof C !== 'function') return;
        var W = function (locales, options) {
          if (locales === undefined && state.cfg.locale) locales = state.cfg.locale;
          if (name === 'DateTimeFormat' && state.cfg.timezone) { options = Object.assign({}, options || {}); if (!options.timeZone) options.timeZone = state.cfg.timezone }
          return new C(locales, options);
        };
        W.prototype = C.prototype; W.supportedLocalesOf = C.supportedLocalesOf;
        try { Object.defineProperty(Intl, name, { value: W, configurable: true, writable: true }) } catch (e) {}
      });
      ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString'].forEach(function (m) {
        var orig = Date.prototype[m];
        Date.prototype[m] = function (locales, options) {
          if (locales === undefined && state.cfg.locale) locales = state.cfg.locale;
          if (state.cfg.timezone) { options = Object.assign({}, options || {}); if (!options.timeZone) options.timeZone = state.cfg.timezone }
          return orig.call(this, locales, options);
        };
      });
      if (navigator.geolocation) {
        var G = Object.getPrototypeOf(navigator.geolocation), origGet = G.getCurrentPosition, origWatch = G.watchPosition, origClear = G.clearWatch, next = 1;
        var position = function () {
          var g = state.cfg.geolocation;
          return { coords: { latitude: Number(g.latitude), longitude: Number(g.longitude), accuracy: Number(g.accuracy) || 10, altitude: null, altitudeAccuracy: null, heading: null, speed: null }, timestamp: Date.now() };
        };
        G.getCurrentPosition = function (ok) { if (!state.cfg.geolocation) return origGet.apply(this, arguments); setTimeout(function () { try { ok(position()) } catch (e) {} }, 0) };
        G.watchPosition = function (ok) { if (!state.cfg.geolocation) return origWatch.apply(this, arguments); var id = 900000 + next++; setTimeout(function () { try { ok(position()) } catch (e) {} }, 0); return id };
        G.clearWatch = function (id) { if (id >= 900000) return; return origClear.apply(this, arguments) };
      }
      return true;
    })(/*ARG*/null)
    """#
}

// MARK: - Script bodies run with callAsyncJavaScript

public enum BrowserAsyncScripts {
    /// The agent's own script, as an expression (a value, or a function called
    /// with `arg`), else as a function body. The answer comes back as JSON.
    public static func evaluate(_ script: String, asBody: Bool, limit: Int = 1_000_000) -> String {
        let run = asBody
            ? "var __v = await (async function (arg) {\n" + script + "\n}).call(window, arg);"
            : "var __v = (\n" + script + "\n);\nif (typeof __v === 'function') __v = __v.call(window, arg);\n__v = await __v;"
        return run + "\n" + serializer + "\nvar __json = JSON.stringify(__ser(__v, 0));\nif (__json === undefined) __json = 'null';\nreturn __json.length > \(limit) ? { truncated: true, chars: __json.length, json: __json.slice(0, \(limit)) } : { json: __json };"
    }

    static let serializer = #"""
    var __seen = new WeakSet();
    var __ser = function (v, depth) {
      if (v === undefined || v === null) return null;
      var t = typeof v;
      if (t === 'number') return isFinite(v) ? v : String(v);
      if (t === 'string' || t === 'boolean') return v;
      if (t === 'bigint') return v.toString();
      if (t === 'function') return '[function ' + (v.name || 'anonymous') + ']';
      if (t === 'symbol') return v.toString();
      if (depth > 8) return '[…]';
      if (typeof Node !== 'undefined' && v instanceof Node) {
        if (v.nodeType === 1) return { node: String(v.localName), id: v.id || undefined, text: String(v.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 200) };
        return { node: String(v.nodeName), text: String(v.textContent || '').slice(0, 200) };
      }
      if (__seen.has(v)) return '[circular]';
      __seen.add(v);
      if (v instanceof Date) return isNaN(v) ? 'Invalid Date' : v.toISOString();
      if (v instanceof RegExp) return String(v);
      if (v instanceof Error) return { error: v.name, message: v.message, stack: String(v.stack || '').slice(0, 2000) };
      if (typeof Map !== 'undefined' && v instanceof Map) return Array.from(v.entries()).slice(0, 1000).map(function (e) { return [__ser(e[0], depth + 1), __ser(e[1], depth + 1)] });
      if (typeof Set !== 'undefined' && v instanceof Set) return Array.from(v).slice(0, 1000).map(function (x) { return __ser(x, depth + 1) });
      if (Array.isArray(v) || (typeof NodeList !== 'undefined' && v instanceof NodeList) || (typeof HTMLCollection !== 'undefined' && v instanceof HTMLCollection))
        return Array.prototype.slice.call(v, 0, 5000).map(function (x) { return __ser(x, depth + 1) });
      if (ArrayBuffer.isView(v)) return Array.prototype.slice.call(v, 0, 5000);
      var out = {}, n = 0;
      for (var k in v) { if (n++ >= 1000) break; try { out[k] = __ser(v[k], depth + 1) } catch (e) { out[k] = '[unreadable]' } }
      return out;
    };
    """#

    /// Wait inside the page for an element state, text or a script to be true.
    /// Wakes on DOM changes (MutationObserver) with a slow fallback tick; the
    /// app re-runs it if a navigation interrupts.
    public static let wait = BrowserDriverScripts.preamble + #"""
    var a = args || {};
    var timeout = Math.max(0, Number(a.timeoutMs) || 0);
    var state = String(a.state || 'visible');
    var check = function () {
      if (a.kind === 'selector') {
        var nodes; try { nodes = resolveAll(String(a.selector || '')) } catch (e) { return { done: true, invalid: true } }
        var el = firstOf(nodes);
        if (state === 'attached') return { done: nodes.length > 0, count: nodes.length };
        if (state === 'detached') return { done: nodes.length === 0, count: nodes.length };
        if (state === 'hidden') return { done: !el || !visible(el), count: nodes.length };
        if (state === 'enabled') return { done: !!el && visible(el) && enabled(el), count: nodes.length };
        return { done: !!el && visible(el), count: nodes.length };
      }
      if (a.kind === 'text') {
        var body = ''; try { body = document.body ? document.body.innerText : '' } catch (e) {}
        var has = norm(body).toLowerCase().indexOf(norm(a.text).toLowerCase()) !== -1;
        return { done: state === 'hidden' ? !has : has };
      }
      return { done: true };
    };
    return await new Promise(function (resolve) {
      var finished = false, observer = null, tick = null, timer = null;
      var finish = function (value) {
        if (finished) return; finished = true;
        if (observer) observer.disconnect(); clearInterval(tick); clearTimeout(timer);
        value.url = String(location.href); resolve(value);
      };
      var run = function () { var c = check(); if (c.done) finish(c) };
      try { observer = new MutationObserver(run); observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true }) } catch (e) {}
      tick = setInterval(run, 250);
      timer = setTimeout(function () { var c = check(); c.timedOut = !c.done; finish(c) }, timeout);
      run();
    });
    """#

    /// A function the agent wrote, true when the page is ready (Playwright's waitForFunction).
    public static func waitForFunction(_ script: String) -> String {
        #"""
        var deadline = Date.now() + Math.max(0, Number(args.timeoutMs) || 0);
        var probe = async function () {
          var __v = (
        """# + script + #"""

          );
          if (typeof __v === 'function') __v = __v.call(window, args.arg);
          return await __v;
        };
        while (true) {
          var got = null, failed = null;
          try { got = await probe() } catch (e) { failed = String(e && e.message || e) }
          if (got) return { done: true, url: String(location.href) };
          if (Date.now() >= deadline) return { done: false, timedOut: true, error: failed, url: String(location.href) };
          await new Promise(function (r) { requestAnimationFrame(function () { setTimeout(r, 100) }) });
        }
        """#
    }
}

// MARK: - Blocking (WebKit content rule lists)

/// Request blocking the way WebKit does it natively: a content rule list. It
/// blocks every kind of load (documents, images, scripts, fetch, websockets),
/// which a page-level hook cannot.
public enum BrowserContentRules {
    public static let resourceTypes: Set<String> = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "fetch", "websocket", "other"]

    /// A URL pattern as WebKit's `url-filter`: `/regex/` as written, `*`/`**`
    /// wildcards, anything else matched as plain text anywhere in the URL.
    public static func urlFilter(_ pattern: String) throws(BrowserDriverRefusal) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { throw BrowserDriverRefusal("a block pattern is a URL, part of one, a glob like **/*.png, or /regex/") }
        if trimmed.count > 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") {
            let inner = String(trimmed.dropFirst().dropLast())
            if inner.contains("|") || inner.contains("{") { throw BrowserDriverRefusal("WebKit's blocking cannot use | or {} in a pattern; give one block pattern per alternative") }
            return inner
        }
        var out = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            switch character {
            case "*":
                out += ".*"
                let next = trimmed.index(after: index)
                if next < trimmed.endIndex, trimmed[next] == "*" { index = next }
            case "?": out += "."
            case ".", "+", "^", "$", "(", ")", "[", "]", "\\", "|", "{", "}": out += "\\" + String(character)
            default: out.append(character)
            }
            index = trimmed.index(after: index)
        }
        // A pattern with a wildcard is the whole URL (Playwright's glob); without one, any part of it.
        if trimmed.contains("*") || trimmed.contains("?") { return "^" + out + "$" }
        return out
    }

    public static func blockList(_ patterns: [String], types: [String]? = nil) throws(BrowserDriverRefusal) -> String {
        if let types, let bad = types.first(where: { !resourceTypes.contains($0) }) {
            throw BrowserDriverRefusal("\(bad) is not a load type WebKit can block. The types are: \(resourceTypes.sorted().joined(separator: ", ")).")
        }
        var rules: [[String: Any]] = []
        for pattern in patterns {
            var trigger: [String: Any] = ["url-filter": try urlFilter(pattern)]
            if let types, !types.isEmpty { trigger["resource-type"] = types }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Offline: every http(s) and websocket load is blocked.
    public static let offlineList = #"[{"action":{"type":"block"},"trigger":{"url-filter":"^https?://"}},{"action":{"type":"block"},"trigger":{"url-filter":"^wss?://"}}]"#
}

/// A URL the page should reach (browser_page wait for:"url"): part of the URL,
/// a glob (`**/checkout*`), or `/regex/`.
public enum BrowserURLMatch {
    public static func matcher(_ pattern: String) throws(BrowserDriverRefusal) -> @Sendable (String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw BrowserDriverRefusal("name the URL to wait for") }
        if trimmed.count > 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") {
            guard let regex = try? NSRegularExpression(pattern: String(trimmed.dropFirst().dropLast())) else { throw BrowserDriverRefusal("that is not a regular expression this can read") }
            nonisolated(unsafe) let compiled = regex
            return { url in compiled.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        if trimmed.contains("*") {
            let filter = (try? BrowserContentRules.urlFilter(trimmed)) ?? NSRegularExpression.escapedPattern(for: trimmed)
            guard let regex = try? NSRegularExpression(pattern: filter) else { throw BrowserDriverRefusal("that URL pattern could not be read") }
            nonisolated(unsafe) let compiled = regex
            return { url in compiled.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        return { url in url.contains(trimmed) }
    }
}
