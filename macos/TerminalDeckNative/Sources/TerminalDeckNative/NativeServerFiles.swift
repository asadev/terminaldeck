import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// SRVFILES #120: the Files view on a server's page. Folders · Photos · Videos · Audio · Documents.
// Everything goes through servers:files:* (the server's own SSH sign-in, its allowed folders only).

struct NativeServerFileRow: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String, path: String, kind: String, type: String
    var size: Int64?, modified: Date?
    var group: String? = nil
    var measure: Double? = nil
    var isFolder: Bool { kind == "folder" }
    var folder: String { let p = (path as NSString).deletingLastPathComponent; return p.isEmpty ? "/" : p }
    var sizeSort: Int64 { size ?? -1 }
    var dateSort: Date { modified ?? .distantPast }

    init(name: String, path: String, kind: String, type: String, size: Int64? = nil, modified: Date? = nil, group: String? = nil, measure: Double? = nil) {
        self.name = name; self.path = path; self.kind = kind; self.type = type; self.size = size; self.modified = modified; self.group = group; self.measure = measure
    }
    init?(_ json: CodingAIJSON) {
        guard let name = json["name"].string, let path = json["path"].string else { return nil }
        self.init(name: name, path: path, kind: json["kind"].string ?? "file", type: json["type"].string ?? "other",
                  size: json["size"].number.map { Int64($0) }, modified: json["modified"].number.map { Date(timeIntervalSince1970: $0 / 1000) },
                  group: json["group"].string, measure: json["seconds"].number ?? json["pages"].number)
    }
    var kindWord: String {
        switch isFolder ? "folder" : kind == "link" ? "link" : type {
        case "folder": "Folder"; case "link": "Link"; case "photo": "Photo"; case "video": "Video"; case "audio": "Audio"
        case "document": "Document"; case "text": "Text"; case "code": "Code"; case "archive": "Archive"; default: "File"
        }
    }
    var symbol: String {
        switch isFolder ? "folder" : kind == "link" ? "link" : type {
        case "folder": "folder.fill"; case "link": "arrow.up.right.square"; case "photo": "photo"; case "video": "film"; case "audio": "waveform"
        case "document": "doc.richtext"; case "text": "doc.text"; case "code": "chevron.left.forwardslash.chevron.right"; case "archive": "archivebox"; default: "doc"
        }
    }
}

enum NativeServerFilesWords {
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }
    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded()); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func count(_ n: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
    static func noun(_ type: String, _ n: Int) -> String {
        let one = ["photo": "photo", "video": "video", "audio": "audio file", "document": "document"][type] ?? "file"
        return n == 1 ? one : one + "s"
    }
}

/// One RPC door for this view. A refusal comes back as `ok: false` + a plain sentence.
@MainActor enum NativeServerFilesAPI {
    struct Refused: LocalizedError { let sentence: String; var errorDescription: String? { sentence } }
    static func raw(_ channel: String, _ server: String, _ options: [String: Any] = [:]) async throws -> Any {
        let answer = try await EngineBridge.shared.invoke(channel, [server, options])
        let json = CodingAIJSON(answer)
        if json["ok"].bool == false { throw Refused(sentence: json["sentence"].string ?? "That did not work.") }
        return answer
    }
    static func call(_ channel: String, _ server: String, _ options: [String: Any] = [:]) async throws -> CodingAIJSON {
        CodingAIJSON(try await raw(channel, server, options))
    }
    static func message(_ error: Error) -> String {
        (error as? Refused)?.sentence ?? CodingAIErrorText.from(error, fallback: "That did not work.")
    }
}

@MainActor @Observable
final class NativeServerFilesModel {
    let serverID: String, serverName: String
    let live: Bool
    var path = ""
    var root = ""
    var roots: [String] = []
    var parent: String?
    var rows: [NativeServerFileRow] = []
    var total = 0
    var more = false
    var query = ""
    var sort = "name"
    var descending = false
    var lookOnly = true
    var loading = false
    var problem: String?
    var notice: String?
    var selection: NativeServerFileRow.ID?
    /// Renders only: previews without a server.
    var fixturePreviews: [String: NativeServerFilePreview.Fixture] = [:]
    private var history: [String] = []
    private var generation = 0

    init(serverID: String, serverName: String, live: Bool = true, fixture: (path: String, rows: [NativeServerFileRow], lookOnly: Bool)? = nil) {
        self.serverID = serverID; self.serverName = serverName; self.live = live
        if let fixture { path = fixture.path; root = fixture.path; roots = [fixture.path]; rows = fixture.rows; total = fixture.rows.count; lookOnly = fixture.lookOnly }
    }
    var selected: NativeServerFileRow? { rows.first { $0.id == selection } }
    var canGoBack: Bool { !history.isEmpty }

