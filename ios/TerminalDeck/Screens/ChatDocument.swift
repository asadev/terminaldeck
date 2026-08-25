/**
 * One chat bubble, split into the things it is made of.
 *
 * > *"On the copilot page, if we are on chat mode, this copilot should be able
 * > to show the structural data and whatever it needs to show and things."*
 *
 * ## What the wire actually carries, which decided everything below
 *
 * A bubble on this wire is `{ id, role, text, at }` and **`text` is prose**.
 * That is not an omission on the phone's side, it is what the desktop's parser
 * produces: `src/main/chat-transcript.ts` keeps `type: 'text'` blocks and throws
 * everything else away — `textBlocks` ignores every block that is not text, and
 * a `user` line whose content array holds a `tool_result` is refused outright.
 * Its own header says so: *"This module throws all of that away and keeps the
 * prose, because the chat view exists precisely to hide it."*
 *
 * So there are **no tool calls, no tool results, no thinking blocks and no
 * attachments on this wire to render**, and a foldable "tool call" row in this
 * app would be a drawer with nothing behind it. What there *is* is what a coding
 * agent writes into its prose, which is a great deal: fenced code, unified
 * patches, and the paths of the files it touched. This type finds those three,
 * and nothing here infers anything it cannot point at a substring for.
 *
 * ## The bounds, stated
 *
 * Nothing here is unbounded and none of the bounds are this file's own. The
 * desktop clips a bubble at `MAX_COPILOT_MESSAGE_CHARS` (8 KB) and an answer at
 * `MAX_CHAT_ROWS` (200 bubbles); `WireCodec.prose` clips again on arrival. So a
 * whole conversation held on the phone is at most 200 × 8 KB, one linear pass
 * per bubble, and only the bubbles a `LazyVStack` has decided to draw are ever
 * passed through here. `maxBlockLines` is the one bound this file adds, and it
 * exists for the pathological bubble that is 8 KB of one-character lines rather
 * than for anything an agent writes; when it fires the view says how many lines
 * were left out rather than stopping quietly.
 *
 * ## Fences
 *
 * Backticks only. `~~~` is legal CommonMark and no agent CLI writes it — checked
 * against this machine's own transcripts before leaving it out — and supporting a
 * second fence character would double the state this scanner carries for a case
 * that does not occur. An unclosed fence runs to the end of the bubble, which is
 * exactly what a streaming answer looks like halfway through writing one: the
 * code is drawn as code while it is still arriving rather than as prose that
 * turns into code when the closing line lands.
 */

import Foundation

struct ChatDocument: Equatable {

    /// One run of a bubble. `id` is the run's position, which is stable for as
    /// long as the text in front of it is — and an agent's answer only ever
    /// grows at the end, so a block already drawn keeps its identity while the
    /// next one is still arriving.
    enum Block: Equatable, Identifiable {
        case prose(id: Int, text: String)
        /// `language` is the fence's info string, lower-cased, or nil when it
        /// had none. Drawn as a label, never used to decide anything.
        case code(id: Int, language: String?, text: String)
        /// A unified patch: a `diff`-tagged fence, or any run that carries the
        /// markers `git` itself writes. Kept as raw patch text — `DiffText`
        /// parses it, so the chat and the Source Control screen classify a line
        /// with one function rather than two.
        case diff(id: Int, text: String)

        var id: Int {
            switch self {
            case let .prose(id, _), let .code(id, _, _), let .diff(id, _): return id
            }
        }
    }

    let blocks: [Block]

    /**
     * The files this turn named, absolute where they could be made absolute.
     *
     * Read out of inline code spans and out of bare absolute paths, in the order
     * they appear, deduplicated. Relative ones are resolved against the folder
     * the session runs in — which is the folder the agent's own relative paths
     * are relative to — and dropped when that folder is not known, because a
     * chip that cannot be resolved is a chip that opens onto a refusal.
     */
    let paths: [String]

    /// How many lines a single code or diff block may draw. See the header.
    static let maxBlockLines = 400

    /// At most this many path chips under one bubble. A refactor that touched
    /// forty files is a real turn, and forty chips is a wall rather than an
    /// index — the conversation itself is the place to read the whole list.
    static let maxPaths = 8

