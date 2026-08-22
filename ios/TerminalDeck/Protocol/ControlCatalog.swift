/**
 * What each control is allowed to offer, and how to describe it — the phone's
 * copy of the desktop's control catalogue.
 *
 * A port of `src/renderer/chat/controls/catalog.ts` and the fallback rows of
 * `src/shared/model-catalog.ts`. The desktop's own cluster and the PWA both read
 * that one file so the three surfaces offer the identical options; Swift cannot
 * import it, so this is the copy, and it changes only when that file changes,
 * with the same ids and labels. The values here are what get typed at the real
 * `claude` binary, which is why the ids are frozen rather than free text.
 *
 * Only the fallback model list is carried — the phone never scrapes a live
 * picker — so `foldDefaultRow` collapses to "no default row present" and the
 * rows pass through unchanged. If a phone is ever given the live picker, that is
 * where a fold would go.
 */

import Foundation

/// One row of a control's sheet. `hint` is a short tag under the label for a
/// fact about *this* account a reader cannot get from the row itself; `group` is
/// a caption starting a run of a different kind of claim (the "Earlier models"
/// heading). A description that would be true of any reader belongs to neither.
struct ControlOption: Equatable, Identifiable {
    let id: String
    let label: String
    var hint: String?
    var group: String?
}

enum ControlCatalog {
    /// The five permission modes, in the order shift+tab visits them. `dontAsk`
    /// is deliberately absent — the CLI accepts it but never cycles into it.
    static let permission: [ControlOption] = [
        ControlOption(id: "plan", label: "Plan", hint: "Research and propose; change nothing"),
        ControlOption(id: "manual", label: "Manual", hint: "Ask before every action that needs permission"),
        ControlOption(id: "acceptEdits", label: "Accept edits", hint: "File edits go through without asking"),
        ControlOption(id: "auto", label: "Auto", hint: "Claude judges each call and blocks risky ones"),
        ControlOption(id: "bypass", label: "Bypass", hint: "No permission checks at all"),
    ]

    /// Effort levels. Extra high is first because it is what this app sets when
    /// nothing is set, and the first row of a menu reads as the default.
    static let effort: [ControlOption] = [
        ControlOption(id: "xhigh", label: "Extra high", hint: "the default here"),
        ControlOption(id: "ultracode", label: "Ultracode", hint: "this session only"),
        ControlOption(id: "max", label: "Max"),
        ControlOption(id: "high", label: "High"),
        ControlOption(id: "medium", label: "Medium"),
        ControlOption(id: "low", label: "Low"),
        ControlOption(id: "auto", label: "Auto"),
    ]

    /// Fast mode's two positions. A switch in the model sheet, not a menu of its
    /// own — see `SessionControlsView`.
    static let fast: [ControlOption] = [
        ControlOption(id: "off", label: "Off"),
        ControlOption(id: "on", label: "On"),
    ]

    /// The models the CLI's picker lists, folded the way the desktop folds them.
    /// `recommended` becomes the "your account's default" tag; everything else
    /// carries no hint, per *"just Opus 5 with drop down is good enough"*.
    static let models: [ControlOption] = fallbackModels.map {
        ControlOption(id: $0.alias, label: $0.model,
                      hint: $0.recommended ? "your account’s default" : nil)
    }

    /// The models `/model` still accepts but the picker no longer lists — run
    /// together with the picker's rows they read as one list where half are
    /// guaranteed and half are not, which is what the caption exists to end.
    static let previousModels: [ControlOption] = previousModelRows.enumerated().map { index, row in
        ControlOption(id: row.alias, label: row.model,
                      group: index == 0 ? "Earlier models" : nil)
    }

    /// The rows of one chip's sheet. Fast mode is a switch, not a sheet.
    static func rows(for control: ControlName) -> [ControlOption] {
        switch control {
        case .model: return models + previousModels
        case .effort: return effort
        case .permission: return permission
        case .fast: return fast
        }
    }

    static func name(_ control: ControlName) -> String {
        switch control {
        case .model: return "Model"
        case .effort: return "Effort"
        case .fast: return "Fast mode"
        case .permission: return "Permission"
        }
    }

