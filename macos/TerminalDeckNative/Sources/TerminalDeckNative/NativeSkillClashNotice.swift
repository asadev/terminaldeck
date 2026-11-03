import SwiftUI
import TerminalDeckNativeCore

/// Shared by the Skills page and project guide; calls the same owner as skills_rename.
struct NativeSkillClashNotice: View {
    let folder: String
    let name: String
    var builtIn = false
    var renamed: (String, String) -> Void = { _, _ in }
    @State private var pending = false
    @State private var problem: String?
    private var note: String? {
        SkillCommandNames.note(name, targets: SkillCommandNames.targets(path: folder))
            ?? SkillCommandNames.note(URL(fileURLWithPath: folder).lastPathComponent, targets: SkillCommandNames.targets(path: folder))
    }
    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 8) {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if !builtIn {
                    Button(pending ? "Renaming…" : "Rename") {
                        pending = true; problem = nil
                        Task { @MainActor in
                            defer { pending = false }
                            do {
                                let value = try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("skills:rename", [["skill": folder]]))
                                guard value["ok"].bool == true, let newName = value["name"].string, let newFolder = value["folder"].string else {
                                    problem = value["message"].string ?? "The skill could not be renamed."; return
                                }
                                renamed(newName, newFolder)
                                await ROUTINESSkillsStore.shared.load()
                            } catch { problem = error.localizedDescription }
                        }
                    }.buttonStyle(.bordered).controlSize(.small).disabled(pending)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
