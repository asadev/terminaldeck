import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The popup's property cells and people controls, as the CRM page draws them:
// page/property-cells.tsx (Property, Status, Type, Track time, Tags), pill-select.tsx,
// task-people-field.tsx, person-search-list.tsx, people/person-picker.tsx (avatar),
// LocalTaskPopup.tsx (Project folder) and workspace-toggle / workspace-cell.

// MARK: - Colours

enum CrmColor {
    /// The CRM's avatar palette names (`bg-blue-500` …) as colours.
    static func avatar(_ name: String) -> Color {
        switch name {
        case "bg-blue-500": Color(red: 0.23, green: 0.51, blue: 0.96)
        case "bg-violet-500": Color(red: 0.55, green: 0.36, blue: 0.96)
        case "bg-emerald-500": Color(red: 0.06, green: 0.73, blue: 0.51)
        case "bg-amber-500": Color(red: 0.96, green: 0.62, blue: 0.04)
        case "bg-rose-500": Color(red: 0.96, green: 0.25, blue: 0.37)
        case "bg-sky-500": Color(red: 0.05, green: 0.65, blue: 0.91)
        case "bg-indigo-500": Color(red: 0.39, green: 0.40, blue: 0.95)
        case "bg-teal-500": Color(red: 0.08, green: 0.72, blue: 0.65)
        case "bg-orange-500": Color(red: 0.98, green: 0.45, blue: 0.09)
        case "bg-fuchsia-500": Color(red: 0.85, green: 0.27, blue: 0.94)
        default: Color.gray
        }
    }

    /// The status pill's solid colour (pill-select.tsx STATUS_SOLID).
    static func statusSolid(_ status: String) -> Color {
        switch status {
        case "Working on it": Color(red: 0.96, green: 0.62, blue: 0.04)
        case "In Progress": Color(red: 0.49, green: 0.23, blue: 0.93)
        case "Done": Color(red: 0.02, green: 0.59, blue: 0.41)
        case "Stuck": Color(red: 0.88, green: 0.11, blue: 0.28)
        default: Color.secondary.opacity(0.15)
        }
    }

    static func statusInk(_ status: String) -> Color { status == "To-Do" ? Color.primary.opacity(0.75) : .white }

    /// A priority's flag (pill-select.tsx PRIORITY_FLAG).
    static func flag(_ priority: String?) -> Color {
        switch priority {
        case "Critical": Color(red: 0.88, green: 0.11, blue: 0.28)
        case "High": Color(red: 0.96, green: 0.62, blue: 0.04)
        case "Medium": Color(red: 0.15, green: 0.39, blue: 0.92)
        default: Color.secondary
        }
    }

    /// A tag colour (task-more.ts LABEL_TONE) — the swatch, its tint and its ink.
    static func label(_ name: String) -> Color {
        switch name {
        case "red": TaskTone.input
        case "orange": Color.orange
        case "amber", "yellow": TaskTone.waiting
        case "lime", "green": TaskTone.completed
        case "teal": Color.teal
        case "cyan": Color.cyan
        case "blue", "indigo": Color.accentColor
        case "violet", "purple": Color.purple
        case "pink": Color.pink
        default: Color.secondary
        }
    }

    static let labelColors = ["grey", "red", "orange", "amber", "yellow", "lime", "green", "teal", "cyan", "blue", "indigo",
                              "violet", "purple", "pink"]
}
