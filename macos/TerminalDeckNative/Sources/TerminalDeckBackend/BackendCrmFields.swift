import Foundation
import TerminalDeckNativeCore

/// Backend entry points for task-fields.ts. The parser, formula evaluator,
/// 23-kind catalogue and ordinary value rules reuse the reviewed Core port.
/// Corrections here preserve the local CRM shim and JS UTF-16 slice limits.
public enum BackendCrmFields {
    public static let fieldKinds = FieldKind.allCases.map(\.rawValue)
    public static let fieldTypes = TaskFields.types
    public static let fieldGroups = FieldGroup.allCases
    public static let fieldColors = TaskFields.colors, currencies = TaskFields.currencies
    public static let defaultCurrency = TaskFields.defaultCurrency
    public static let maxFieldLabel = TaskFields.maxFieldLabel, maxText = TaskFields.maxText, maxLongText = TaskFields.maxLongText
    public static let maxList = TaskFields.maxList, maxSignatureBytes = TaskFields.maxSignatureBytes
    public static let formulaFunctions = TaskFields.formulaFunctions, buttonStatuses = TaskFields.buttonStatuses
    public static let buttonTargetKinds = TaskFields.buttonTargetKinds
    public static func isFieldKind(_ value: String?) -> Bool { value.flatMap(FieldKind.init(rawValue:)) != nil }
    public static func fieldTypeInfo(_ kind: FieldKind) -> FieldTypeInfo { TaskFields.info(kind) }
    public static func isComputedKind(_ kind: FieldKind) -> Bool { TaskFields.isComputed(kind) }
    public static func isActionOnlyKind(_ kind: FieldKind) -> Bool { TaskFields.isActionOnly(kind) }
    public static func hasOptions(_ kind: FieldKind) -> Bool { TaskFields.hasOptions(kind) }
    public static func newFieldKey() -> String { TaskFields.newKey() }
    public static func isUuidLike(_ value: String?) -> Bool { TaskFields.isUuidLike(value) }
    public static func roundTo(_ n: Double, _ decimals: Int) -> Double { TaskFields.roundTo(n, decimals) }
    public static func toNumber(_ raw: CrmValue?) -> TaskFields.Parsed { TaskFields.toNumber(raw) }
    public static func normaliseFieldLabel(_ raw: CrmValue?) -> FieldRes<String> { TaskFields.normaliseLabel(raw?.string) }
    public static func sameLabel(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func string(_ value: CrmValue?) -> String {
        switch value {
        case nil: "undefined"
        case .null: "null"
        case .string(let s): s
        case .number(let n): TaskFields.js(n)
        case .bool(let b): b ? "true" : "false"
        case .object: "[object Object]"
        case .array(let list): list.map { $0 == .null ? "" : string($0) }.joined(separator: ",")
        }
    }
    static func collapse(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    static func fail<T>(_ text: String) -> FieldRes<T> { .failure(FieldFail(text)) }
    /// Number() in the source's clampInt accepts hex/octal/binary strings.
    static func clamped(_ value: CrmValue?, low: Double, high: Double, fallback: Double) -> CrmValue {
        var n = value?.number
        if let raw = value?.string {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let lower = text.lowercased()
                if lower.hasPrefix("0x") { n = UInt64(lower.dropFirst(2), radix: 16).map { Double($0) } }
                else if lower.hasPrefix("0o") { n = UInt64(lower.dropFirst(2), radix: 8).map { Double($0) } }
                else if lower.hasPrefix("0b") { n = UInt64(lower.dropFirst(2), radix: 2).map { Double($0) } }
                else { n = Double(text) }
            }
        }
        guard let n, n.isFinite else { return .number(fallback) }
        // Clamp before Int conversion: crafted 1e300 must never trap Swift.
        return .number(min(high, max(low, TaskFields.jsRound(n))))
    }
    public static func defaultConfig(_ kind: FieldKind) -> FieldConfig { (try? normaliseConfig(kind, nil).get()) ?? FieldConfig() }
    static func normaliseOptions(_ raw: CrmValue?) -> FieldRes<[FieldOption]> {
        guard let raw, raw != .null else { return .success([]) }
        guard let list = raw.array else { return fail("Options must be a list") }
        if list.count > 200 { return fail("Too many options (200 max)") }
        var out: [FieldOption] = []
        for (i, item) in list.enumerated() {
            guard let row = item.object else { return fail("An option is malformed") }
            let label = collapse(row["label"]?.string ?? "")
            if label.isEmpty { return fail("Every option needs a name") }
            if label.utf16.count > 60 { return fail("Option “\(BackendCrmInlineFiles.slice(label, 0, 20))…” is too long (60 max)") }
            if out.contains(where: { sameLabel($0.label, label) }) { return fail("Two options are called “\(label)”") }
            let given = row["id"]?.string
            let id = given.flatMap { $0.wholeMatch(of: #/[A-Za-z0-9_-]{1,40}/#) != nil ? $0 : nil } ?? String(newFieldKey().prefix(36))
            if out.contains(where: { $0.id == id }) { return fail("Two options share an id") }
            let color = row["color"]?.string.flatMap { $0.wholeMatch(of: #/#[0-9a-fA-F]{6}/#) != nil ? $0.uppercased() : nil } ?? fieldColors[i % fieldColors.count]
            out.append(FieldOption(id: id, label: label, color: color))
        }
        return .success(out)
    }
    public static func normaliseConfig(_ kind: FieldKind, _ raw: CrmValue?, siblings: [TaskField]? = nil) -> FieldRes<FieldConfig> {
        if let raw, raw != .null, raw.object == nil { return fail("Settings are malformed") }
        var c = raw?.object ?? [:]
        if kind == .dropdown || kind == .labels {
            return normaliseOptions(c["options"]).map { options in var config = FieldConfig(); config.options = options; return config }
        }
        if kind == .relationship {
            if let areas = c["areas"], areas.array == nil { return fail("Areas must be a list") }
            var out = FieldConfig(), seen: [String] = []
            for area in c["areas"]?.array ?? [] {
                guard BackendCrmShim.isTagArea(area), let label = area.string else { return fail("Unknown area “\(string(area))”") }
                if !seen.contains(label) { seen.append(label) }
            }
            out.areas = seen
            return .success(out)
        }
        switch kind {
        case .number, .formula: c["decimals"] = clamped(c["decimals"], low: 0, high: 6, fallback: 2)
        case .money: c["decimals"] = clamped(c["decimals"], low: 0, high: 4, fallback: 2)
        case .rating: c["max"] = clamped(c["max"], low: 1, high: 10, fallback: 5)
        default: break
        }
        let result = TaskFields.normaliseConfig(kind, .object(c), siblings: nil)
        guard kind == .button, let siblings, case .success(var config) = result, case .field(let fieldID, let value)? = config.action else { return result }
        guard let target = siblings.first(where: { $0.id == fieldID }) else { return fail("The field this button sets is not on this task") }
        if !buttonTargetKinds.contains(target.kind) { return fail("A button cannot set a \(TaskFields.info(target.kind).name) field") }
        switch normaliseValue(target.kind, target.config, value, ctx: ValueCtx(userId: "", now: "")) {
        case .failure(let error): return fail("Button value for “\(target.label)”: \(error.error)")
        case .success(let cleaned): config.action = .field(fieldId: fieldID, value: cleaned); return .success(config)
        }
    }
    public static func normaliseValue(_ kind: FieldKind, _ config: FieldConfig, _ raw: CrmValue, ctx: ValueCtx) -> FieldRes<CrmValue> {
        if kind == .relationship {
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Links must be a list") }
            if list.count > maxList { return fail("At most \(maxList) links") }
            var out: [CrmValue] = [], seen = Set<String>()
            for item in list {
                guard let row = item.object, BackendCrmShim.isTagArea(row["area"]), let area = row["area"]?.string else { return fail("A link is malformed") }
                if let areas = config.areas, !areas.isEmpty, !areas.contains(area) { return fail("This field does not link that kind of record") }
                let id = row["id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let label = BackendCrmInlineFiles.slice(collapse(row["label"]?.string ?? ""), 0, 200)
                if id.isEmpty || id.utf16.count > 100 || label.isEmpty { return fail("A link is malformed") }
                guard let href = row["href"]?.string, href.utf16.count <= 500, href.hasPrefix("/"), !href.hasPrefix("//"),
                      !href.contains(where: { $0.isWhitespace || $0 == "\\" }) else { return fail("A link must point inside the CRM") }
                // A compound key without separator collisions.
                let key = "\(area.utf16.count):\(area)\(id)"
                if seen.insert(key).inserted { out.append(.object(["area": .string(area), "id": .string(id), "label": .string(label), "href": .string(href)])) }
            }
            return .success(out.isEmpty ? .null : .array(out))
        }
        if kind == .website { return normaliseWebsite(raw).map { $0.map(CrmValue.string) ?? .null } }
        if kind == .files || kind == .tasks, let list = raw.array {
            let prepared = list.map { item -> CrmValue in
                guard var row = item.object else { return item }
                for (key, cap) in kind == .files ? [("name", 200), ("mime", 120)] : [("label", 200)] {
                    if let text = row[key]?.string {
                        let cleaned = key == "label" ? collapse(text) : key == "name" ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
                        row[key] = .string(BackendCrmInlineFiles.slice(cleaned, 0, cap))
                    }
                }
                return .object(row)
            }
            return TaskFields.normaliseValue(kind, config, .array(prepared), ctx: ctx)
        }
        return TaskFields.normaliseValue(kind, config, raw, ctx: ctx)
    }
    public static func normaliseWebsite(_ raw: CrmValue?) -> FieldRes<String?> {
        guard let raw, raw != .null else { return .success(nil) }
        guard let text = raw.string else { return fail("Website must be text") }
        let clean = collapse(text)
        if clean.isEmpty { return .success(nil) }
        if clean.utf16.count > 2000 { return fail("Website is too long (2000 characters max)") }
        var input = clean
        if let match = clean.firstMatch(of: #/^([a-zA-Z][a-zA-Z0-9+.\-]*):/#) {
            let scheme = String(match.1).lowercased()
            if scheme != "http" && scheme != "https" { return fail("Only http and https links") }
            // Special URL schemes treat backslashes as slashes and permit an
            // omitted authority separator (https:example.com).
            let body = String(clean[match.range.upperBound...]).replacingOccurrences(of: "\\", with: "/").drop(while: { $0 == "/" })
            input = scheme + "://" + String(body)
        } else { input = "https://" + clean.replacingOccurrences(of: "\\", with: "/") }
        guard var url = URLComponents(string: input), let scheme = url.scheme?.lowercased(), var host = url.host?.lowercased(), !host.isEmpty else { return fail("That is not a web address") }
        guard !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || "#/:<>?@[\\]^|".unicodeScalars.contains($0) || $0.value == 0 }) else { return fail("That is not a web address") }
        switch canonicalIPv4(host) {
        case .failure: return fail("That is not a web address")
        case .success(let ip): if let ip { host = ip }
        }
        guard host.contains(".") || host == "localhost" else { return fail("That is not a web address") }
        if let port = url.port, !(0...65535).contains(port) { return fail("That is not a web address") }
        url.scheme = scheme; url.host = host
        if url.port == 443 && scheme == "https" || url.port == 80 && scheme == "http" { url.port = nil }
        if url.path.isEmpty { url.path = "/" }
        // WHATWG removes literal and percent-encoded dot segments.
        var path: [String] = []
        let pieces = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        for (i, piece) in pieces.enumerated() {
            let value = piece.lowercased().replacingOccurrences(of: "%2e", with: ".")
            if value == "." { if i == pieces.count - 1 { path.append("") }; continue }
            if value == ".." { if path.count > 1 { path.removeLast() }; if i == pieces.count - 1 { path.append("") }; continue }
            path.append(String(piece))
        }
        url.percentEncodedPath = path.joined(separator: "/")
        guard let output = url.url?.absoluteString else { return fail("That is not a web address") }
        return .success(output)
    }
    /// WHATWG's legacy IPv4 forms: 127.1, octal and hex all serialize to four
    /// decimal components; a numeric-looking invalid host is refused.
    static func canonicalIPv4(_ host: String) -> FieldRes<String?> {
        var parts = host.components(separatedBy: ".")
        if parts.count > 1 && parts.last == "" { parts.removeLast() }
        func number(_ part: String) -> UInt64? {
            guard !part.isEmpty else { return nil }
            var value = part.lowercased(), radix = 10
            if value.hasPrefix("0x") { value = String(value.dropFirst(2)); radix = 16 }
            else if value.count >= 2 && value.hasPrefix("0") { value = String(value.dropFirst()); radix = 8 }
            if value.isEmpty { return 0 }
            let allowed = radix == 16 ? "0123456789abcdef" : radix == 8 ? "01234567" : "0123456789"
            guard value.allSatisfy({ allowed.contains($0) }) else { return nil }
            return UInt64(value, radix: radix)
        }
        guard let last = parts.last else { return .success(nil) }
        let endsInNumber = number(last) != nil || last.wholeMatch(of: #/[0-9]+/#) != nil
        guard endsInNumber else { return .success(nil) }
        guard parts.count <= 4 else { return fail("Invalid IPv4") }
        let values = parts.compactMap(number)
        guard values.count == parts.count, values.dropLast().allSatisfy({ $0 <= 255 }), let tail = values.last,
              tail < (UInt64(1) << (8 * (5 - parts.count))) else { return fail("Invalid IPv4") }
        var address = tail
        for (i, value) in values.dropLast().enumerated() { address += value << (8 * (3 - i)) }
        return .success((0..<4).map { String((address >> (8 * (3 - $0))) & 255) }.joined(separator: "."))
    }
    public static func normaliseEmail(_ raw: CrmValue?) -> FieldRes<String?> { TaskFields.normaliseEmail(raw) }
    public static func normalisePhone(_ raw: CrmValue?) -> FieldRes<String?> { TaskFields.normalisePhone(raw) }
    public static func normaliseLocation(_ raw: CrmValue?) -> FieldRes<CrmValue> { TaskFields.normaliseLocation(raw) }
    public static func mapHref(_ value: CrmValue) -> String { TaskFields.mapHref(value) }
    public static func reconcileValue(_ kind: FieldKind, _ config: FieldConfig, _ value: CrmValue) -> CrmValue { TaskFields.reconcileValue(kind, config, value) }
    public static func parseFormula(_ source: String) -> FieldRes<FormulaAst> { TaskFields.parseFormula(source) }
    public static func formulaRefs(_ source: String) -> [String] { TaskFields.formulaRefs(source) }
    public static func renameFormulaRefs(_ source: String, from: String, to: String) -> String { TaskFields.renameFormulaRefs(source, from: from, to: to) }
    public static func evaluateFormula(_ source: String, resolve: (String) -> FieldRes<Double>) -> FieldRes<Double> { TaskFields.evaluateFormula(source, resolve) }
    public static func numericValueOf(_ field: TaskField) -> FieldRes<Double> { TaskFields.numericValue(field) }
    public static func computeFormula(_ expression: String?, fields: [TaskField]) -> FieldRes<Double> { TaskFields.computeFormula(expression, fields) }
    public static func autoProgressOf(_ config: FieldConfig, auto: AutoProgress?) -> (done: Int, total: Int, percent: Int) { TaskFields.autoProgress(config, auto) }
    public static func manualPercent(_ config: FieldConfig, value: Double?) -> Int { TaskFields.manualPercent(config, value) }
    public static func formatDateValue(_ date: String, time: String?) -> String { TaskFields.formatDate(date, time: time) }
    public static func formatNumber(_ n: Double, decimals: Int, fixed: Bool = false) -> String { TaskFields.formatNumber(n, decimals, fixed: fixed) }
    public static func formatMoney(_ n: Double, currency: String, decimals: Int) -> String { TaskFields.formatMoney(n, currency, decimals) }
    public static func formatFieldValue(_ field: TaskField, names: (String) -> String? = { _ in nil }) -> String? { TaskFields.formatValue(field.kind, field.config, field.value, names: names) }
    public static func feedValue(_ text: String?) -> String? {
        text.map { $0.utf16.count > 120 ? BackendCrmInlineFiles.slice($0, 0, 117) + "…" : $0 }
    }
    public static func fieldActivitySentence(_ actor: String, payload: [String: CrmValue]) -> String { ActivityFeedRules.fieldSentence(actor, payload) }
    public static func rowToField(_ row: CrmValue) -> TaskField? {
        guard let r = row.object, let kind = r["kind"]?.string.flatMap(FieldKind.init(rawValue:)) else { return nil }
        let config = (try? normaliseConfig(kind, r["config"]).get()) ?? defaultConfig(kind)
        return TaskField(id: r["id"]?.string ?? "", taskId: r["task_id"]?.string ?? "", label: r["label"]?.string ?? "", kind: kind, config: config,
            value: r["value"] ?? .null, sortOrder: r["sort_order"]?.number, createdBy: r["created_by"]?.string, createdAt: r["created_at"]?.string ?? "", updatedAt: r["updated_at"]?.string)
    }
    public static func sortFields(_ fields: [TaskField]) -> [TaskField] { TaskFields.sorted(fields) }
}
