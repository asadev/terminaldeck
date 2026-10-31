import Foundation

/// Who a project's own instructions say its AI is: "You are **Commander** 🎯 — …" in ClaudeiMatch/CLAUDE.md,
/// "**You are Decker, the lead …**" in ~/Deck Dev/CLAUDE.md. A session opened in that folder already behaves as
/// that person, so a project with no lead is offered that name as its lead (13 Oct). Pure: the caller reads files.
public enum AGTDeclaredLead {
    public struct Found: Equatable, Sendable {
        /// "Commander".
        public let name: String
        /// "CLAUDE.md".
        public let file: String
        /// The full path it was read from.
        public let path: String
        /// The AI that reads this file: claude (CLAUDE.md), codex (AGENTS.md), gemini (GEMINI.md).
        public let provider: String
        public init(name: String, file: String, path: String, provider: String) {
            self.name = name; self.file = file; self.path = path; self.provider = provider
        }
    }

    /// The instruction files each AI reads in a project folder, in the order they are looked at.
    public static let files: [(file: String, provider: String)] = [("CLAUDE.md", "claude"), ("AGENTS.md", "codex"), ("GEMINI.md", "gemini")]
    /// Words that follow "You are" without being anyone's name.
    static let notNames: Set<String> = ["a", "an", "the", "claude", "claude code", "codex", "gemini", "chatgpt", "gpt", "ai", "an ai",
                                        "my", "your", "our", "now", "here", "not", "working", "helping", "in", "on", "at"]

    /// The name the text says its AI is, from its first 60 lines; nil when it names nobody.
    public static func name(in text: String) -> String? {
        let head = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).joined(separator: "\n")
        let patterns = [
            #"You are \*\*([^*\n]{1,48})\*\*"#,                    // You are **Commander** 🎯 — …
            #"\*\*You are ([^,.!;:—–*\n]{1,48})"#,                  // **You are Decker, the lead of …**
            #"(?m)^[\s>#*_]*You are ([^,.!;:—–*\n]{1,48})[,.!;:—–]"#, // You are Max, the lead of …
        ]
        let range = NSRange(head.startIndex..., in: head)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: head, range: range) {
                guard let found = Range(match.range(at: 1), in: head), let name = clean(String(head[found])) else { continue }
                return name
            }
        }
        return nil
    }

    /// A name, or nil: one to three words, each starting with a capital letter or a digit, no emoji or punctuation
    /// around it, and not a word like "a" or an AI's own product name.
    static func clean(_ raw: String) -> String? {
        let kept = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == " " || $0 == "'" || $0 == "’" || $0 == "-"
        }))
        let words = kept.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard (1...3).contains(words.count) else { return nil }
        let name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
        guard (2...40).contains(name.count), !notNames.contains(name.lowercased()),
              words.allSatisfy({ word in word.first.map { $0.isUppercase || $0.isNumber } ?? false }) else { return nil }
        return name
    }

    /// The first declaration in a project's folders: each folder's CLAUDE.md, then AGENTS.md, then GEMINI.md.
    public static func find(folders: [String], read: (String) -> String?) -> Found? {
        for folder in folders {
            let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            for (file, provider) in files {
                let path = base + "/" + file
                guard let text = read(path), let name = name(in: text) else { continue }
                return Found(name: name, file: file, path: path, provider: provider)
            }
        }
        return nil
    }

    /// The first 16 KB of a file (an identity line sits at the top), or nil when it cannot be read.
    public static func readHead(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
