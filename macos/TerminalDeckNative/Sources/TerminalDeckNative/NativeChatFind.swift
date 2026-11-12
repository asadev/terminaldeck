import AppKit
import SwiftUI
import TerminalDeckNativeCore

enum NativeChatFindText {
    static func ranges(_ text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var cursor = 0, result: [NSRange] = []
        while cursor < source.length {
            let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range); cursor = NSMaxRange(range)
        }
        return result
    }
    static func highlight(_ text: AttributedString, query: String) -> AttributedString {
        var result = text
        let plain = String(text.characters)
        for range in ranges(plain, query: query) {
            guard let swift = Range(range, in: plain),
                  let lower = AttributedString.Index(swift.lowerBound, within: result),
                  let upper = AttributedString.Index(swift.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
        }
        return result
    }
    static func highlight(_ text: NSAttributedString, query: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        for range in ranges(text.string, query: query) { result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), range: range) }
        return result
    }
}

private struct NativeChatFindQueryKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var nativeChatFindQuery: String {
        get { self[NativeChatFindQueryKey.self] }
        set { self[NativeChatFindQueryKey.self] = newValue }
    }
}

struct NativeChatFindMatch {
    let id: String
    let firstRow: String
    let range: NSRange
    let snippet: String
}

struct NativeChatFindTarget: NSViewRepresentable {
    let model: NativeHootChatModel
    func makeNSView(context: Context) -> Target { Target(model: model) }
    func updateNSView(_ view: Target, context: Context) { view.model = model }
    @MainActor final class Target: NSView {
        private final class Weak { weak var target: Target?; init(_ target: Target) { self.target = target } }
        private static var targets: [Weak] = []
        var model: NativeHootChatModel
        init(model: NativeHootChatModel) {
            self.model = model
            super.init(frame: .zero)
            Self.targets.removeAll { $0.target == nil }; Self.targets.append(Weak(self))
        }
        required init?(coder: NSCoder) { fatalError("Not used") }
        static func navigate(_ direction: String) {
            guard let target = targets.compactMap(\.target).last(where: {
                $0.window === NSApp.keyWindow && $0.window?.attachedSheet == nil && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }) else { return }
            NativeChatShortcuts.navigate(target.model, action: direction)
        }
    }
}

extension NativeHootChatModel {
    var findMatch: NativeChatFindMatch? { findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil }
    var findState: NativeRPCValue {
        .object([.init("visible", .bool(findVisible)), .init("query", .string(findQuery)),
                 .init("count", .number(Double(findMatches.count))), .init("index", findMatch == nil ? .null : .number(Double(findIndex + 1))),
                 .init("match", findMatch.map { .object([.init("id", .string($0.id)), .init("snippet", .string($0.snippet)),
                     .init("location", .number(Double($0.range.location))), .init("length", .number(Double($0.range.length)))]) } ?? .null)])
    }
    func updateFind() {
        guard findVisible, !findQuery.isEmpty else { findMatches = []; findIndex = 0; return }
        let old = findMatch
        findMatches = HootChatItem.items(displayRows).flatMap { item -> [NativeChatFindMatch] in
            let row: HootChatRow?
            let first: String
            switch item {
            case .row(let value): row = value; first = value.id
            case .reply(let key, let answer, _, _): row = answer; first = key
            }
            guard let row, [.user, .message, .textDelta, .error].contains(row.kind), let text = row.value["text"].string else { return [] }
            let plain = text as NSString
            return NativeChatFindText.ranges(text, query: findQuery).map { range in
                let start = max(0, range.location - 35), end = min(plain.length, NSMaxRange(range) + 65)
                let snippet = plain.substring(with: plain.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start)))
                return NativeChatFindMatch(id: item.id, firstRow: first, range: range, snippet: snippet)
            }
        }
        findIndex = old.flatMap { prior in findMatches.firstIndex { $0.id == prior.id && $0.range == prior.range } } ?? min(findIndex, max(0, findMatches.count - 1))
    }
    func findChat(_ direction: String, query: String? = nil) {
        if direction == "close" { findVisible = false; updateFind(); return }
        findVisible = true
        if let query, query != findQuery { findIndex = 0; findQuery = query }
        updateFind()
        if !findMatches.isEmpty {
            if direction == "next" { findIndex = (findIndex + 1) % findMatches.count }
            if direction == "previous" { findIndex = (findIndex + findMatches.count - 1) % findMatches.count }
        }
        findRevision += 1
    }
}

struct NativeChatFindBar: View {
    @Bindable var model: NativeHootChatModel
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            NativeSessionTextField("Find in conversation", text: $model.findQuery)
                .sessionFocused($focused)
                .onSubmit { model.findChat(NSEvent.modifierFlags.contains(.shift) ? "previous" : "next") }
                .onExitCommand { model.findChat("close") }
                .textFieldStyle(.plain)
                .onChange(of: model.findQuery) { _, _ in model.updateFind(); model.findRevision += 1 }
            Text(model.findMatches.isEmpty ? "0 matches" : "\(model.findIndex + 1) of \(model.findMatches.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            NativeSessionButton { model.findChat("previous") } label: { Image(systemName: "chevron.up") }.help("Previous match").disabled(model.findMatches.isEmpty)
            NativeSessionButton { model.findChat("next") } label: { Image(systemName: "chevron.down") }.help("Next match").disabled(model.findMatches.isEmpty)
            NativeSessionButton { model.findChat("close") } label: { Image(systemName: "xmark") }.help("Close search")
        }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 8)
            .onAppear { focused = true }
    }
}
