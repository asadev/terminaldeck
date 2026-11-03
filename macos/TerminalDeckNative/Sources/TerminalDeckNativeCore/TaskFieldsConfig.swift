import Foundation

extension TaskFields {
    // MARK: Config

    public static func defaultConfig(_ kind: FieldKind) -> FieldConfig {
        (try? normaliseConfig(kind, nil).get()) ?? FieldConfig()
    }

    static func normaliseOptions(_ raw: CrmValue?) -> FieldRes<[FieldOption]> {
        guard let raw, raw != .null else { return .success([]) }
        guard let list = raw.array else { return .failure(FieldFail("Options must be a list")) }
        if list.count > 200 { return .failure(FieldFail("Too many options (200 max)")) }
        var out: [FieldOption] = []
        for (i, o) in list.enumerated() {
            guard let obj = o.object else { return .failure(FieldFail("An option is malformed")) }
            let label = obj["label"]?.string.map(collapse) ?? ""
            if label.isEmpty { return .failure(FieldFail("Every option needs a name")) }
            if label.utf16.count > 60 { return .failure(FieldFail("Option “\(label.prefix(20))…” is too long (60 max)")) }
            if out.contains(where: { sameLabel($0.label, label) }) { return .failure(FieldFail("Two options are called “\(label)”")) }
            let given = obj["id"]?.string
            let id = given.map { $0.wholeMatch(of: #/[A-Za-z0-9_-]{1,40}/#) != nil } == true ? given! : String(newKey().prefix(36))
            if out.contains(where: { $0.id == id }) { return .failure(FieldFail("Two options share an id")) }
            let color = isHex(obj["color"]?.string) ? obj["color"]!.string!.uppercased() : colors[i % colors.count]
            out.append(FieldOption(id: id, label: label, color: color))
        }
        return .success(out)
    }

    /// The type's settings, cleaned. With `siblings`, a Button checks the field it sets.
    public static func normaliseConfig(_ kind: FieldKind, _ raw: CrmValue?, siblings: [TaskField]? = nil) -> FieldRes<FieldConfig> {
        if let raw, raw != .null, raw.object == nil { return .failure(FieldFail("Settings are malformed")) }
        let c = raw?.object ?? [:]
        var out = FieldConfig()
        switch kind {
        case .dropdown, .labels:
            switch normaliseOptions(c["options"]) {
            case .failure(let f): return .failure(f)
            case .success(let o): out.options = o
            }
        case .number:
            out.decimals = clampInt(c["decimals"], 0, 6, 2)
        case .money:
            if case .string(let given) = c["currency"] {
                guard currencies.contains(given.uppercased()) else { return .failure(FieldFail("Unknown currency “\(given)”")) }
                out.currency = given.uppercased()
            } else {
                out.currency = defaultCurrency
            }
            out.decimals = clampInt(c["decimals"], 0, 4, 2)
        case .date:
            out.includeTime = c["includeTime"] == .bool(true)
        case .rating:
            out.max = clampInt(c["max"], 1, 10, 5)
            out.icon = c["icon"]?.string.flatMap(RatingIcon.init(rawValue:)) ?? .star
        case .progressManual:
            let start = c["start"] == nil ? Parsed.value(0) : toNumber(c["start"])
            let end = c["end"] == nil ? Parsed.value(100) : toNumber(c["end"])
            guard case .value(let s) = start, case .value(let e) = end else { return .failure(FieldFail("Start and end must be numbers")) }
            if abs(s) > 1e9 || abs(e) > 1e9 { return .failure(FieldFail("Start and end are too large")) }
            if !(s < e) { return .failure(FieldFail("Start must be less than end")) }
            out.start = s
            out.end = e
        case .progressAuto:
            let subtasks = c["subtasks"] == nil ? true : c["subtasks"] == .bool(true)
            let checklists = c["checklists"] == nil ? true : c["checklists"] == .bool(true)
            if !subtasks && !checklists { return .failure(FieldFail("Count subtasks, checklists, or both")) }
            out.subtasks = subtasks
            out.checklists = checklists
        case .formula:
            let expression = c["expression"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if expression.utf16.count > 500 { return .failure(FieldFail("Formula is too long (500 characters max)")) }
            if !expression.isEmpty, case .failure(let f) = parseFormula(expression) { return .failure(FieldFail("Formula: \(f.error)")) }
            var currency: String?
            if case .string(let given) = c["currency"], !given.isEmpty {
                guard currencies.contains(given.uppercased()) else { return .failure(FieldFail("Unknown currency “\(given)”")) }
                currency = given.uppercased()
            }
            out.expression = expression
            out.decimals = clampInt(c["decimals"], 0, 6, 2)
            out.currency = currency
        case .relationship:
            if let given = c["areas"], given.array == nil { return .failure(FieldFail("Areas must be a list")) }
            var areas: [String] = []
            for a in c["areas"]?.array ?? [] {
                guard isRelationshipArea(a.string) else { return .failure(FieldFail("Unknown area “\(jsString(a))”")) }
                if !areas.contains(a.string!) { areas.append(a.string!) }
            }
            out.areas = areas
        case .button:
            let given = c["label"]?.string ?? ""
            let label = given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Button" : collapse(given)
            if label.utf16.count > 40 { return .failure(FieldFail("Button label is too long (40 max)")) }
            out.label = label
            out.color = isHex(c["color"]?.string) ? c["color"]!.string!.uppercased() : "#2F6BFF"
            let a = c["action"] ?? .object(["type": .string("status"), "status": .string("Done")])
            guard let obj = a.object else { return .failure(FieldFail("Choose what the button does")) }
            switch obj["type"]?.string {
            case "status":
                guard let s = obj["status"]?.string, buttonStatuses.contains(s) else { return .failure(FieldFail("Choose a status for the button")) }
                out.action = .status(s)
            case "comment":
                let body = obj["body"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if body.isEmpty { return .failure(FieldFail("Write the comment the button adds")) }
                if body.utf16.count > 2000 { return .failure(FieldFail("Comment is too long (2000 max)")) }
                out.action = .comment(body)
            case "field":
                guard let fieldId = obj["fieldId"]?.string, !fieldId.isEmpty else { return .failure(FieldFail("Choose the field the button sets")) }
                let value = obj["value"] ?? .null
                out.action = .field(fieldId: fieldId, value: value)
                if let siblings {
                    guard let target = siblings.first(where: { $0.id == fieldId }) else {
                        return .failure(FieldFail("The field this button sets is not on this task"))
                    }
                    if !buttonTargetKinds.contains(target.kind) { return .failure(FieldFail("A button cannot set a \(info(target.kind).name) field")) }
                    switch normaliseValue(target.kind, target.config, value, ctx: ValueCtx(userId: "", now: "")) {
                    case .failure(let f): return .failure(FieldFail("Button value for “\(target.label)”: \(f.error)"))
                    case .success(let v): out.action = .field(fieldId: fieldId, value: v)
                    }
                }
            default:
                return .failure(FieldFail("Choose what the button does"))
            }
        default:
            break
        }
        return .success(out)
    }

}