    // MARK: - Parsing

    /**
     * Split one bubble.
     *
     * `cwd` is the session's own folder, used only to make a relative path
     * absolute. Nil is honest — a session whose folder this phone has not been
     * told about gets chips for absolute paths and none for relative ones,
     * rather than chips resolved against a guess.
     */
    static func parse(_ text: String, cwd: String? = nil) -> ChatDocument {
        var blocks: [Block] = []
        var prose: [Substring] = []
        var fence: (ticks: Int, language: String?, lines: [Substring])?

        func closeProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            prose.removeAll()
            guard !joined.isEmpty else { return }
            // A patch written without a fence, which is how `git diff` output
            // arrives when an agent pastes it inline. Split rather than
            // classified whole: the sentence above the patch is prose and
            // belongs in prose, and drawing it in a monospaced band would be
            // this view deciding that a paragraph is code.
            for piece in splitLoosePatch(joined) {
                blocks.append(piece.patch ? .diff(id: blocks.count, text: piece.text)
                                          : .prose(id: blocks.count, text: piece.text))
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if closesFence(line, ticks: open.ticks) {
                    blocks.append(block(id: blocks.count,
                                        language: open.language,
                                        lines: open.lines))
                    fence = nil
                } else {
                    fence?.lines.append(line)
                }
                continue
            }
            if let opened = opensFence(line) {
                closeProse()
                fence = (ticks: opened.ticks, language: opened.language, lines: [])
                continue
            }
            prose.append(line)
        }

        // An unclosed fence is the ordinary state of a streaming answer, not a
        // malformed one. See the header.
        if let open = fence {
            blocks.append(block(id: blocks.count, language: open.language, lines: open.lines))
        } else {
            closeProse()
        }

