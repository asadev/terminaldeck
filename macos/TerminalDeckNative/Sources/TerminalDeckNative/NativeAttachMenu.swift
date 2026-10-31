import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// MARK: - The attach menu (`AttachMenu`)

struct NativeAttachMenu: View {
    let pathMode: Bool
    let disabled: Bool
    let startIn: String
    let onAdd: ([ChatPick]) -> Void
    let onNotice: (String) -> Void
    let onClose: () -> Void

    @State private var open = false
    @State private var busy: ChatAttachMenu.Surface?

    var body: some View {
        Button {
            if open { close() } else { open = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text(ChatAttachMenu.word(pathMode: pathMode))
            }
            .font(.footnote)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(ChatAttachMenu.label(pathMode: pathMode))
        .accessibilityLabel(ChatAttachMenu.label(pathMode: pathMode))
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ChatAttachMenu.items(pathMode: pathMode), id: \.surface) { item in
                    Button { browse(item.surface) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.symbol(item.surface))
                                .font(.system(size: 14))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                Text(busy == item.surface ? ChatAttachMenu.opening : item.hint)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy != nil)
                }
            }
            .padding(6)
            .frame(width: 336)
            .accessibilityLabel(ChatAttachMenu.title(pathMode: pathMode))
        }
    }

    static func symbol(_ surface: ChatAttachMenu.Surface) -> String {
        switch surface {
        case .file: return "doc"
        case .folder: return "folder"
        case .image: return "photo"
        }
    }

    private func close() {
        open = false
        onClose()
    }

    /// The Mac's own open panel, as the engine's dialog was: files (several), a folder,
    /// or images only, starting where the session can read.
    private func browse(_ surface: ChatAttachMenu.Surface) {
        busy = surface
        let panel = NSOpenPanel()
        let folder = surface == .folder
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = !folder
        panel.title = folder ? "Add a folder" : surface == .image ? "Add an image" : "Add files"
        panel.prompt = "Add"
        if surface == .image {
            panel.allowedContentTypes = ChatAttach.imageExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        if !startIn.isEmpty { panel.directoryURL = URL(fileURLWithPath: startIn, isDirectory: true) }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            busy = nil
            guard response == .OK else { return }
            let picks = panel.urls.map { url in
                ChatPick(path: url.path, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }
            guard !picks.isEmpty else { return }
            onAdd(picks)
            close()
        }
        open = false
        if let window = AppModel.shared.web.webView.window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }
}
