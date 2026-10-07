import Foundation

/// A checked lexical subset, NOT an ES module implementation. Supported:
/// semicolon-terminated static string imports (side-effect/default/namespace/
/// named), immutable `export const name = expression;`, `export {local as name};`
/// for a top-level const, and `export default expression;`. Mutable exports,
/// declaration exports, cycles, re-exports, dynamic import, import.meta, import
/// attributes, top-level await and interpolated templates fail explicitly.
/// Source ranges are replaced only after tokens establish a real declaration;
/// strings/comments/regular expressions are never regex-rewritten.
public enum BackendJSCoreModulesESM {
    private struct Token {
        enum Kind: Equatable { case identifier, string, other }
        let text: String
        let start: Int
        let end: Int
        let depth: Int
        let kind: Kind
    }
    private struct Edit { let start: Int; let end: Int; let replacement: String }
    public static func transform(_ source: String) throws -> String {
        let characters = Array(source), tokens = try lex(characters)
        var edits: [Edit] = [], importInitializers: [String] = [], exports: [(String, String)] = [], immutable = Set<String>(), imported = Set<String>(), serial = 0
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .identifier && token.text.hasPrefix("__td_") { throw refusal("identifiers reserved for the checked module wrapper (__td_)") }
            if token.kind == .identifier && token.text == "import" {
                let member = i > 0 && tokens[i - 1].text == "."
                if !member && i + 1 < tokens.count && ["(", "."].contains(tokens[i + 1].text) { throw refusal("dynamic import and import.meta") }
            }
            if token.depth != 0 || token.kind != .identifier { i += 1; continue }
            if token.text == "await" { throw refusal("top-level await") }
            if token.text == "const", i + 2 < tokens.count, isName(tokens[i + 1]), tokens[i + 2].text == "=" { immutable.insert(tokens[i + 1].text) }
            guard ["import", "export"].contains(token.text) else { i += 1; continue }
            // A member/property named export/import is not a declaration.
            if i > 0 && [".", "?."].contains(tokens[i - 1].text) { i += 1; continue }
            // Module declarations begin a statement. This also refuses to edit
            // keyword-looking characters inside an ambiguous slash expression.
            if i > 0 && !(tokens[i - 1].depth == 0 && [";", "}"].contains(tokens[i - 1].text)) { i += 1; continue }
            let end = try statementEnd(tokens, after: i)
            let body = Array(tokens[(i + 1)..<end]), last = tokens[end]
            if token.text == "import" {
                serial += 1
                let parsed = try parseImport(body, serial: serial)
                for name in parsed.names {
                    guard imported.insert(name).inserted else { throw refusal("duplicate import bindings") }
                }
                importInitializers.append(parsed.text)
                edits.append(Edit(start: token.start, end: last.end, replacement: ""))
            } else {
                guard let first = body.first else { throw refusal("empty export declarations") }
                switch first.text {
                case "const":
                    guard body.count >= 4, isName(body[1]), body[2].text == "=", !body.dropFirst(3).contains(where: { $0.depth == 0 && $0.text == "," }) else { throw refusal("export const requires one plain identifier and initializer") }
                    let name = body[1].text
                    immutable.insert(name); exports.append((name, name))
                    edits.append(Edit(start: token.start, end: first.start, replacement: ""))
                case "default":
                    guard body.count >= 2 else { throw refusal("empty default exports") }
                    if ["function", "class", "async"].contains(body[1].text) { throw refusal("default declaration exports; use an expression or immutable const") }
                    serial += 1; let name = "__td_default_\(serial)"
                    exports.append(("default", name))
                    edits.append(Edit(start: token.start, end: first.end, replacement: "const \(name) ="))
                case "{":
                    guard body.last?.text == "}", !body.contains(where: { $0.text == "from" && $0.depth == 0 }) else { throw refusal("re-exports") }
                    let pairs = try names(Array(body.dropFirst().dropLast()))
                    for pair in pairs { exports.append((pair.1, pair.0)) }
                    edits.append(Edit(start: token.start, end: last.end, replacement: ""))
                default: throw refusal("export \(first.text); only immutable const/default-expression/export-list forms are supported")
                }
            }
            i = end + 1
        }
        var taken = Set<String>()
        for (exported, local) in exports {
            guard taken.insert(exported).inserted else { throw refusal("duplicate export names") }
            guard local.hasPrefix("__td_default_") || immutable.contains(local) else { throw refusal("export lists must reference local immutable const bindings") }
            guard !imported.contains(local) else { throw refusal("re-exported import bindings") }
        }
        // The parser does not emulate module live bindings. Every local export
        // is an actual const, so a later assignment naturally throws in JSC.
        // Static dependencies/link bindings precede the module body even when
        // an import declaration appears after executable source statements.
        var result = importInitializers.joined(separator: "\n") + "\n", cursor = 0
        for edit in edits.sorted(by: { $0.start < $1.start }) {
            guard edit.start >= cursor else { throw refusal("overlapping module declarations") }
            result += String(characters[cursor..<edit.start]) + edit.replacement; cursor = edit.end
        }
        result += String(characters[cursor...])
        for (exported, local) in exports {
            let key = quoted(exported)
            result += "\nObject.defineProperty(__td_exports,\(key),{enumerable:true,get:function(){return \(local);}});"
        }
        return result
    }
    private static func parseImport(_ tokens: [Token], serial: Int) throws -> (text: String, names: [String]) {
        if tokens.count == 1, tokens[0].kind == .string { return ("__td_import(\(try specifier(tokens[0])));", []) }
        guard tokens.count >= 3, tokens[tokens.count - 2].text == "from", tokens.last?.kind == .string else { throw refusal("import attributes/nonliteral specifiers or unterminated static imports") }
        let module = "__td_import_\(serial)", path = try specifier(tokens.last!)
        var body = Array(tokens.dropLast(2)), bindings: [(local: String, expression: String, key: String?)] = []
        if let first = body.first, isName(first) {
            bindings.append((first.text, "\(module).default", "default")); body.removeFirst()
            if !body.isEmpty { guard body.removeFirst().text == "," else { throw refusal("static import binding grammar") } }
        }
        if !body.isEmpty {
            if body[0].text == "*" {
                guard body.count == 3, body[1].text == "as", isName(body[2]) else { throw refusal("namespace import grammar") }
                bindings.append((body[2].text, module, nil))
            } else {
                guard body.first?.text == "{", body.last?.text == "}" else { throw refusal("named import grammar") }
                for pair in try names(Array(body.dropFirst().dropLast())) { bindings.append((pair.1, "\(module)[\(quoted(pair.0))]", pair.0)) }
            }
        }
        guard !bindings.isEmpty else { throw refusal("empty static imports") }
        let linked = bindings.map { binding -> String in
            let check = binding.key.map { key in
                "if(!Object.prototype.hasOwnProperty.call(\(module),\(quoted(key)))){const e=new Error('Module does not export '+\(quoted(key)));e.code='ERR_JSCORE_ESM_MISSING_EXPORT';throw e;}"
            } ?? ""
            return check + "const \(binding.local)=\(binding.expression);"
        }.joined()
        return ("const \(module)=__td_import(\(path));" + linked, bindings.map(\.local))
    }
    private static func names(_ tokens: [Token]) throws -> [(String, String)] {
        var result: [(String, String)] = [], i = 0
        while i < tokens.count {
            guard isName(tokens[i]) else { throw refusal("plain identifier import/export lists") }
            let original = tokens[i].text; i += 1; var alias = original
            if i < tokens.count, tokens[i].text == "as" {
                i += 1; guard i < tokens.count, isName(tokens[i]) else { throw refusal("plain identifier import/export aliases") }
                alias = tokens[i].text; i += 1
            }
            result.append((original, alias))
            if i < tokens.count { guard tokens[i].text == "," else { throw refusal("comma-separated import/export lists") }; i += 1 }
        }
        return result
    }
    private static func statementEnd(_ tokens: [Token], after start: Int) throws -> Int {
        for index in (start + 1)..<tokens.count {
            if tokens[index].depth == 0 && tokens[index].text == ";" { return index }
            let member = index > 0 && tokens[index - 1].text == "."
            if !member && tokens[index].depth == 0 && ["import", "export"].contains(tokens[index].text) && tokens[index].kind == .identifier { throw refusal("module declarations must end with a semicolon") }
        }
        throw refusal("module declarations must end with a semicolon")
    }
    private static func specifier(_ token: Token) throws -> String {
        let value = String(token.text.dropFirst().dropLast())
        guard !value.contains("\\"), !value.contains("\n"), !value.contains("\r") else { throw refusal("escaped module specifiers") }
        return quoted(value)
    }
    private static func isName(_ token: Token) -> Bool {
        token.kind == .identifier && token.text.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
    }
    private static func quoted(_ value: String) -> String {
        let bytes = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return bytes.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }
    private static func refusal(_ detail: String) -> BackendJSCoreCompatibilityFailure { .init("ERR_JSCORE_ESM_UNSUPPORTED", "The checked JavaScriptCore ESM subset does not support \(detail)") }
    private static func lex(_ characters: [Character]) throws -> [Token] {
        var result: [Token] = [], i = 0, depth = 0, stack: [(character: Character, control: Bool)] = [], canStartRegex = true
        func identifier(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "$" }
        while i < characters.count {
            let ch = characters[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "/", i + 1 < characters.count, characters[i + 1] == "/" { i += 2; while i < characters.count && characters[i] != "\n" { i += 1 }; continue }
            if ch == "/", i + 1 < characters.count, characters[i + 1] == "*" {
                i += 2; var closed = false
                while i + 1 < characters.count { if characters[i] == "*" && characters[i + 1] == "/" { i += 2; closed = true; break }; i += 1 }
                guard closed else { throw refusal("unterminated comments") }; continue
            }
            let start = i
            if ch == "/" && !canStartRegex && result.last?.text == "}" { throw refusal("ambiguous slash after a closing block/object") }
            if ch == "\"" || ch == "'" || ch == "`" {
                let quote = ch; i += 1; var closed = false
                while i < characters.count {
                    if characters[i] == "\\" { i += 2; continue }
                    if quote == "`", characters[i] == "$", i + 1 < characters.count, characters[i + 1] == "{" { throw refusal("interpolated templates") }
                    if characters[i] == quote { i += 1; closed = true; break }; i += 1
                }
                guard closed else { throw refusal("unterminated strings/templates") }
                result.append(Token(text: String(characters[start..<i]), start: start, end: i, depth: depth, kind: quote == "`" ? .other : .string)); canStartRegex = false; continue
            }
            if ch == "/" && canStartRegex {
                i += 1; var bracket = false, closed = false
                while i < characters.count {
                    if characters[i] == "\\" { i += 2; continue }
                    if characters[i] == "[" { bracket = true }; if characters[i] == "]" { bracket = false }
                    if characters[i] == "/" && !bracket { i += 1; closed = true; break }
                    if characters[i] == "\n" || characters[i] == "\r" { break }; i += 1
                }
                guard closed else { throw refusal("ambiguous/unterminated regular expressions") }
                while i < characters.count && identifier(characters[i]) { i += 1 }
                result.append(Token(text: String(characters[start..<i]), start: start, end: i, depth: depth, kind: .other)); canStartRegex = false; continue
            }
            if identifier(ch) {
                i += 1; while i < characters.count && identifier(characters[i]) { i += 1 }
                let text = String(characters[start..<i])
                result.append(Token(text: text, start: start, end: i, depth: depth, kind: ch.isNumber ? .other : .identifier))
                canStartRegex = ["return", "throw", "case", "delete", "typeof", "void", "new", "yield", "await", "else", "in", "of"].contains(text); continue
            }
            i += 1
            let tokenDepth: Int
            var closedControl = false
            if "([{ ".contains(ch) && ch != " " {
                tokenDepth = depth
                let previous = result.last?.text ?? ""
                let control = ch == "(" && (["if", "while", "for", "switch", "catch", "with"].contains(previous) || (previous == "await" && result.dropLast().last?.text == "for"))
                stack.append((ch, control)); depth += 1
            }
            else if ")] }".contains(ch) && ch != " " {
                let expected: Character = ch == ")" ? "(" : ch == "]" ? "[" : "{"
                guard let opening = stack.popLast(), opening.character == expected else { throw refusal("unbalanced module delimiters") }
                closedControl = ch == ")" && opening.control; depth -= 1; tokenDepth = depth
            } else { tokenDepth = depth }
            result.append(Token(text: String(ch), start: start, end: i, depth: tokenDepth, kind: .other))
            canStartRegex = closedControl || ![")", "]", "}", "."].contains(String(ch))
        }
        guard stack.isEmpty else { throw refusal("unbalanced module delimiters") }
        return result
    }
}