    /// Folder names from the allowed folder down to here, for the path bar.
    var crumbs: [(label: String, path: String)] {
        guard !root.isEmpty else { return [] }
        let home = roots.first ?? root
        var out = [(label: root == home ? "Home" : (root as NSString).lastPathComponent, path: root)]
        let rest = path.hasPrefix(root) ? String(path.dropFirst(root == "/" ? 1 : root.count)) : ""
        var at = root
        for part in rest.split(separator: "/") { at = at == "/" ? "/" + part : at + "/" + part; out.append((String(part), at)) }
        return out
    }

    func start() { if live, rows.isEmpty, !loading { open("", remember: false) } }
    func open(_ target: String, remember: Bool = true, select: String? = nil) {
        if remember, !path.isEmpty, target != path { history.append(path) }
        query = ""; load(target, select: select)
    }
    func back() { guard let last = history.popLast() else { return }; query = ""; load(last) }
    func reload(fresh: Bool = true) { load(path, fresh: fresh) }
    func searchChanged() {
        let mine = generation + 1; generation = mine
        Task { try? await Task.sleep(for: .milliseconds(250)); if generation == mine { load(path) } }
    }
    func setSort(_ key: String, descending: Bool) { sort = key; self.descending = descending; load(path) }

    private func options(_ target: String, offset: Int, fresh: Bool) -> [String: Any] {
        ["path": target, "query": query, "sort": sort, "descending": descending, "offset": offset, "limit": 200, "fresh": fresh]
    }
    private func load(_ target: String, fresh: Bool = false, select: String? = nil) {
        guard live else { return }
        generation += 1; let mine = generation
        loading = true; problem = nil
        Task {
            defer { if generation == mine { loading = false } }
            do {
                let page = try await NativeServerFilesAPI.call("servers:files:list", serverID, options(target, offset: 0, fresh: fresh))
                guard generation == mine else { return }
                take(page, append: false)
                if let select { selection = select }
                else if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
            } catch {
                guard generation == mine else { return }
                problem = NativeServerFilesAPI.message(error)
            }
        }
    }
    func loadMore() {
        guard live, more, !loading else { return }
        loading = true; let mine = generation
        Task {
            // #481: a Reload started meanwhile owns the spinner now.
            defer { if generation == mine { loading = false } }
            if let page = try? await NativeServerFilesAPI.call("servers:files:list", serverID, options(path, offset: rows.count, fresh: false)), generation == mine {
                take(page, append: true)
            }
        }
    }
    private func take(_ page: CodingAIJSON, append: Bool) {
        path = page["path"].string ?? path; root = page["root"].string ?? root
        roots = (page["roots"].array ?? []).compactMap(\.string); parent = page["parent"].string
        let fresh = (page["entries"].array ?? []).compactMap(NativeServerFileRow.init)
        rows = append ? rows + fresh : fresh
        total = Int(page["total"].number ?? Double(rows.count)); more = page["more"].isTrue
        lookOnly = page["lookOnly"].bool ?? true
    }

    // MARK: actions

    func download(_ row: NativeServerFileRow) {
        guard live, !row.isFolder else { return }
        notice = "Downloading \(row.name)…"
        Task {
            do {
                let saved = try await NativeServerFilesAPI.call("servers:files:download", serverID, ["path": row.path])
                notice = "Saved to Downloads as \(saved["name"].string ?? row.name)."
            } catch { notice = NativeServerFilesAPI.message(error) }
        }
    }
    func copyPath(_ row: NativeServerFileRow) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.path, forType: .string)
        notice = "Copied the path."
    }
    func rename(_ row: NativeServerFileRow, to name: String) {
        guard live, !lookOnly else { return }
        Task {
            do {
                let moved = try await NativeServerFilesAPI.call("servers:files:rename", serverID, ["path": row.path, "name": name])
                notice = "Renamed to \(name)."; load(path, fresh: true, select: moved["path"].string)
            } catch { notice = NativeServerFilesAPI.message(error) }
        }
    }
    func delete(_ row: NativeServerFileRow) {
        guard live, !lookOnly else { return }
        Task {
            do { _ = try await NativeServerFilesAPI.call("servers:files:delete", serverID, ["path": row.path]); notice = "Deleted \(row.name)."; selection = nil; load(path, fresh: true) }
            catch { notice = NativeServerFilesAPI.message(error) }
        }
    }
    func upload(_ files: [URL]) {
        guard live, !lookOnly, !files.isEmpty else { return }
        notice = files.count == 1 ? "Adding \(files[0].lastPathComponent)…" : "Adding \(files.count) files…"
        Task {
            var last: String?
            for file in files {
                do { last = try await NativeServerFilesAPI.call("servers:files:upload", serverID, ["local": file.path, "folder": path])["path"].string }
                catch { notice = NativeServerFilesAPI.message(error); load(path, fresh: true); return }
            }
            notice = files.count == 1 ? "Added \(files[0].lastPathComponent)." : "Added \(files.count) files."
            load(path, fresh: true, select: last)
        }
    }
}