    /// The unread word for a control: `Not reported` for permission (the CLI
    /// prints it only when it changes), `Unknown` for the rest.
    static func unreadLabel(_ control: ControlName) -> String {
        control == .permission ? "Not reported" : "Unknown"
    }

    /// What a chip prints. A reading with no label shows the unread word; a
    /// model label is shortened the way the desktop's chip shortens it.
    static func displayValue(_ reading: ControlReadingWire, _ control: ControlName) -> String {
        guard let label = reading.label else { return unreadLabel(control) }
        return control == .model ? shortModelLabel(label) : label
    }

    /**
     * Whether an option is the one in force.
     *
     * Exact id first; then a normalised name-and-1M comparison, so a screen that
     * printed "Opus 5 (recommended)" still ticks the `opus` row. A port of
     * `isCurrent`.
     */
    static func isCurrent(_ reading: ControlReadingWire, _ option: ControlOption) -> Bool {
        guard let value = reading.value else { return false }
        if value == option.id { return true }
        let shown = reading.label ?? ""
        if shown.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        let read = modelKey(shown)
        let offered = modelKey(option.label)
        return !read.name.isEmpty && read.name == offered.name && read.long == offered.long
    }

    /// The short label a model chip shows: the name, `Plan` folded in, `1M` kept.
    static func shortModelLabel(_ label: String) -> String {
        let text = label.trimmingCharacters(in: .whitespaces)
        if let name = firstGroup(text, pattern: "^(\\S+) in plan mode") {
            return "\(name) Plan"
        }
        let long = contains1M(text)
        let name = text
            .replacing(pattern: "\\((?:default|recommended)\\)", with: "", caseInsensitive: true)
            .replacing(pattern: "\\(1m context\\)|with 1m context|·\\s*1m", with: "", caseInsensitive: true)
            .replacing(pattern: "\\s+", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return long ? "\(name) 1M" : name
    }

    /// The normalised key two labels are compared on: lowercased, decorations
    /// stripped, and whether it carries a 1M context. A port of `modelKey`.
    private static func modelKey(_ text: String) -> (name: String, long: Bool) {
        let lower = text.lowercased()
        let long = lower.contains("1m")
        let name = lower
            .replacing(pattern: "\\((?:default|recommended)\\)", with: "")
            .replacing(pattern: "\\(1m context\\)|with 1m context|·\\s*1m", with: "")
            .replacing(pattern: "[^a-z0-9. ]+", with: " ")
            .replacing(pattern: "\\s+", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (name, long)
    }

    private static func contains1M(_ text: String) -> Bool {
        text.range(of: "1m", options: .caseInsensitive) != nil
    }
}

// MARK: - The fallback model rows (a port of `FALLBACK_MODELS`/`PREVIOUS_MODELS`)

private struct ModelRow {
    let alias: String
    let model: String
    let recommended: Bool
}

private let fallbackModels: [ModelRow] = [
    ModelRow(alias: "opus[1m]", model: "Opus 5 with 1M context", recommended: true),
    ModelRow(alias: "opus", model: "Opus 5", recommended: false),
    ModelRow(alias: "fable", model: "Fable 5", recommended: false),
    ModelRow(alias: "sonnet", model: "Sonnet 5", recommended: false),
    ModelRow(alias: "haiku", model: "Haiku 4.5", recommended: false),
    ModelRow(alias: "opusplan", model: "Opus in plan mode, else Sonnet", recommended: false),
]

private let previousModelRows: [ModelRow] = [
    ModelRow(alias: "claude-opus-4-8", model: "Opus 4.8", recommended: false),
    ModelRow(alias: "claude-opus-4-5", model: "Opus 4.5", recommended: false),
    ModelRow(alias: "claude-sonnet-4-6", model: "Sonnet 4.6", recommended: false),
]

// MARK: - Small regex conveniences, kept private to this file

private extension String {
    /// `replace(pattern, with)` with the whole-string, multiline-off semantics
    /// the catalogue's JavaScript uses. A bad pattern (never, these are literals)
    /// returns the string unchanged rather than throwing.
    func replacing(pattern: String, with replacement: String, caseInsensitive: Bool = false) -> String {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: replacement)
    }
}

/// The first capture group of `pattern` in `text`, case-insensitive, or nil.
private func firstGroup(_ text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
          let group = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[group])
}
