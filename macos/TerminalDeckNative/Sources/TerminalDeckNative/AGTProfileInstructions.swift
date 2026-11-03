import SwiftUI

struct AGTProfileInstructions: View {
    @Bindable var model: AGOPTProfileModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(model.filePath.map(AGFRAMEStyle.shortPath) ?? "No saved agent file")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(model.filePath ?? "")
                Spacer(minLength: 8)
                Button("Show in Finder") { model.showFile() }.disabled(model.filePath == nil)
                Button("Open in my editor") { model.openFile() }.disabled(model.filePath == nil)
                Text(model.sourceSaving ? "Saving…" : model.sourceHasChanges ? "Unsaved changes" : "Saved")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save") { Task { await model.saveSource() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canWriteSource || !model.sourceHasChanges || model.sourceSaving || model.sourceChanged)
            }.controlSize(.small)
            if model.sourceChanged {
                AGOPTCard {
                    HStack {
                        Text("This file changed on disk.").font(.callout)
                        Spacer()
                        Button("Keep mine") {
                            model.sourceRevision = model.snapshot["source"]["revision"].string
                            model.sourceChanged = false
                        }
                        Button("Use the file") { Task { await model.useFileVersion() } }
                    }
                }
            }
            TextEditor(text: $model.sourceBody)
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(10).background(AGOPTStyle.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AGOPTStyle.hairline, lineWidth: 0.5))
                .frame(minHeight: 240, maxHeight: .infinity)
                .disabled(!model.canWriteSource)
                .accessibilityLabel("Agent file")
            // SETTINGS-TRUTH row 88: the box edits the text that reaches every brief only for an imported agent (its file
            // is the agent; this box is added to each task). For an agent made here, extra instructions set by an AI app
            // (extraTaskInstructions) are added to each brief too; they are named here, not edited through a box that
            // only repeated the agent's own file.
            if model.separateExtraInstructions && model.snapshot["source"]["imported"].bool != true {
                Text("It also has extra instructions an AI app set for every task. They are added to each task brief.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.separateExtraInstructions && model.snapshot["source"]["imported"].bool == true { AGOPTCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Extra instructions for every task").font(.headline)
                    TextEditor(text: $model.draft.instructions)
                        .font(.system(size: 12, design: .monospaced)).frame(height: 120)
                        .accessibilityLabel("Extra instructions for every task")
                        .onChange(of: model.draft.instructions) { _, _ in model.changed() }
                }
            } }
            if !model.canWriteSource, let reason = model.snapshot["source"]["writeReason"].string {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}