/// The Files view: its own switch, then the folder browser or one gallery.
struct NativeServerFilesView: View {
    @State var files: NativeServerFilesModel
    @State var gallery: NativeServerGalleryModel
    @State private var view: String
    private let fixtureImages: [String: NSImage]

    init(serverID: String, serverName: String, live: Bool = true, initialView: String = "Folders",
         filesFixture: NativeServerFilesModel? = nil, galleryFixture: NativeServerGalleryModel? = nil, fixtureImages: [String: NSImage] = [:]) {
        self.fixtureImages = fixtureImages
        _files = State(initialValue: filesFixture ?? NativeServerFilesModel(serverID: serverID, serverName: serverName, live: live))
        _gallery = State(initialValue: galleryFixture ?? NativeServerGalleryModel(serverID: serverID, live: live))
        _view = State(initialValue: initialView)
    }
    static let views = [("Folders", ""), ("Photos", "photo"), ("Videos", "video"), ("Audio", "audio"), ("Documents", "document")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Files view", selection: $view) {
                    ForEach(Self.views, id: \.0) { item in
                        if let n = gallery.counts[item.1], n.count > 0 { Text("\(item.0) \(NativeServerFilesWords.count(n.count))").tag(item.0) }
                        else { Text(item.0).tag(item.0) }
                    }
                }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl().fixedSize()
                Spacer()
                Label(files.lookOnly ? "Look only" : "Look and change", systemImage: files.lookOnly ? "eye" : "pencil")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(files.lookOnly ? "Browse, preview and download. Nothing on this server can be changed here."
                          : "Rename, delete and add files too. Each change asks you first.")
            }
            Group {
                if view == "Folders" {
                    NativeServerFolderBrowser(model: files)
                } else {
                    NativeServerGalleryView(model: gallery, type: Self.views.first { $0.0 == view }?.1 ?? "photo", showInFolder: { row in
                        view = "Folders"; files.open(row.folder, select: row.path)
                    }, fixtureImages: fixtureImages)
                }
            }
            .frame(height: 620)
            .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DeckTokens.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if let notice = files.notice ?? gallery.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onAppear { files.start(); gallery.start() }
    }
}

