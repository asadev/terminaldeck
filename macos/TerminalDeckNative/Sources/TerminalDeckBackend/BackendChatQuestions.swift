import Foundation
import TerminalDeckNativeCore

public enum BackendChatQuestions {
    public struct Option: Identifiable, Sendable {
        public let label: String
        public let detail: String
        public var id: String { label }
    }
    public struct Question: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let text: String
        public let multiple: Bool
        public let secret: Bool
        public let options: [Option]
    }
    public static func isQuestion(_ request: NativeRPCValue) -> Bool {
        request["name"].string == "AskUserQuestion" ||
            ["tool/requestUserInput", "item/tool/requestUserInput"].contains(request["subtype"].string ?? "")
    }
    public static func questions(_ request: NativeRPCValue) -> [Question] {
        guard isQuestion(request) else { return [] }
        return (request["input"]["questions"].elements ?? []).compactMap { value in
            guard let id = value["id"].string ?? value["question"].string, !id.isEmpty else { return nil }
            return Question(id: id, title: value["header"].string ?? "Question", text: value["question"].string ?? "",
                multiple: value["multiSelect"].bool == true, secret: value["isSecret"].bool == true,
                options: (value["options"].elements ?? []).compactMap {
                    guard let label = $0["label"].string else { return nil }
                    return Option(label: label, detail: $0["description"].string ?? "")
                })
        }
    }
    public static func answers(_ request: NativeRPCValue, values: [String: [String]]) -> NativeRPCValue {
        let claude = request["name"].string == "AskUserQuestion"
        return .object(questions(request).map { question in
            let values = values[question.id] ?? []
            return .init(question.id, claude ? .string(values.joined(separator: ", ")) :
                .object([.init("answers", .array(values.map(NativeRPCValue.string)))]))
        })
    }
    public static func validate(_ request: NativeRPCValue, answers: NativeRPCValue) throws {
        guard isQuestion(request) else { return }
        let questions = questions(request)
        guard !questions.isEmpty, answers.fields != nil else { throw NativeRPCError.invalidArguments("This question needs structured answers.") }
        for question in questions {
            let values = request["name"].string == "AskUserQuestion" ? answers[question.id].string.map { [$0] } :
                answers[question.id]["answers"].elements?.compactMap(\.string)
            guard let values, !values.isEmpty, values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 32_768 }) else {
                throw NativeRPCError.invalidArguments("Answer " + question.title + " before submitting.")
            }
        }
    }
}
