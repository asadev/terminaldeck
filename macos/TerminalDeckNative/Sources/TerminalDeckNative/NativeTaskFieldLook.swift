import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - Look

enum FieldPaint {
    static func hex(_ s: String?) -> Color {
        guard let s, s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return .accentColor }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func hue(_ name: String) -> Color {
        switch name {
        case "emerald": hex("#10B981")
        case "sky": hex("#0EA5E9")
        case "amber": hex("#F59E0B")
        case "teal": hex("#14B8A6")
        case "violet": hex("#8B5CF6")
        case "fuchsia": hex("#D946EF")
        case "blue": hex("#3B82F6")
        case "indigo": hex("#6366F1")
        case "orange": hex("#F97316")
        case "rose": hex("#F43F5E")
        default: .secondary
        }
    }

    static func icon(_ kind: FieldKind) -> String {
        switch kind {
        case .dropdown: "chevron.down.circle"
        case .text: "textformat"
        case .date: "calendar"
        case .longText: "text.alignleft"
        case .number: "number"
        case .labels: "tag"
        case .checkbox: "checkmark.square"
        case .money: "banknote"
        case .website: "globe"
        case .formula: "sum"
        case .files: "paperclip"
        case .relationship: "point.3.connected.trianglepath.dotted"
        case .people: "person.2"
        case .progressAuto: "gauge.with.dots.needle.33percent"
        case .email: "envelope"
        case .phone: "phone"
        case .tasks: "checklist"
        case .location: "mappin.and.ellipse"
        case .progressManual: "slider.horizontal.3"
        case .rating: "star"
        case .voting: "hand.thumbsup"
        case .signature: "signature"
        case .button: "cursorarrow.click"
        }
    }
}

/// The coloured icon tile each type wears — in the picker and on every row.
struct FieldTypeIcon: View {
    let kind: FieldKind
    var size: CGFloat = 20

    var body: some View {
        let hue = FieldPaint.hue(TaskFields.info(kind).hue)
        Image(systemName: FieldPaint.icon(kind))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hue)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 5).fill(hue.opacity(0.15)))
            .accessibilityHidden(true)
    }
}

/// An option's chip, tinted with its own colour.
struct OptionChip: View {
    let option: FieldOption
    var onRemove: (() -> Void)?

    var body: some View {
        let c = FieldPaint.hex(option.color)
        HStack(spacing: 4) {
            Text(option.label).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(option.label)")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(c)
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.18)))
    }
}

/// A link-ish chip: a file, a record, a task.
struct RefChip<Icon: View>: View {
    let label: String
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 4) {
            icon
            if let onOpen {
                Button(action: onOpen) { Text(label).lineLimit(1) }.buttonStyle(.plain)
            } else {
                Text(label).lineLimit(1)
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Remove \(label)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8).frame(height: 24)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
    }
}

/// A menu row inside a popover.
struct FieldMenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.secondary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct AddButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "plus").font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .help(label).accessibilityLabel(label)
    }
}

struct EmptyPill: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(text).font(.system(size: 13)).padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
    }
}

struct LinkOut: View {
    let url: URL?
    let label: String

    var body: some View {
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            Image(systemName: "arrow.up.right.square").font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(label).accessibilityLabel(label)
    }
}

struct FieldChipToggle: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                .overlay(Capsule().stroke(on ? Color.accentColor.opacity(0.5) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
