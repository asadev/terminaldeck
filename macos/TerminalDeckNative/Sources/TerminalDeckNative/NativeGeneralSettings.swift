import SwiftUI
import TerminalDeckNativeCore

/// Settings → General (`GeneralSection.tsx`): the heading and the section's rows
/// of the table — Pick up where you left off, Name sessions from the
/// conversation, Confirm before deleting a session, Copy on select.
struct NativeGeneralSettings: View {
    var body: some View {
        NativeSettingsPage(sectionId: "general") {
            Section {
                NativeSettingsList(section: "general")
            }
        }
    }
}
