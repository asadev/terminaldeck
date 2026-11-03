import Foundation

extension TaskFields {
    // MARK: Values

    static func isCalendarDate(_ s: String) -> Bool {
        guard let m = s.wholeMatch(of: #/(\d{4})-(\d{2})-(\d{2})/#), let y = Int(m.1), let mo = Int(m.2), let d = Int(m.3) else { return false }
        if y < 1900 || y > 2200 || mo < 1 || mo > 12 || d < 1 { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let days = cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: y, month: mo, day: 1))!)?.count ?? 31
        return d <= days
    }

    static func isTime(_ s: String) -> Bool { s.wholeMatch(of: #/([01]\d|2[0-3]):([0-5]\d)/#) != nil }

    static func cleanString(_ raw: CrmValue?, _ max: Int, _ what: String, multiline: Bool) -> FieldRes<String?> {
        guard let raw, raw != .null else { return .success(nil) }
        guard var s = raw.string else { return .failure(FieldFail("\(what) must be text")) }
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if multiline {
            s = s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    var l = Substring(line)
                    while let last = l.last, last.isWhitespace { l = l.dropLast() }
                    return String(l)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            s = collapse(s)
        }
        if s.isEmpty { return .success(nil) }
        if s.utf16.count > max { return .failure(FieldFail("\(what) is too long (\(max) characters max)")) }
        return .success(s)
    }

    public static func normaliseWebsite(_ raw: CrmValue?) -> FieldRes<String?> {
        let cleaned = cleanString(raw, 2000, "Website", multiline: false)
        guard case .success(let s?) = cleaned else { return cleaned }
        let withScheme = s.firstMatch(of: #/^[a-zA-Z][a-zA-Z0-9+.\-]*:/#) != nil ? s : "https://\(s)"
        guard var u = URLComponents(string: withScheme), let scheme = u.scheme?.lowercased() else {
            return .failure(FieldFail("That is not a web address"))
        }
        if scheme != "http" && scheme != "https" { return .failure(FieldFail("Only http and https links")) }
        guard let host = u.host?.lowercased(), !host.isEmpty else { return .failure(FieldFail("That is not a web address")) }
        if !host.contains(".") && host != "localhost" { return .failure(FieldFail("That is not a web address")) }
        u.scheme = scheme
        u.host = host
        if u.path.isEmpty { u.path = "/" }
        guard let out = u.string else { return .failure(FieldFail("That is not a web address")) }
        return .success(out)
    }

    public static func normaliseEmail(_ raw: CrmValue?) -> FieldRes<String?> {
        let cleaned = cleanString(raw, 254, "Email", multiline: false)
        guard case .success(let s?) = cleaned else { return cleaned }
        if s.wholeMatch(of: #/[^\s@]+@[^\s@]+\.[^\s@]{2,}/#) == nil { return .failure(FieldFail("That is not an email address")) }
        return .success(s)
    }

    public static func normalisePhone(_ raw: CrmValue?) -> FieldRes<String?> {
        let cleaned = cleanString(raw, 40, "Phone", multiline: false)
        guard case .success(let s?) = cleaned else { return cleaned }
        if s.wholeMatch(of: #/\+?[\d\s().\-]+/#) == nil { return .failure(FieldFail("A phone number has digits, spaces, + ( ) - only")) }
        let digits = s.filter { $0.isASCII && $0.isNumber }.count
        if digits < 6 || digits > 15 { return .failure(FieldFail("A phone number has 6 to 15 digits")) }
        return .success(s)
    }

    public static func normaliseLocation(_ raw: CrmValue?) -> FieldRes<CrmValue> {
        guard let raw, raw != .null, raw != .string("") else { return .success(.null) }
        var text: CrmValue? = raw
        var lat: CrmValue = .null
        var lng: CrmValue = .null
        if let o = raw.object {
            text = o["text"]
            lat = o["lat"] ?? .null
            lng = o["lng"] ?? .null
        }
        let t: String
        switch cleanString(text, 300, "Location", multiline: false) {
        case .failure(let f): return .failure(f)
        case .success(nil): return .success(.null)
        case .success(let s?): t = s
        }
        if lat == .null && lng == .null,
           let m = t.wholeMatch(of: #/\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*/#) {
            lat = .number(Double(m.1) ?? .nan)
            lng = .number(Double(m.2) ?? .nan)
        }
        let la: Double? = lat == .null ? nil : (lat.number ?? .nan)
        let ln: Double? = lng == .null ? nil : (lng.number ?? .nan)
        if (la == nil) != (ln == nil) { return .failure(FieldFail("A location needs both latitude and longitude, or neither")) }
        if let la, !la.isFinite || la < -90 || la > 90 { return .failure(FieldFail("Latitude is between -90 and 90")) }
        if let ln, !ln.isFinite || ln < -180 || ln > 180 { return .failure(FieldFail("Longitude is between -180 and 180")) }
        return .success(.object(["text": .string(t), "lat": la.map { .number($0) } ?? .null, "lng": ln.map { .number($0) } ?? .null]))
    }

    /// A Google Maps link for a location, coordinates first when we have them.
    public static func mapHref(_ v: CrmValue) -> String {
        let q: String
        if let la = v["lat"]?.number, let ln = v["lng"]?.number { q = "\(js(la)),\(js(ln))" } else { q = v["text"]?.string ?? "" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return "https://www.google.com/maps/search/?api=1&query=\(q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q)"
    }

    /// An internal link only — "/…", never "//host" or "javascript:".
    static func isInternalHref(_ h: String?) -> Bool {
        guard let h else { return false }
        return h.utf16.count <= 500 && h.hasPrefix("/") && !h.hasPrefix("//") && !h.contains(where: { $0.isWhitespace || $0 == "\\" })
    }

    static func isDataImage(_ d: String) -> Bool {
        let prefixes = ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/webp;base64,"]
        guard let p = prefixes.first(where: { d.hasPrefix($0) }) else { return false }
        let body = d.utf8.dropFirst(p.utf8.count)
        var seenPad = false
        var count = 0
        for c in body {
            if c == UInt8(ascii: "=") {
                seenPad = true
                continue
            }
            if seenPad { return false }
            let ok = (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == UInt8(ascii: "+") || c == UInt8(ascii: "/")
            if !ok { return false }
            count += 1
        }
        return count > 0
    }

    /// THE rule for a value, per kind: what is stored (`.null` = empty), or why not.
    public static func normaliseValue(_ kind: FieldKind, _ config: FieldConfig, _ raw: CrmValue, ctx: ValueCtx) -> FieldRes<CrmValue> {
        if isComputed(kind) { return .failure(FieldFail("This field is calculated — it cannot be set by hand")) }
        if kind == .voting { return .failure(FieldFail("Use the vote button to vote")) }
        if kind == .button { return .failure(FieldFail("Press the button to run it")) }
        func str(_ r: FieldRes<String?>) -> FieldRes<CrmValue> { r.map { $0.map { CrmValue.string($0) } ?? .null } }
        let fail = { (s: String) in FieldRes<CrmValue>.failure(FieldFail(s)) }

        switch kind {
        case .text:
            return str(cleanString(raw, maxText, "Text", multiline: false))
        case .longText:
            return str(cleanString(raw, maxLongText, "Text", multiline: true))
        case .number, .money:
            switch toNumber(raw) {
            case .bad: return fail("That is not a number")
            case .empty: return .success(.null)
            case .value(let n):
                if abs(n) > maxAbsNumber { return fail("That number is too large") }
                return .success(.number(roundTo(n, config.decimals ?? 2)))
            }
        case .checkbox:
            if raw == .null { return .success(.null) }
            guard raw.bool != nil else { return fail("A checkbox is ticked or not") }
            return .success(raw)
        case .date:
            if raw == .null || raw == .string("") { return .success(.null) }
            var date: CrmValue? = raw
            var time: CrmValue = .null
            if let o = raw.object {
                date = o["date"]
                time = o["time"] ?? .null
            }
            if date == .null || date == .string("") { return .success(.null) }
            guard let d = date?.string, isCalendarDate(d) else { return fail("That is not a date") }
            if time != .null && time != .string("") && !(time.string.map(isTime) ?? false) { return fail("That is not a time (HH:MM)") }
            let keep = config.includeTime == true && (time.string.map { !$0.isEmpty } ?? false)
            return .success(.object(["date": .string(d), "time": keep ? time : .null]))
        case .dropdown:
            if raw == .null || raw == .string("") { return .success(.null) }
            guard let id = raw.string else { return fail("Pick one of the options") }
            if !(config.options ?? []).contains(where: { $0.id == id }) { return fail("That option is not on this field") }
            return .success(raw)
        case .labels:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Labels must be a list") }
            var ids: [String] = []
            for v in list {
                guard let id = v.string, (config.options ?? []).contains(where: { $0.id == id }) else { return fail("A label is not on this field") }
                if !ids.contains(id) { ids.append(id) }
            }
            return .success(ids.isEmpty ? .null : .array(ids.map { .string($0) }))
        case .website:
            return str(normaliseWebsite(raw))
        case .email:
            return str(normaliseEmail(raw))
        case .phone:
            return str(normalisePhone(raw))
        case .location:
            return normaliseLocation(raw)
        case .rating:
            if raw == .null || raw == .number(0) { return .success(.null) }
            guard let n = raw.number, n == n.rounded(), n.isFinite else { return fail("A rating is a whole number") }
            let max = config.max ?? 5
            if n < 1 || n > Double(max) { return fail("A rating is 1 to \(max)") }
            return .success(raw)
        case .progressManual:
            switch toNumber(raw) {
            case .bad: return fail("Progress is a number")
            case .empty: return .success(.null)
            case .value(let n):
                let start = config.start ?? 0
                let end = config.end ?? 100
                if n < start || n > end { return fail("Progress is between \(js(start)) and \(js(end))") }
                return .success(.number(roundTo(n, 2)))
            }
        case .people:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("People must be a list") }
            if list.count > maxList { return fail("At most \(maxList) people") }
            var ids: [String] = []
            for v in list {
                guard isUuidLike(v.string) else { return fail("A person is malformed") }
                if !ids.contains(v.string!) { ids.append(v.string!) }
            }
            return .success(ids.isEmpty ? .null : .array(ids.map { .string($0) }))
        case .files:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Files must be a list") }
            if list.count > maxList { return fail("At most \(maxList) files") }
            var out: [CrmValue] = []
            var seen: Set<String> = []
            for f in list {
                guard let o = f.object, let id = o["id"]?.string, isUuidLike(id) else { return fail("A file is malformed") }
                let name = String((o["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").prefix(200))
                if name.isEmpty { return fail("A file has no name") }
                let mime = o["mime"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                if seen.insert(id).inserted { out.append(.object(["id": .string(id), "name": .string(name), "mime": mime.map { .string($0) } ?? .null])) }
            }
            return .success(out.isEmpty ? .null : .array(out))
        case .relationship:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Links must be a list") }
            if list.count > maxList { return fail("At most \(maxList) links") }
            let allowed = config.areas ?? []
            var out: [CrmValue] = []
            var seen: Set<String> = []
            for r in list {
                guard let o = r.object, let area = o["area"]?.string, isRelationshipArea(area) else { return fail("A link is malformed") }
                if !allowed.isEmpty && !allowed.contains(area) { return fail("This field does not link that kind of record") }
                let id = o["id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let label = String(collapse(o["label"]?.string ?? "").prefix(200))
                if id.isEmpty || id.utf16.count > 100 || label.isEmpty { return fail("A link is malformed") }
                guard isInternalHref(o["href"]?.string) else { return fail("A link must point inside the CRM") }
                if seen.insert("\(area):\(id)").inserted {
                    out.append(.object(["area": .string(area), "id": .string(id), "label": .string(label), "href": o["href"]!]))
                }
            }
            return .success(out.isEmpty ? .null : .array(out))
        case .tasks:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Tasks must be a list") }
            if list.count > maxList { return fail("At most \(maxList) tasks") }
            var out: [CrmValue] = []
            var seen: Set<String> = []
            for t in list {
                guard let o = t.object, let id = o["id"]?.string, isUuidLike(id) else { return fail("A task is malformed") }
                let label = String(collapse(o["label"]?.string ?? "").prefix(200))
                if seen.insert(id).inserted { out.append(.object(["id": .string(id), "label": .string(label.isEmpty ? "Task" : label)])) }
            }
            return .success(out.isEmpty ? .null : .array(out))
        case .signature:
            if raw == .null { return .success(.null) }
            guard let o = raw.object else { return fail("A signature is malformed") }
            switch o["mode"]?.string {
            case "drawn":
                guard let d = o["dataUrl"]?.string, isDataImage(d) else { return fail("The drawn signature is not an image") }
                if d.utf16.count > maxSignatureBytes { return fail("The drawn signature is too large") }
                return .success(.object(["mode": .string("drawn"), "dataUrl": .string(d), "by": .string(ctx.userId), "at": .string(ctx.now)]))
            case "typed":
                switch cleanString(o["text"], 80, "Signature", multiline: false) {
                case .failure(let f): return .failure(f)
                case .success(nil): return fail("Type your name to sign")
                case .success(let t?):
                    return .success(.object(["mode": .string("typed"), "text": .string(t), "by": .string(ctx.userId), "at": .string(ctx.now)]))
                }
            default:
                return fail("Draw or type a signature")
            }
        default:
            return fail("Unknown field type")
        }
    }

    /// After "Edit options", what a stored value becomes.
    public static func reconcileValue(_ kind: FieldKind, _ config: FieldConfig, _ value: CrmValue) -> CrmValue {
        if value == .null { return .null }
        switch kind {
        case .dropdown:
            return (config.options ?? []).contains { $0.id == value.string } ? value : .null
        case .labels:
            guard let list = value.array else { return .null }
            let kept = list.filter { v in (config.options ?? []).contains { $0.id == v.string } }
            return kept.isEmpty ? .null : .array(kept)
        case .rating:
            return value.number.map { .number(Swift.min($0, Double(config.max ?? 5))) } ?? .null
        case .progressManual:
            return value.number.map { .number(Swift.min(config.end ?? 100, Swift.max(config.start ?? 0, $0))) } ?? .null
        case .date:
            guard let d = value["date"]?.string else { return .null }
            return .object(["date": .string(d), "time": config.includeTime == true ? (value["time"] ?? .null) : .null])
        case .number, .money:
            return value.number.map { .number(roundTo($0, config.decimals ?? 2)) } ?? .null
        default:
            return value
        }
    }

}
