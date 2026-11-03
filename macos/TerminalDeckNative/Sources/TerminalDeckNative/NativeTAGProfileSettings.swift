import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeTAGSourceStatus: View {
    let source: String
    let status: String?
    let syncedAt: Double?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(label, systemImage: status == "synced" ? "checkmark.circle" : "doc.text")
                if status == "synced", let syncedAt {
                    Text(Date(timeIntervalSince1970: syncedAt / 1000).formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                Button("Show source") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source)]) }
            }
            Text(source).lineLimit(2).textSelection(.enabled).help(source)
            if let error, !error.isEmpty { Text(error).fixedSize(horizontal: false, vertical: true) }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var label: String {
        switch status {
        case "synced": "Synced"
        case "missing": "Source missing"
        case "error": "Sync failed"
        default: "Sync not confirmed"
        }
    }
}