        /*
         * The chips come from the **prose**, not from the whole bubble.
         *
         * A path inside a code block is already on screen inside that block, and
         * the backticks in a shell fence are quoting, not code spans — scanning
         * them produced chips for fragments of commands. The prose is where an
         * agent says which files it touched, which is what a chip is an index
         * of.
         */
        let sentences = blocks.compactMap { block -> String? in
            if case let .prose(_, text) = block { return text }
            return nil
        }
        return ChatDocument(blocks: blocks,
                            paths: paths(in: sentences.joined(separator: "\n"), cwd: cwd))
    }

    /// A fence's contents, as the kind of block they are.
    private static func block(id: Int, language: String?, lines: [Substring]) -> Block {
        let body = lines.joined(separator: "\n")
        if let language, ChatDocument.diffLanguages.contains(language) {
            return .diff(id: id, text: body)
        }
        // An untagged fence that is plainly a patch. Agents tag these about half
        // the time; the markers are unambiguous when they do not.
        if language == nil, looksLikePatch(body) { return .diff(id: id, text: body) }
        return .code(id: id, language: language, text: body)
    }

    private static let diffLanguages: Set<String> = ["diff", "patch", "udiff"]

    /// `` ``` `` or more, with an optional info string. The count is kept because
    /// a fence closes on a run at least as long as the one that opened it, which
    /// is what lets a block of markdown contain a shorter fence.
    private static func opensFence(_ line: Substring) -> (ticks: Int, language: String?)? {
        let trimmed = line.drop(while: { $0 == " " })
        let ticks = trimmed.prefix(while: { $0 == "`" }).count
        guard ticks >= 3 else { return nil }
        let info = trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased()
        // An info string with a backtick in it is not an info string — CommonMark
        // forbids it, and allowing it here would let `` ```` `` inside a sentence
        // open a fence that never closes.
        guard !info.contains("`") else { return nil }
        // The language is the first word: agents write ```swift and also
        // ```swift title=x, and the second is one language with a note on it.
        let language = info.split(separator: " ").first.map(String.init)
        return (ticks, language?.isEmpty == false ? language : nil)
    }

    private static func closesFence(_ line: Substring, ticks: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy({ $0 == "`" }) else { return false }
        return trimmed.count >= ticks
    }

    // MARK: - Patches without a fence

    /**
     * Whether a run of text is a unified patch.
     *
     * Two markers, and both have to be there. `@@` alone appears in prose about
     * decorators and in `git log` output; a `---`/`+++` pair alone is a
     * horizontal rule followed by an emphasis marker in enough markdown to
     * matter. `diff --git` on its own is conclusive because nothing else writes
     * it, so it is enough by itself.
     */
    static func looksLikePatch(_ text: String) -> Bool {
        var sawHeader = false
        var sawHunk = false
        var sawChange = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { return true }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") { sawHeader = true }
            if line.hasPrefix("@@") { sawHunk = true }
            if line.hasPrefix("+") || line.hasPrefix("-") { sawChange = true }
        }
        return sawHunk && sawChange && sawHeader
    }

    private struct Piece {
        let text: String
        let patch: Bool
    }

    /**
     * Cut a run of prose where a patch begins, **and where it ends**.
     *
     * The start is deliberately narrow — a patch starts at `diff --git`, or at a
     * `---` line whose next line is `+++` — because everything between the two
     * cuts is handed to the diff renderer, and a false positive turns a
     * paragraph into red and green bands.
     *
     * The end is the half that was got wrong first. Taking the patch to be
     * *everything after* its first line put the sentence an agent writes
     * underneath a patch — "I also touched x" — inside the monospaced band, in
     * grey, at 12 points, photographed on the Simulator. A patch ends at the
     * first line that cannot be part of one, which `stillInPatch` decides.
     */
    private static func splitLoosePatch(_ text: String) -> [Piece] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var start: Int?
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("diff --git ") { start = index; break }
            if line.hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") {
                start = index
                break
            }
        }
        guard let start else { return [Piece(text: text, patch: false)] }

        var end = lines.count
        var index = start
        while index < lines.count {
            if stillInPatch(lines, at: index) {
                index += 1
            } else {
                end = index
                break
            }
        }

        let patch = lines[start..<end].joined(separator: "\n")
        guard looksLikePatch(patch) else { return [Piece(text: text, patch: false)] }

        var pieces: [Piece] = []
        let head = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !head.isEmpty { pieces.append(Piece(text: head, patch: false)) }
        pieces.append(Piece(text: patch, patch: true))
        let tail = lines[end...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !tail.isEmpty { pieces.append(Piece(text: tail, patch: false)) }
        return pieces
    }

    /**
     * Whether the line at `index` is still part of the patch that began above it.
     *
     * A patch line begins with a space, a `+`, a `-`, a `@`, or a `\` — the five
     * first characters `git diff` writes — or is one of the header lines
     * `classify` in `DiffText` already knows by name.
     *
     * The blank line is the case that needs the lookahead. A truly empty line is
     * a context line whose single leading space some tools strip, so it is inside
     * the patch when the next line that has anything on it is; and it is the
     * paragraph break before the sentence underneath the patch when it is not.
     */
    private static func stillInPatch(_ lines: [Substring], at index: Int) -> Bool {
        let line = lines[index]
        if line.isEmpty {
            var next = index + 1
            while next < lines.count, lines[next].isEmpty { next += 1 }
            guard next < lines.count else { return false }
            return stillInPatch(lines, at: next)
        }
        if let first = line.first, " +-@\\".contains(first) { return true }
        return metaPrefixes.contains { line.hasPrefix($0) }
    }

    /// The header lines a patch carries that begin with none of the five
    /// characters above. The same list `DiffText.classify` keeps, for the same
    /// reason and against the same output.
    private static let metaPrefixes = [
        "diff --git", "index ", "new file mode", "deleted file mode", "old mode", "new mode",
        "similarity index", "dissimilarity index", "rename from", "rename to",
        "copy from", "copy to", "Binary files", "GIT binary patch",
    ]

    // MARK: - Paths

    /**
     * The file paths named in a turn.
     *
     * Inline code spans first, because that is where an agent puts a path nine
     * times out of ten and the backticks are the author saying "this is a
     * token, not a sentence". Bare absolute paths after, for the turns written
     * without them.
     *
     * The tests that keep this honest are about what it must **not** return: a
     * URL, a package name with a slash in it, a sentence with a slash in it, and
     * the `+++ b/…` line of a patch — which names a file but names it in git's
     * spelling rather than the filesystem's.
     */
    static func paths(in text: String, cwd: String?) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []

        func consider(_ candidate: String) {
            guard found.count < maxPaths, isPath(candidate) else { return }
            guard let absolute = absolute(candidate, cwd: cwd), seen.insert(absolute).inserted else { return }
            found.append(absolute)
        }

        for span in inlineSpans(text) { consider(span) }
        if found.count < maxPaths {
            for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            where token.hasPrefix("/") {
                consider(String(token).trimmingCharacters(in: pathEdges))
            }
        }
        return found
    }

    /// Characters that routinely sit against a path in a sentence and are never
    /// part of one at its edge.
    private static let pathEdges = CharacterSet(charactersIn: "()[]{}<>,;:'\"`")

    /// The contents of every `` `…` `` span, in order. Spans are single-line:
    /// a backtick pair that straddles a newline is two stray backticks in prose
    /// far more often than it is a code span.
    static func inlineSpans(_ text: String) -> [String] {
        var spans: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var open: String.Index?
            var index = line.startIndex
            while index < line.endIndex {
                if line[index] == "`" {
                    if let start = open {
                        let inner = line[line.index(after: start)..<index]
                        if !inner.isEmpty { spans.append(String(inner)) }
                        open = nil
                    } else {
                        open = index
                    }
                }
                index = line.index(after: index)
            }
        }
        return spans
    }

    /**
     * Whether a token names a file.
     *
     * A slash and no whitespace is the floor. Above that the rejections are what
     * the rule is made of: a scheme means it is a URL and belongs to a browser;
     * a `*` or a `?` means it is a glob and names no single file; a leading `-`
     * means it is a flag with a slash in its argument; and a trailing slash means
     * a folder, which the file reader has nothing to say about.
     */
    static func isPath(_ token: String) -> Bool {
        guard token.count >= 3, token.count <= 512 else { return false }
        guard token.contains("/"), !token.contains("://"), !token.hasSuffix("/") else { return false }
        guard !token.contains(where: { $0 == " " || $0 == "*" || $0 == "?" || $0 == "\t" }) else { return false }
        guard !token.hasPrefix("-") else { return false }
        // git's own spelling of the two sides of a patch. The file is real; this
        // is not its path, and resolving `a/src/x.ts` against a folder produces a
        // path that does not exist.
        guard !token.hasPrefix("a/"), !token.hasPrefix("b/") else { return false }
        let last = token.split(separator: "/").last ?? ""
        // A name with no dot in it is a folder far more often than a file, and
        // nothing in the text tells the two apart — `src/main` and `src/main.ts`
        // are the same shape of token. So the extension carries it, and the names
        // below are the exceptions: files that are conventionally written without
        // one, listed rather than guessed at. A repository that keeps a *folder*
        // under one of these names gets a chip that opens onto the machine
        // refusing the read, which `FileTextView` says plainly — a bounded and
        // explainable miss rather than a chip on every folder anybody mentions.
        if last.contains(".") { return !last.hasSuffix(".") }
        return ChatDocument.extensionless.contains(String(last))
    }

    private static let extensionless: Set<String> = [
        "Makefile", "Dockerfile", "Containerfile", "Procfile", "Gemfile", "Rakefile",
        "Jenkinsfile", "Vagrantfile", "Brewfile", "Justfile", "CMakeLists",
        "hosts", "crontab", "sudoers", "authorized_keys", "known_hosts",
        "LICENSE", "LICENCE", "README", "CHANGELOG", "CODEOWNERS", "NOTICE", "AUTHORS",
    ]

    /// A path the `files.read` verb can be given. The host resolves what it is
    /// sent against its own process, not against the session — so a relative path
    /// has to be joined here, where the session's folder is known, or dropped.
    static func absolute(_ token: String, cwd: String?) -> String? {
        if token.hasPrefix("/") { return token }
        // `~` is the machine's home and this phone does not know what that is.
        // The host does not expand it either.
        if token.hasPrefix("~") { return nil }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        var stem = token
        while stem.hasPrefix("./") { stem.removeFirst(2) }
        guard !stem.hasPrefix("../") else { return nil }
        return cwd.hasSuffix("/") ? cwd + stem : cwd + "/" + stem
    }
}
