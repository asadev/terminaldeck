import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// A section in the existing database Overview, using the native settings kit.
struct NativeAppsDataDatabaseConnectionPanel: View {
    let connection: NativeAppsDataDatabaseConnection?
    let loading: Bool
    let problem: String?
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    @State private var copyNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeSettingsProse(text: "Use this private address from an app on the same server. It is not an internet address.")
            if loading {
                NativePageNote("Reading connection details…", busy: true).frame(height: 28)
                ForEach(["Private host", "Port", "Username", "Password"], id: \.self) { label in
                    NativeSettingRow(label: label) { Text("Connection details") }
                        .redacted(reason: .placeholder).accessibilityHidden(true)
                }
                .allowsHitTesting(false)
            } else if let problem, !problem.isEmpty {
                NativeCodingAINotice(tone: .error, text: problem)
                Button("Try again", action: onRefresh)
            } else if let connection {
                NativeSettingRow(label: "Private host") {
                    Text(connection.host).font(.callout.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NativeSettingRow(label: "Port", help: "The number your app uses to reach this database.") {
                    Text(String(connection.port)).monospacedDigit().textSelection(.enabled)
                }
                if let database = connection.database {
                    NativeSettingRow(label: "Database") { Text(database).textSelection(.enabled) }
                }
                NativeSettingRow(label: "Username") { Text(connection.username).textSelection(.enabled) }
                if let authenticationDatabase = connection.authenticationDatabase {
                    NativeSettingRow(label: "Authentication database", help: "Use this when connecting to MongoDB.") {
                        Text(authenticationDatabase).textSelection(.enabled)
                    }
                }
                NativeSettingRow(label: "Password", help: "The password stays hidden in this database’s settings.") {
                    Text("••••••••").accessibilityLabel("Password hidden")
                }
                NativeSettingRow(label: "Password setting") {
                    Text(connection.passwordKey).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Copy address") {
                        NSPasteboard.general.clearContents()
                        copyNotice = NSPasteboard.general.setString(connection.address, forType: .string)
                            ? "Private address copied." : "The address could not be copied. Select the host and port above."
                    }
                    Button("Open settings", action: onOpenSettings)
                    Button("Refresh", action: onRefresh)
                }
                if let copyNotice {
                    Text(copyNotice).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                NativeSettingsProse(text: "Connection details are unavailable. Try reading them again from this server.")
                Button("Try again", action: onRefresh)
            }
        }
        .onChange(of: connection?.address) { _, _ in copyNotice = nil }
    }
}
