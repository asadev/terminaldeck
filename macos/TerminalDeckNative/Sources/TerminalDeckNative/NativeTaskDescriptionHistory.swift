import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Description history

struct DescriptionHistorySheet: View {
    let model: TaskDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("Description history").font(.callout.weight(.semibold))
                Spacer()
                Button { model.historyOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Close description history")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let versions = model.versions {
                        if versions.isEmpty {
                            Text("The description has not been changed yet.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(versions.enumerated()), id: \.offset) { _, v in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(localStamp(v.at)) · \(v.by.flatMap { id in model.team.first { $0.id == id }?.name } ?? "Someone")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let to = v.to {
                                    Text(to).textSelection(.enabled)
                                } else if v.from != nil {
                                    Text("Cleared.").italic().foregroundStyle(.secondary)
                                } else {
                                    Text("Changed — the text was not kept. History starts from when this feature was switched on.")
                                        .italic().foregroundStyle(.tertiary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                        }
                    } else {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .onExitCommand { model.historyOpen = false }
    }
}
