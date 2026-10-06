import SwiftUI
import TerminalDeckNativeCore

// The Hoot row's extras on the native rail (lane B) — renderer/copilot/CopilotEntry.tsx.
// The page sends the row itself (title, owl, status dot); this adds what the web row
// had on top: its hover sentence, and while Hoot's side panel is folded in here
// (lane T's NativeRailPanel), the chevron that says so and a press that brings it back.

enum NativeCopilotEntry {
    /// The panel is folded into this row.
    @MainActor static var parked: Bool { NativeRailPanel.shared.state == .folded }

    /// A press on the row: bring the folded panel back, or open Hoot as before.
    @MainActor static func press(_ open: () -> Void) {
        if parked { NativeRailPanel.shared.open() } else { open() }
    }

    /// `title` on the web row: where the panel is, the blurb, or Hoot's state.
    @MainActor static func help(name: String) -> String {
        let hoot = NativeHootModel.shared
        return CopilotEntryWords.help(name: name, stage: hoot.loading ? nil : hoot.stage,
                                      problem: hoot.state?.problem, parked: parked)
    }
}

/// The chevron pointing back out of the row while the panel is folded in here.
struct NativeCopilotEntryChevron: View {
    @State private var hovered = false

    var body: some View {
        let parked = NativeCopilotEntry.parked
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovered ? .primary : .tertiary)
            .frame(width: parked ? nil : 0)
            .opacity(parked ? 1 : 0)
            .onHover { hovered = $0 }
            .accessibilityHidden(true)
            // Hoot's state for the hover sentence, read once the row is on screen.
            .onAppear { NativeHootModel.shared.start() }
    }
}
