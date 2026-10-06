import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The folder a session on a server starts in (`ServerFolderPicker.tsx`): the
/// chosen folder (or the server's default, or wherever the sign-in lands), and
/// Browse…, which lists that server's folders in a sheet — Home, Up, a typed
/// path, "Start here every time", and Use this folder.
///
/// Used by a server's page (Open a terminal) and by the New session dialog.
/// `path` nil means the server's default.
struct NativeServerFolderPicker: View {
    let serverId: String
    let serverName: String
    @Binding var path: String?
    @State private var fallback: String?
    @State private var browsing = false

    var body: some View {
        let line = ServerFolders.line(path: path, fallback: fallback)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(line.shown)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(line.shown)
                Spacer(minLength: 8)
                Button("Browse…") { browsing = true }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            Text(line.note).font(.callout).foregroundStyle(.secondary)
        }
        .task(id: serverId) { await readFallback() }
        .sheet(isPresented: $browsing) {
            NativeServerFolderSheet(serverId: serverId, serverName: serverName, start: path ?? fallback, fallback: $fallback) { chosen in
                path = chosen
                browsing = false
            } onClose: {
                browsing = false
            }
        }
    }

    /// The server's stored default folder, with the page's four-second deadline.
    private func readFallback() async {
        fallback = nil
        let id = serverId
        let work = Task { CodingAIJSON(try await EngineBridge.shared.invoke("servers:start-in", [id])) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(4))
            work.cancel()
        }
        if let raw = try? await work.value { fallback = ServerFolders.storedFolder(raw) }
        timer.cancel()
    }
}

/// "Folders on <server>": the folder window.
struct NativeServerFolderSheet: View {
    let serverId: String
    let serverName: String
    let start: String?
    @Binding var fallback: String?
    let onUse: (String?) -> Void
    let onClose: () -> Void
    @State private var here: ServerFolders.Folder?
    @State private var held: String?
    @State private var busy = false
    @State private var problem: String?
    @State private var typed = ""
    @State private var ticket = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Folders on \(serverName)").font(.headline)
                Spacer()
                Button("Home") { look("") }.disabled(busy)
                if let here, here.path != "/" {
                    Button("Up") { look(ServerFolders.childOf(here.path, "..")) }.disabled(busy)
                }
            }
            Text(held ?? ServerFolders.defaultFolder)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(held ?? ServerFolders.defaultFolder)

            let shown = ServerFolders.inNameOrder(here?.folders ?? [])
            List {
                if busy { Text("Reading \(serverName)…").foregroundStyle(.secondary) }
                if !busy && shown.isEmpty {
                    Text(here == nil ? "No folder list. Type the path below." : "No folders in here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { name in
                    Button {
                        look(ServerFolders.childOf(here?.path ?? "", name))
                    } label: {
                        Label(name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .frame(minHeight: 220)

            if let files = here?.files, files > 0 {
                Text(ServerFolders.filesNotShown(files)).font(.callout).foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField("Path on this server", text: $typed, prompt: Text("Or type a path, like /srv/app"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(goTo)
                Button("Go", action: goTo)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Toggle("Start here every time", isOn: Binding(
                    get: { held != nil && held == fallback },
                    set: { remember($0 ? held : nil) }))
                    .toggleStyle(.checkbox)
                    .disabled(held == nil)
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Use this folder") { onUse(held) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(held == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onAppear {
            held = start
            look(start ?? "")
        }
    }

    private func goTo() {
        let wanted = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        held = wanted
        look(wanted)
    }

    /// List one folder, with the page's twelve-second deadline; a late answer is dropped.
    private func look(_ where_: String) {
        ticket += 1
        let mine = ticket
        busy = true
        let id = serverId
        Task {
            let work = Task { CodingAIJSON(try await EngineBridge.shared.invoke("servers:folder", [id, where_])) }
            let timer = Task {
                try? await Task.sleep(for: .seconds(12))
                work.cancel()
            }
            do {
                let raw = try await work.value
                timer.cancel()
                guard mine == ticket else { return }
                busy = false
                guard raw["ok"].isTrue else {
                    problem = raw["sentence"].text ?? "That did not work, and this server did not say why."
                    return
                }
                guard let folder = ServerFolders.parse(raw) else {
                    problem = "That server answered with something we could not read."
                    return
                }
                problem = nil
                here = folder
                held = folder.path
            } catch {
                timer.cancel()
                guard mine == ticket else { return }
                busy = false
                problem = work.isCancelled ? CodingAIDeadline.overdue("listing that folder", seconds: 12)
                                           : CodingAIErrorText.from(error, fallback: "That server would not list that folder.")
            }
        }
    }

    /// "Start here every time": saved as the server's default.
    private func remember(_ chosen: String?) {
        fallback = chosen
        let id = serverId
        Task {
            do {
                _ = CodingAIJSON(try await EngineBridge.shared.invoke("servers:start-in:set", [id, chosen]))
            } catch {
                fallback = nil
            }
        }
    }
}
