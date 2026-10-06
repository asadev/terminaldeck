import SwiftUI
import TerminalDeckNativeCore

// The app's empty states, ported from src/renderer/components/{EmptyState,PageEmpty,PageScope}.tsx.
// Shared: every native screen draws its "nothing here yet" with these, so all of them
// look and read alike, exactly as the page's did.
//
//   NativePageEmpty(symbol: "checklist", title: "No tasks yet") { Text("…") }
//       .action("New task", primary: true) { … }
//   NativePageNote("Loading…")
//   NativePageScope(path: project, detail: "12 files")
//   NativeEmptyState(openProject: …)          the app's own, when nothing is open at all

/// PageEmpty: a centred column — mark, title, body, one action, a hint, extra content —
/// at most 30rem wide, as `.page-blank` in shell.css.
struct NativePageEmpty<Body: View, Hint: View, Extra: View>: View {
    var symbol: String? = nil
    var mark: AnyView? = nil
    let title: String
    @ViewBuilder var message: () -> Body
    var action: PageEmptyAction? = nil
    @ViewBuilder var hint: () -> Hint
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 0) {
            if let mark {
                mark.padding(.bottom, 16)
            } else if let symbol {
                Image(systemName: SymbolName.resolve(symbol, fallback: "square.dashed"))
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .opacity(0.55 / 0.6)
                    .padding(.bottom, 16)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            message()
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            if let action {
                Group {
                    if action.primary {
                        Button(action.label, action: action.perform).buttonStyle(.borderedProminent)
                    } else {
                        Button(action.label, action: action.perform).buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                .disabled(action.busy)
                .padding(.top, 24)
            }
            hint()
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            extra()
                .padding(.top, 24)
        }
        .frame(maxWidth: 480)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct PageEmptyAction {
    let label: String
    var primary = false
    var busy = false
    let perform: () -> Void
}

extension NativePageEmpty where Hint == EmptyView, Extra == EmptyView {
    init(symbol: String? = nil, title: String, action: PageEmptyAction? = nil, @ViewBuilder message: @escaping () -> Body) {
        self.init(symbol: symbol, title: title, message: message, action: action, hint: { EmptyView() }, extra: { EmptyView() })
    }
}

extension NativePageEmpty where Body == EmptyView, Hint == EmptyView, Extra == EmptyView {
    init(symbol: String? = nil, title: String, action: PageEmptyAction? = nil) {
        self.init(symbol: symbol, title: title, message: { EmptyView() }, action: action, hint: { EmptyView() }, extra: { EmptyView() })
    }
}

/// PageNote: one quiet status line ("Loading…", "Nothing matches").
struct NativePageNote: View {
    let text: String
    var busy = false

    init(_ text: String, busy: Bool = false) {
        self.text = text
        self.busy = busy
    }

    var body: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// PageScope: what a page is about — "~/code/app · on this Mac · 12 files". The path
/// truncates from the left, since its last segments tell two checkouts apart.
struct NativePageScope: View {
    let path: String?
    var machine: String? = nil
    var detail: String? = nil

    var body: some View {
        if path != nil || machine != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let path {
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(path)
                    separator
                }
                Text("on \(machine ?? "this Mac")").fixedSize()
                if let detail, !detail.isEmpty {
                    separator
                    Text(detail).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 16)
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}

/// EmptyState: the app's own, when nothing is open at all — the terminal mark, the
/// name and tagline, "Open a project", and the two chords that start things.
struct NativeEmptyState: View {
    let openProject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TerminalMark()
                .frame(width: 44, height: 44)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
            Text("Terminal Deck")
                .font(.largeTitle.weight(.semibold))
            Text("Run your coding agents on one deck.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Button("Open a project", action: openProject)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 24)
            let hints = [("project.open", "to open"), ("session.new", "for a new session")]
                .compactMap { id, text in Keymap.chord(for: id).map { ($0, text) } }
            if !hints.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                        if index > 0 { Text("·") }
                        KeyCap(hint.0)
                        Text(hint.1)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The `>_` mark of EmptyState (24×24 artwork, 1.6 stroke).
private struct TerminalMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 24
            var path = Path()
            path.move(to: CGPoint(x: 4 * s, y: 17 * s))
            path.addLine(to: CGPoint(x: 10 * s, y: 11 * s))
            path.addLine(to: CGPoint(x: 4 * s, y: 5 * s))
            path.move(to: CGPoint(x: 12 * s, y: 19 * s))
            path.addLine(to: CGPoint(x: 20 * s, y: 19 * s))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// A key cap, as the page's `<kbd>`.
struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.separator))
    }
}
