import Foundation

/// Object-only answers, canonicalized for the equatable wire model.
struct HootAnswers: Equatable {
    let data: Data
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    init(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else { throw HootFormError.invalid("Those answers are not valid JSON.") }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 16 * 1024 else { throw HootFormError.invalid("Those answers are too large. The limit is 16 KiB.") }
        self.data = data
    }
}

enum HootFormError: Error, LocalizedError { case invalid(String)
    var errorDescription: String? { if case let .invalid(text) = self { return text }; return nil }
}

struct HootQuestionField: Equatable, Identifiable {
    enum Kind: String { case string, boolean, number, integer }
    let id: String, label: String, detail: String
    let kind: Kind
    let required: Bool, secret: Bool
    let choices: [String]
    let questionAnswer: Bool
    let minimum: Double?, maximum: Double?, minLength: Int?, maxLength: Int?, pattern: String?
}

struct HootQuestionForm: Equatable {
    let fields: [HootQuestionField]
    let unsupported: String?
    static let none = HootQuestionForm(fields: [], unsupported: nil)

    static func decode(tool: String, arguments: [String: Any]) -> Self {
        guard tool == "hoot.cli" || tool == "copilot.cli" else { return .none }
        let subtype = arguments["subtype"] as? String ?? ""
        let input = arguments["input"] as? [String: Any] ?? [:]
        var fields: [HootQuestionField] = []
        func unavailable() -> Self { .init(fields: [], unsupported: "This question needs a form this phone cannot safely answer. Answer it on the machine.") }
        if subtype == "tool/requestUserInput" || subtype == "item/tool/requestUserInput" {
            guard let questions = input["questions"] as? [[String: Any]], !questions.isEmpty, questions.count <= 32 else { return unavailable() }
            for question in questions {
                guard let id = question["id"] as? String, !id.isEmpty, id.utf8.count <= 256, question["multiSelect"] as? Bool != true else { return unavailable() }
                let options = question["options"] as? [[String: Any]] ?? []
                let choices = options.compactMap { $0["label"] as? String }
                guard choices.count == options.count, choices.count <= 50 else { return unavailable() }
                fields.append(.init(id: id, label: question["header"] as? String ?? id,
                    detail: question["question"] as? String ?? "", kind: .string, required: true,
                    secret: question["isSecret"] as? Bool == true,
                    choices: question["isOther"] as? Bool == true ? [] : choices, questionAnswer: true,
                    minimum: nil, maximum: nil, minLength: nil, maxLength: nil, pattern: nil))
            }
        } else if subtype == "mcpServer/elicitation/request", input["mode"] as? String != "url" {
            guard let schema = (input["requestedSchema"] ?? arguments["requestedSchema"]) as? [String: Any], schema["type"] as? String == "object",
                  let properties = schema["properties"] as? [String: [String: Any]], properties.count <= 32 else { return unavailable() }
            let required = schema["required"] as? [String] ?? []
            guard Set(required).isSubset(of: Set(properties.keys)) else { return unavailable() }
            for id in properties.keys.sorted() {
                let property = properties[id]!
                guard !id.isEmpty, id.utf8.count <= 256, let type = property["type"] as? String,
                      let kind = HootQuestionField.Kind(rawValue: type) else { return unavailable() }
                let choices = property["enum"] as? [String] ?? []
                if property["enum"] != nil && (kind != .string || (property["enum"] as? [String]) == nil) { return unavailable() }
                guard choices.count <= 50 else { return unavailable() }
                fields.append(.init(id: id, label: property["title"] as? String ?? id,
                    detail: property["description"] as? String ?? "", kind: kind, required: required.contains(id),
                    secret: property["format"] as? String == "password", choices: choices, questionAnswer: false,
                    minimum: (property["minimum"] as? NSNumber)?.doubleValue,
                    maximum: (property["maximum"] as? NSNumber)?.doubleValue,
                    minLength: WireCodec.whole(property["minLength"]), maxLength: WireCodec.whole(property["maxLength"]),
                    pattern: property["pattern"] as? String))
            }
        } else if !["can_use_tool", "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "session/request_permission", "mcpServer/elicitation/request"].contains(subtype) { return unavailable() }
        guard Set(fields.map(\.id)).count == fields.count else { return unavailable() }
        return .init(fields: fields, unsupported: nil)
    }

    func answers(_ values: [String: String]) throws -> HootAnswers? {
        if let unsupported { throw HootFormError.invalid(unsupported) }
        guard !fields.isEmpty else { return nil }
        var result: [String: Any] = [:]
        for field in fields {
            let raw = values[field.id] ?? ""
            if raw.isEmpty {
                if field.required { throw HootFormError.invalid("Answer \(field.label) first.") }
                continue
            }
            if !field.choices.isEmpty && !field.choices.contains(raw) { throw HootFormError.invalid("Choose a listed value for \(field.label).") }
            let value: Any
            switch field.kind {
            case .boolean:
                guard ["true", "false"].contains(raw) else { throw HootFormError.invalid("Choose Yes or No for \(field.label).") }
                value = raw == "true"
            case .integer, .number:
                guard let number = Double(raw), number.isFinite,
                      field.kind != .integer || number.rounded() == number,
                      field.minimum == nil || number >= field.minimum!, field.maximum == nil || number <= field.maximum! else {
                    throw HootFormError.invalid("Enter a valid \(field.kind.rawValue) for \(field.label).")
                }
                value = number
            case .string:
                guard field.minLength == nil || raw.count >= field.minLength!, field.maxLength == nil || raw.count <= field.maxLength! else { throw HootFormError.invalid("Check the length of \(field.label).") }
                if let pattern = field.pattern {
                    guard let regex = try? NSRegularExpression(pattern: pattern), regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil else { throw HootFormError.invalid("Check the format of \(field.label).") }
                }
                value = raw
            }
            result[field.id] = field.questionAnswer ? ["answers": [raw]] : value
        }
        return try HootAnswers(result)
    }

    func validate(_ answers: HootAnswers?) -> Bool {
        guard unsupported == nil else { return false }
        if fields.isEmpty { return answers == nil || answers?.object.isEmpty == true }
        guard let answers else { return false }
        let object = answers.object
        var values: [String: String] = [:]
        for field in fields {
            guard let value = object[field.id] else { continue }
            if field.questionAnswer {
                guard let list = (value as? [String: Any])?["answers"] as? [String], list.count == 1 else { return false }
                values[field.id] = list[0]
            }
            else if field.kind == .boolean, let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { values[field.id] = number.boolValue ? "true" : "false" }
            else if field.kind == .number || field.kind == .integer, let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { values[field.id] = number.stringValue }
            else if let string = value as? String { values[field.id] = string }
        }
        guard let canonical = try? self.answers(values) else { return false }
        return canonical == answers
    }
}
