import Foundation

extension TaskFields {
    // MARK: The formula engine

    enum Tok: Equatable {
        case num(Double)
        case ref(String)
        case fn(String)
        case op(Character)
        case open, close, comma
    }

    static func tokenize(_ src: String) -> FieldRes<[Tok]> {
        let chars = Array(src)
        var out: [Tok] = []
        var i = 0
        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        func isWordStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                i += 1
                continue
            }
            if isDigit(ch) || ch == "." {
                var j = i
                var text = ""
                if isDigit(ch) {
                    while j < chars.count, isDigit(chars[j]) { text.append(chars[j]); j += 1 }
                    if j < chars.count, chars[j] == "." {
                        text.append(".")
                        j += 1
                        while j < chars.count, isDigit(chars[j]) { text.append(chars[j]); j += 1 }
                    }
                } else {
                    guard j + 1 < chars.count, isDigit(chars[j + 1]) else { return .failure(FieldFail("Unexpected “\(ch)”")) }
                    text = "0."
                    j += 1
                    while j < chars.count, isDigit(chars[j]) { text.append(chars[j]); j += 1 }
                }
                out.append(.num(Double(text) ?? 0))
                i = j
                continue
            }
            if ch == "{" {
                guard let close = chars[(i + 1)...].firstIndex(of: "}") else { return .failure(FieldFail("A { has no closing }")) }
                let inside = String(chars[(i + 1)..<close])
                let name = collapse(inside)
                if name.isEmpty { return .failure(FieldFail("Empty {} — put a field name inside")) }
                if name.contains("{") { return .failure(FieldFail("Braces cannot be nested")) }
                out.append(.ref(name))
                i = close + 1
                continue
            }
            if isWordStart(ch) {
                var j = i
                var word = ""
                while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { word.append(chars[j]); j += 1 }
                let lower = word.lowercased()
                guard formulaFunctions.contains(lower) else { return .failure(FieldFail("Unknown word “\(word)” — put field names in {braces}")) }
                out.append(.fn(lower))
                i = j
                continue
            }
            switch ch {
            case "+", "-", "*", "/", "%": out.append(.op(ch))
            case "×": out.append(.op("*"))
            case "÷": out.append(.op("/"))
            case "(": out.append(.open)
            case ")": out.append(.close)
            case ",": out.append(.comma)
            default: return .failure(FieldFail("Unexpected “\(ch)”"))
            }
            i += 1
        }
        if out.count > 300 { return .failure(FieldFail("Formula is too long")) }
        return .success(out)
    }

    static let arity: [String: (Int, Int)] = ["round": (1, 2), "min": (1, 20), "max": (1, 20), "abs": (1, 1), "floor": (1, 1), "ceil": (1, 1)]

    private struct Parser {
        let ts: [Tok]
        var pos = 0
        var depth = 0

        func peek() -> Tok? { pos < ts.count ? ts[pos] : nil }

        mutating func expr() -> FieldRes<FormulaAst> {
            depth += 1
            if depth > 64 { return .failure(FieldFail("Formula is nested too deeply")) }
            var node: FormulaAst
            switch term() {
            case .failure(let f): return .failure(f)
            case .success(let n): node = n
            }
            while case .op(let o)? = peek(), o == "+" || o == "-" {
                pos += 1
                switch term() {
                case .failure(let f): return .failure(f)
                case .success(let r): node = .bin(o, node, r)
                }
            }
            depth -= 1
            return .success(node)
        }

        mutating func term() -> FieldRes<FormulaAst> {
            var node: FormulaAst
            switch unary() {
            case .failure(let f): return .failure(f)
            case .success(let n): node = n
            }
            while case .op(let o)? = peek(), o == "*" || o == "/" || o == "%" {
                pos += 1
                switch unary() {
                case .failure(let f): return .failure(f)
                case .success(let r): node = .bin(o, node, r)
                }
            }
            return .success(node)
        }

        mutating func unary() -> FieldRes<FormulaAst> {
            if case .op(let o)? = peek(), o == "-" || o == "+" {
                pos += 1
                depth += 1
                if depth > 64 { return .failure(FieldFail("Formula is nested too deeply")) }
                let e = unary()
                depth -= 1
                guard case .success(let inner) = e else { return e }
                return o == "-" ? .success(.neg(inner)) : e
            }
            return primary()
        }

        mutating func primary() -> FieldRes<FormulaAst> {
            guard let tk = peek() else { return .failure(FieldFail("The formula ends too early")) }
            switch tk {
            case .num(let v):
                pos += 1
                return .success(.num(v))
            case .ref(let name):
                pos += 1
                return .success(.ref(name))
            case .open:
                pos += 1
                let e = expr()
                guard case .success = e else { return e }
                if peek() != .close { return .failure(FieldFail("A ( has no closing )")) }
                pos += 1
                return e
            case .fn(let name):
                pos += 1
                if peek() != .open { return .failure(FieldFail("\(name) needs ( )")) }
                pos += 1
                var args: [FormulaAst] = []
                if peek() != .close {
                    while true {
                        switch expr() {
                        case .failure(let f): return .failure(f)
                        case .success(let a): args.append(a)
                        }
                        if peek() == .comma {
                            pos += 1
                            continue
                        }
                        break
                    }
                }
                if peek() != .close { return .failure(FieldFail("\(name)( has no closing )")) }
                pos += 1
                let (lo, hi) = TaskFields.arity[name] ?? (1, 1)
                if args.count < lo || args.count > hi {
                    return .failure(FieldFail(lo == hi ? "\(name) takes \(lo) value" : "\(name) takes \(lo) to \(hi) values"))
                }
                return .success(.call(name, args))
            case .close: return .failure(FieldFail("Unexpected )"))
            case .comma: return .failure(FieldFail("Unexpected ,"))
            case .op(let o): return .failure(FieldFail("Unexpected “\(o)”"))
            }
        }
    }

    /// Parse only — refuses a malformed expression at the door.
    public static func parseFormula(_ src: String) -> FieldRes<FormulaAst> {
        if src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(FieldFail("The formula is empty")) }
        if src.utf16.count > 500 { return .failure(FieldFail("Formula is too long")) }
        let toks: [Tok]
        switch tokenize(src) {
        case .failure(let f): return .failure(f)
        case .success(let t): toks = t
        }
        var p = Parser(ts: toks)
        let root = p.expr()
        guard case .success = root else { return root }
        if p.pos < toks.count {
            return .failure(FieldFail(toks[p.pos] == .close ? "Unexpected )" : "Something is missing between two values"))
        }
        return root
    }

    /// Every {Name} an expression refers to, in order, de-duplicated.
    public static func formulaRefs(_ src: String) -> [String] {
        var out: [String] = []
        for m in src.matches(of: #/\{([^{}]*)\}/#) {
            let name = collapse(String(m.1))
            if !name.isEmpty && !out.contains(where: { sameLabel($0, name) }) { out.append(name) }
        }
        return out
    }

    /// A field was renamed: point {Old} at {New}.
    public static func renameFormulaRefs(_ src: String, from: String, to: String) -> String {
        src.replacing(#/\{([^{}]*)\}/#) { m in sameLabel(String(m.1), from) ? "{\(to)}" : String(m.0) }
    }

    static func evaluate(_ ast: FormulaAst, _ resolve: (String) -> FieldRes<Double>) -> FieldRes<Double> {
        switch ast {
        case .num(let v): return .success(v)
        case .ref(let name): return resolve(name)
        case .neg(let e): return evaluate(e, resolve).map { -$0 }
        case .bin(let op, let l, let r):
            let lv: Double, rv: Double
            switch evaluate(l, resolve) {
            case .failure(let f): return .failure(f)
            case .success(let v): lv = v
            }
            switch evaluate(r, resolve) {
            case .failure(let f): return .failure(f)
            case .success(let v): rv = v
            }
            if (op == "/" || op == "%") && rv == 0 { return .failure(FieldFail("Division by zero")) }
            let v: Double = switch op {
            case "+": lv + rv
            case "-": lv - rv
            case "*": lv * rv
            case "/": lv / rv
            default: lv.truncatingRemainder(dividingBy: rv)
            }
            return v.isFinite ? .success(v) : .failure(FieldFail("The result is too large"))
        case .call(let fn, let args):
            var vals: [Double] = []
            for a in args {
                switch evaluate(a, resolve) {
                case .failure(let f): return .failure(f)
                case .success(let v): vals.append(v)
                }
            }
            switch fn {
            case "round":
                let d = vals.count > 1 ? jsRound(vals[1]) : 0
                if d < 0 || d > 10 { return .failure(FieldFail("round() keeps 0 to 10 decimals")) }
                return .success(roundTo(vals[0], Int(d)))
            case "min": return .success(vals.min() ?? .infinity)
            case "max": return .success(vals.max() ?? -.infinity)
            case "abs": return .success(abs(vals[0]))
            case "floor": return .success(vals[0].rounded(.down))
            default: return .success(vals[0].rounded(.up))
            }
        }
    }

    public static func evaluateFormula(_ src: String, _ resolve: (String) -> FieldRes<Double>) -> FieldRes<Double> {
        switch parseFormula(src) {
        case .failure(let f): return .failure(f)
        case .success(let ast): return evaluate(ast, resolve)
        }
    }

    /// The number a field gives a formula, or why it cannot.
    public static func numericValue(_ f: TaskField) -> FieldRes<Double> {
        switch f.kind {
        case .number, .money, .rating, .progressManual:
            return f.value.number.map { .success($0) } ?? .failure(FieldFail("“\(f.label)” is empty"))
        case .checkbox:
            return .success(f.value == .bool(true) ? 1 : 0)
        case .formula:
            return .failure(FieldFail("A formula cannot use another formula (“\(f.label)”)"))
        default:
            return .failure(FieldFail("“\(f.label)” is not a number field"))
        }
    }

    /// A formula field's result from its siblings' current values.
    public static func computeFormula(_ expression: String?, _ fields: [TaskField]) -> FieldRes<Double> {
        guard let expression, !expression.isEmpty else { return .failure(FieldFail("No formula yet — Edit options to write one")) }
        return evaluateFormula(expression) { name in
            let hits = fields.filter { sameLabel($0.label, name) }
            if hits.isEmpty { return .failure(FieldFail("Unknown field “\(name)”")) }
            if hits.count > 1 { return .failure(FieldFail("Two fields are called “\(name)”")) }
            return numericValue(hits[0])
        }
    }

}