struct NativeServerFolderBrowser: View {
    @Bindable var model: NativeServerFilesModel
    @State private var order = [KeyPathComparator(\NativeServerFileRow.name)]
    @State private var renaming: NativeServerFileRow?
    @State private var newName = ""
    @State private var deleting: NativeServerFileRow?
    @State private var picking = false
    @State private var uploads: [URL] = []

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
                Divider()
                footer
            }
            if let row = model.selected {
                Divider()
                NativeServerFilePreview(serverID: model.serverID, row: row, live: model.live, lookOnly: model.lookOnly,
                    onOpen: { model.open(row.path) }, onDownload: { model.download(row) }, onCopyPath: { model.copyPath(row) }, onShowInFolder: nil,
                    fixture: model.fixturePreviews[row.path])
                    .frame(width: 320).id(row.id)
            }
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $newName)
            Button("Rename") { if let row = renaming { model.rename(row, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("This renames it on \(model.serverName).") }
        .alert("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let row = deleting { model.delete(row) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text(deleting?.isFolder == true ? "Only an empty folder can be deleted. This can't be undone." : "It is removed from \(model.serverName). This can't be undone.") }
        .alert("Add \(uploads.count == 1 ? uploads[0].lastPathComponent : "\(uploads.count) files") to \(model.crumbs.last?.label ?? "this folder")?",
               isPresented: Binding(get: { !uploads.isEmpty }, set: { if !$0 { uploads = [] } })) {
            Button("Add") { model.upload(uploads); uploads = [] }
            Button("Cancel", role: .cancel) { uploads = [] }
        } message: { Text("They are copied onto \(model.serverName). A file with the same name is kept; the new one gets a number.") }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { uploads = urls }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.back() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(.rect) }
                .buttonStyle(.borderless).disabled(!model.canGoBack).help("Back").accessibilityLabel("Back")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                        Button { if crumb.path != model.path { model.open(crumb.path) } } label: {
                            HStack(spacing: 4) {
                                if index == 0 { Image(systemName: "house").font(.system(size: 11)) }
                                Text(crumb.label).lineLimit(1)
                            }.padding(.horizontal, 6).frame(height: 24).contentShape(.rect)
                        }.buttonStyle(DeckRowStyle()).foregroundStyle(index == model.crumbs.count - 1 ? Color.primary : Color.secondary)
                            .help(crumb.path)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Search this folder", text: $model.query).textFieldStyle(.plain).frame(width: 150)
                    .onChange(of: model.query) { _, _ in model.searchChanged() }
            }.padding(.horizontal, 8).frame(height: 26).background(DeckTokens.selection, in: RoundedRectangle(cornerRadius: 7))
            Menu {
                Picker("Sort by", selection: Binding(get: { model.sort }, set: { model.setSort($0, descending: model.descending) })) {
                    Text("Name").tag("name"); Text("Size").tag("size"); Text("Date modified").tag("date"); Text("Kind").tag("kind")
                }.pickerStyle(.inline)
                Divider()
                Toggle("Descending", isOn: Binding(get: { model.descending }, set: { model.setSort(model.sort, descending: $0) }))
            } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Sort").accessibilityLabel("Sort")
            if !model.lookOnly {
                Button { picking = true } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(.rect) }
                    .buttonStyle(.borderless).help("Add files to this folder").accessibilityLabel("Add files to this folder")
            }
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).contentShape(.rect) }
                .buttonStyle(.borderless).help("Read this folder again").accessibilityLabel("Read this folder again")
        }.padding(.horizontal, 10).frame(height: 44)
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem, model.rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.orange)
                Text(problem).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                DeckRetryButton("Try Again", autoRetry: true) { model.reload() } // autoRetry: re-reads the folder listing
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty && !model.loading {
            VStack(spacing: 8) {
                Image(systemName: model.query.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "This folder is empty" : "Nothing here matches “\(model.query)”").font(.system(size: 15, weight: .semibold))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.rows, selection: $model.selection, sortOrder: $order) {
                TableColumn("Name", value: \NativeServerFileRow.name) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.symbol).foregroundStyle(.secondary).frame(width: 18)
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                    }
                    .onAppear { if row.id == model.rows.last?.id { model.loadMore() } }
                }.width(min: 200, ideal: 340)
                TableColumn("Size", value: \NativeServerFileRow.sizeSort) { row in
                    Text(row.isFolder ? "—" : NativeServerFilesWords.size(row.size)).monospacedDigit().foregroundStyle(.secondary)
                }.width(min: 70, ideal: 90)
                TableColumn("Date modified", value: \NativeServerFileRow.dateSort) { row in
                    Text(NativeServerFilesWords.date(row.modified)).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 120, ideal: 170)
                TableColumn("Kind", value: \NativeServerFileRow.type) { row in Text(row.kindWord).foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: NativeServerFileRow.ID.self) { ids in
                if let row = model.rows.first(where: { ids.contains($0.id) }) { rowMenu(row) }
            } primaryAction: { ids in
                if let row = model.rows.first(where: { ids.contains($0.id) }), row.isFolder || row.kind == "link" { model.open(row.path) }
            }
            .onChange(of: order) { _, next in
                guard let first = next.first else { return }
                let key = first.keyPath == \NativeServerFileRow.sizeSort ? "size" : first.keyPath == \NativeServerFileRow.dateSort ? "date"
                    : first.keyPath == \NativeServerFileRow.type ? "kind" : "name"
                model.setSort(key, descending: first.order == .reverse)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ row: NativeServerFileRow) -> some View {
        if row.isFolder || row.kind == "link" { Button("Open") { model.open(row.path) } }
        if !row.isFolder { Button("Download") { model.download(row) } }
        Button("Copy path") { model.copyPath(row) }
        if !model.lookOnly {
            Divider()
            Button("Rename…") { newName = row.name; renaming = row }
            Button("Delete…", role: .destructive) { deleting = row }
        }
    }

    private var footer: some View {
        HStack {
            if model.loading { ProgressView().controlSize(.small) }
            Text(model.rows.count < model.total ? "\(NativeServerFilesWords.count(model.rows.count)) / \(NativeServerFilesWords.count(model.total)) items" : "\(NativeServerFilesWords.count(model.total)) \(model.total == 1 ? "item" : "items")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if model.more { Button("Show more") { model.loadMore() }.buttonStyle(.borderless).font(.caption) }
            Spacer()
            Text(model.path.isEmpty ? "" : model.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                .help(model.path)
        }.padding(.horizontal, 12).frame(height: 28)
    }
}
