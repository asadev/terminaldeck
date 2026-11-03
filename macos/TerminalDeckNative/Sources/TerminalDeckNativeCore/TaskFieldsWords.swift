import Foundation

extension TaskFields {
    // MARK: Reading a value as words

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static func formatDate(_ date: String, time: String?) -> String {
        guard let m = date.wholeMatch(of: #/(\d{4})-(\d{2})-(\d{2})/#), let mo = Int(m.2), (1...12).contains(mo), let d = Int(m.3) else { return date }
        let s = "\(d) \(months[mo - 1]) \(m.1)"
        if let time, !time.isEmpty { return "\(s) \(time)" }
        return s
    }

    public static func formatNumber(_ n: Double, _ decimals: Int, fixed: Bool = false) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = fixed ? decimals : 0
        f.maximumFractionDigits = decimals
        f.roundingMode = .halfUp
        return f.string(from: NSNumber(value: n)) ?? js(n)
    }

    public static func formatMoney(_ n: Double, _ currency: String, _ decimals: Int) -> String {
        "\(currency) \(formatNumber(n, decimals, fixed: true))"
    }

    /// A value as one line of words; nil = empty. `names` turns people ids into names.
    public static func formatValue(_ kind: FieldKind, _ c: FieldConfig, _ v: CrmValue, names: (String) -> String? = { _ in nil }) -> String? {
        if v == .null { return nil }
        switch kind {
        case .text, .longText, .website, .email, .phone:
            return v.string
        case .number:
            return v.number.map { formatNumber($0, c.decimals ?? 2) }
        case .money:
            return v.number.map { formatMoney($0, c.currency ?? defaultCurrency, c.decimals ?? 2) }
        case .checkbox:
            return v == .bool(true) ? "Checked" : "Unchecked"
        case .date:
            return v["date"]?.string.map { formatDate($0, time: v["time"]?.string) }
        case .dropdown:
            return (c.options ?? []).first { $0.id == v.string }?.label
        case .labels:
            guard let list = v.array else { return nil }
            let words = list.compactMap { id in (c.options ?? []).first { $0.id == id.string }?.label }.filter { !$0.isEmpty }.joined(separator: ", ")
            return words.isEmpty ? nil : words
        case .rating:
            return v.number.map { "\(js($0))/\(c.max ?? 5)" }
        case .progressManual:
            return v.number.map { "\(manualPercent(c, $0))%" }
        case .location:
            return v["text"]?.string
        case .people:
            return v.array.map { $0.map { names($0.string ?? "") ?? "someone" }.joined(separator: ", ") }
        case .files:
            return v.array.map { $0.map { $0["name"]?.string ?? "" }.joined(separator: ", ") }
        case .relationship, .tasks:
            return v.array.map { $0.map { $0["label"]?.string ?? "" }.joined(separator: ", ") }
        case .signature:
            guard v.object != nil else { return nil }
            return v["mode"]?.string == "typed" ? "Signed “\(jsString(v["text"]))”" : "Signed"
        case .voting:
            return v["votes"]?.object.map { "\($0.count) votes" }
        case .button:
            return v["count"]?.number.map { "Pressed \(js($0))×" }
        default:
            return nil
        }
    }

}
