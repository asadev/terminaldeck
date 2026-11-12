import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - Small editors

/// A text cell that saves on leaving it (and on Return for one line). Escape puts
/// the saved value back. While not being typed in it shows the SAVED value.
struct FieldTextCell: View {
    let value: String
    var display: String?
    let onCommit: (String) -> Void
    let readOnly: Bool
    var multiline = false
    var placeholder = "Empty"
    let label: String
    var prefix: String?
    @State private var draft = ""
    @State private var cancel = false
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if let prefix { Text(prefix).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 8) }
            Group {
                if multiline {
                    ZStack(alignment: .topLeading) {
                        if (focused ? draft : value).isEmpty {
                            Text(readOnly ? "—" : "Write something…").foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                        }
                        NativeSessionTextEditor(text: Binding(get: { focused ? draft : value }, set: { draft = $0 }))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 22, maxHeight: 160)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    NativeSessionTextField(readOnly ? "—" : placeholder, text: Binding(get: { focused ? draft : (display ?? value) }, set: { draft = $0 }))
                        .textFieldStyle(.plain)
                        .sessionOnSubmit { focused = false }
                }
            }
            .font(.system(size: 13))
            .sessionFocused($focused)
            .disabled(readOnly)
            .sessionOnExitCommand {
                cancel = true
                focused = false
            }
            .onChange(of: focused) { _, now in
                if now {
                    draft = value
                } else if cancel {
                    cancel = false
                } else if !readOnly && draft != value {
                    onCommit(draft)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(focused ? Color(nsColor: .textBackgroundColor) : hover && !readOnly ? Color.secondary.opacity(0.1) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : .clear))
            .onHover { hover = $0 }
            .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProgressBarField: View {
    let percent: Int
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(TaskTone.completed).frame(width: proxy.size.width * CGFloat(percent) / 100)
                }
            }
            .frame(minWidth: 60, maxWidth: .infinity).frame(height: 6)
            Text("\(percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(percent)%")
    }
}
