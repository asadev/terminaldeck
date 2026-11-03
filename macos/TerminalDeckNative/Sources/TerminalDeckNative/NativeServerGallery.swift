import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// SRVFILES #120 galleries: every photo, video, audio file or document in the server's
// allowed folders in one place. Scanned on request (read-only), cached, refreshed by a button.

@MainActor @Observable
final class NativeServerGalleryModel {
    let serverID: String
    let live: Bool
    var type = "photo"
    var rows: [NativeServerFileRow] = []
    var total = 0
    var bytes: Int64 = 0
    var more = false
    var counts: [String: (count: Int, bytes: Int64)] = [:]
    var scanned = false
    var scanning = false
    var complete = true
    var scannedAt: Date?
    var progress: (found: Int, bytes: Int64)?
    var sort = "date"
    var descending = true
    var group = "none"
    var query = ""
    var selection: NativeServerFileRow.ID?
    var loading = false
    var problem: String?
    var notice: String?
    @ObservationIgnored private var listener: EngineSubscription?
    @ObservationIgnored private var generation = 0

    init(serverID: String, live: Bool = true) { self.serverID = serverID; self.live = live }
    /// Renders only.
    init(fixture serverID: String, type: String, rows: [NativeServerFileRow], counts: [String: (Int, Int64)], scannedAt: Date?, group: String = "none") {
        self.serverID = serverID; live = false; self.type = type; self.rows = rows; total = rows.count
        bytes = rows.reduce(0) { $0 + ($1.size ?? 0) }; self.counts = counts.mapValues { (count: $0.0, bytes: $0.1) }
        scanned = scannedAt != nil; self.scannedAt = scannedAt; self.group = group
    }
    var selected: NativeServerFileRow? { rows.first { $0.id == selection } }

    func start() {
        guard live, listener == nil else { return }
        let id = serverID
        listener = EngineBridge.shared.on("servers:files:scan") { [weak self] args in
            let event = CodingAIJSON(args.first)
            guard event["serverId"].string == id else { return }
            Task { @MainActor in
                // #509: a word that arrives after the scan finished does not bring its count back.
                guard let self, self.scanning, event["done"].bool != true else { return }
                self.progress = (Int(event["found"].number ?? 0), Int64(event["bytes"].number ?? 0))
            }
        }
        load()
    }
    func show(_ type: String) { guard type != self.type || rows.isEmpty else { return }; self.type = type; selection = nil; load() }
    func reloadSoon() {
        let mine = generation + 1; generation = mine
        Task { try? await Task.sleep(for: .milliseconds(250)); if generation == mine { load() } }
    }
    private func options(offset: Int) -> [String: Any] {
        ["type": type, "query": query, "sort": sort, "descending": descending, "group": group, "offset": offset, "limit": 300]
    }
    func load() {
        guard live else { return }
        generation += 1; let mine = generation
        loading = true; problem = nil
        Task {
            defer { if generation == mine { loading = false } }
            do {
                let page = try await NativeServerFilesAPI.call("servers:files:gallery", serverID, options(offset: 0))
                guard generation == mine else { return }
                take(page, append: false)
            } catch { if generation == mine { problem = NativeServerFilesAPI.message(error) } }
        }
    }
    func loadMore() {
        guard live, more, !loading else { return }
        loading = true; let mine = generation
        Task {
            // #481: a reload started meanwhile owns the spinner now.
            defer { if generation == mine { loading = false } }
            if let page = try? await NativeServerFilesAPI.call("servers:files:gallery", serverID, options(offset: rows.count)), generation == mine { take(page, append: true) }
        }
    }
    private func take(_ page: CodingAIJSON, append: Bool) {
        let fresh = (page["items"].array ?? []).compactMap(NativeServerFileRow.init)
        rows = append ? rows + fresh : fresh
        total = Int(page["total"].number ?? 0); bytes = Int64(page["bytes"].number ?? 0); more = page["more"].isTrue
        scanned = page["scanned"].isTrue; scanning = page["scanning"].isTrue; complete = page["complete"].bool ?? true
        scannedAt = page["scannedAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) }
        var next: [String: (count: Int, bytes: Int64)] = [:]
        for (key, value) in page["counts"].object ?? [:] { next[key] = (Int(value["count"].number ?? 0), Int64(value["bytes"].number ?? 0)) }
        counts = next
    }
    func scan() {
        guard live, !scanning else { return }
        scanning = true; progress = (0, 0); problem = nil
        Task {
            defer { scanning = false; progress = nil }
            do { _ = try await NativeServerFilesAPI.call("servers:files:gallery:scan", serverID); load() }
            catch { problem = NativeServerFilesAPI.message(error) }
        }
    }
    func download(_ row: NativeServerFileRow) {
        guard live else { return }
        notice = "Downloading \(row.name)…"
        Task {
            do { notice = "Saved to Downloads as \(try await NativeServerFilesAPI.call("servers:files:download", serverID, ["path": row.path])["name"].string ?? row.name)." }
            catch { notice = NativeServerFilesAPI.message(error) }
        }
    }
}

/// The server's SSH sign-in allows only a few channels at once, so thumbnail and measure loads share these slots.
/// #483: a finished load hands its slot straight to the next one waiting, so a newcomer in between cannot take one more.
@MainActor final class NativeServerThumbSlots {
    let limit: Int
    private(set) var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiting.count }
    init(limit: Int = 4) { self.limit = limit }
    func take() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func give() { if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() } }
}

/// Small thumbnail loads, four at a time, cached on disk by the backend.
@MainActor final class NativeServerThumbs {
    static let shared = NativeServerThumbs()
    /// #483: a thumbnail that failed is tried again when its tile shows after this long, not only after a restart.
    static let retryAfter: TimeInterval = 60
    private var memory: [String: NSImage] = [:]
    private var missing: [String: Date] = [:]
    private let slots = NativeServerThumbSlots()
    func cached(_ key: String) -> NSImage? { memory[key] }
    private var measured: [String: Double] = [:]
    func measure(server: String, path: String) async -> Double? {
        let key = server + "|" + path
        if let hit = measured[key] { return hit }
        await slots.take(); defer { slots.give() }
        guard !Task.isCancelled, let value = try? await NativeServerFilesAPI.call("servers:files:measure", server, ["path": path])["value"].number else { return nil }
        measured[key] = value; return value
    }
    func image(server: String, path: String) async -> NSImage? {
        let key = server + "|" + path
        if let hit = memory[key] { return hit }
        if let failed = missing[key], Date().timeIntervalSince(failed) < Self.retryAfter { return nil }
        await slots.take(); defer { slots.give() }
        // A tile scrolled away before its turn is not a failure.
        guard !Task.isCancelled else { return nil }
        guard let local = try? await NativeServerFilesAPI.call("servers:files:thumb", server, ["path": path])["local"].string,
              let image = NSImage(contentsOfFile: local) else { missing[key] = Date(); return nil }
        missing[key] = nil
        if memory.count > 600 { memory.removeAll() }
        memory[key] = image
        return image
    }
}

struct NativeServerGalleryView: View {
    @Bindable var model: NativeServerGalleryModel
    let type: String
    let showInFolder: (NativeServerFileRow) -> Void
    var fixtureImages: [String: NSImage] = [:]

    private var noun: String { NativeServerFilesWords.noun(type, 2) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let row = model.selected {
                Divider()
                NativeServerFilePreview(serverID: model.serverID, row: row, live: model.live, lookOnly: true, onOpen: nil,
                    onDownload: { model.download(row) },
                    onCopyPath: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.path, forType: .string); model.notice = "Copied the path." },
                    onShowInFolder: { showInFolder(row) },
                    fixture: fixtureImages[row.path].map { .image($0) })
                    .frame(width: 320).id(row.id)
            }
        }
        .onAppear { model.show(type) }
        .onChange(of: type) { _, next in model.show(next) }
    }

    private var status: String {
        if model.scanning {
            let p = model.progress ?? (0, 0)
            return p.found == 0 ? "Searching the allowed folders…" : "Found \(NativeServerFilesWords.count(p.found)) files so far · \(NativeServerFilesWords.size(p.bytes))"
        }
        guard model.scanned else { return "Not searched yet" }
        var line = "Found \(NativeServerFilesWords.count(model.total)) \(NativeServerFilesWords.noun(type, model.total)) · \(NativeServerFilesWords.size(model.bytes))"
        if let at = model.scannedAt {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
            line += " · searched \(f.localizedString(for: at, relativeTo: Date()))"
        }
        if !model.complete { line += " · stopped at 100,000 files" }
        return line
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.scanning { ProgressView().controlSize(.small) }
            Text(status).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Search \(noun)", text: $model.query).textFieldStyle(.plain).frame(width: 130)
                    .onChange(of: model.query) { _, _ in model.reloadSoon() }
            }.padding(.horizontal, 8).frame(height: 26).background(DeckTokens.selection, in: RoundedRectangle(cornerRadius: 7))
            Menu {
                Picker("Sort by", selection: Binding(get: { model.sort }, set: { model.sort = $0; model.descending = $0 != "name"; model.load() })) {
                    Text("Date").tag("date"); Text("Size").tag("size"); Text("Name").tag("name")
                }.pickerStyle(.inline)
                Picker("Group by", selection: Binding(get: { model.group }, set: { model.group = $0; model.load() })) {
                    Text("No groups").tag("none"); Text("Folder").tag("folder"); Text("Month").tag("month")
                }.pickerStyle(.inline)
            } label: { Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Sort and group").accessibilityLabel("Sort and group")
            Button { model.scan() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).contentShape(.rect) }
                .buttonStyle(.borderless).disabled(model.scanning || !model.live && !model.scanned)
                .help("Search the allowed folders again").accessibilityLabel("Search the allowed folders again")
        }.padding(.horizontal, 12).frame(height: 44)
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem, model.rows.isEmpty {
            empty(symbol: "exclamationmark.triangle", title: "Couldn’t search this server", line: problem, button: "Try Again", warn: true) { model.scan() }
        } else if !model.scanned && !model.scanning {
            empty(symbol: symbol, title: "Find every \(NativeServerFilesWords.noun(type, 1)) on this server",
                  line: BackendServersActions.searchOnlyReads, button: "Search folders") { model.scan() }
        } else if model.rows.isEmpty && model.scanning {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty {
            empty(symbol: symbol, title: model.query.isEmpty ? "No \(noun) found" : "Nothing matches “\(model.query)”",
                  line: model.query.isEmpty ? "None in the folders this server may open." : "Try another word.", button: nil) {}
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.label) { section in
                        Section {
                            if type == "photo" || type == "video" { grid(section.rows) } else { list(section.rows) }
                        } header: {
                            if !section.label.isEmpty {
                                Text(section.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6).background(DeckTokens.card)
                            }
                        }
                    }
                    if model.more {
                        Button("Show more") { model.loadMore() }.buttonStyle(.borderless).padding(14)
                            .onAppear { model.loadMore() }
                    }
                }.padding(.bottom, 10)
            }
        }
    }

    private var symbol: String { ["photo": "photo.on.rectangle", "video": "film.stack", "audio": "waveform", "document": "doc.richtext"][type] ?? "doc" }

    private func empty(symbol: String, title: String, line: String, button: String?, warn: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(warn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(line).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let button {
                // "Try Again" reads again by itself first (DeckReconnect); any other button is the person's.
                Group {
                    if DeckRetryRules.isRetryLabel(button) { DeckRetryButton(button, action: action) } else { Button(button, action: action) }
                }.padding(.top, 4).disabled(!model.live)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 40)
    }

    private struct GallerySection { let label: String; let rows: [NativeServerFileRow] }
    private var sections: [GallerySection] {
        guard model.group != "none" else { return [.init(label: "", rows: model.rows)] }
        var out: [GallerySection] = []
        for row in model.rows {
            let label = monthLabel(row.group ?? "")
            if out.last?.label == label { out[out.count - 1] = .init(label: label, rows: out[out.count - 1].rows + [row]) }
            else { out.append(.init(label: label, rows: [row])) }
        }
        return out
    }
    private func monthLabel(_ raw: String) -> String {
        guard model.group == "month" else { return raw.isEmpty ? "—" : raw }
        let parse = DateFormatter(); parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "yyyy-MM"
        guard let date = parse.date(from: raw) else { return raw.isEmpty ? "No date" : raw }
        let show = DateFormatter(); show.setLocalizedDateFormatFromTemplate("MMMM yyyy"); return show.string(from: date)
    }

    private func grid(_ rows: [NativeServerFileRow]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 10)], spacing: 10) {
            ForEach(rows) { row in
                Button { model.selection = row.id } label: {
                    NativeServerThumbTile(serverID: model.serverID, row: row, live: model.live, fixture: fixtureImages[row.path],
                                          selected: model.selection == row.id)
                }.buttonStyle(.plain)
                .contextMenu { menu(row) }
                .accessibilityLabel(row.name)
            }
        }.padding(.horizontal, 12).padding(.top, 10)
    }

    private func list(_ rows: [NativeServerFileRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                Button { model.selection = row.id } label: {
                    NativeServerGalleryRow(serverID: model.serverID, row: row, live: model.live)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(.rect)
                        .background(model.selection == row.id ? DeckTokens.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(DeckRowStyle())
                .contextMenu { menu(row) }
            }
        }.padding(.horizontal, 8).padding(.top, 6)
    }

    @ViewBuilder private func menu(_ row: NativeServerFileRow) -> some View {
        Button("Preview") { model.selection = row.id }
        Button("Show in folder") { showInFolder(row) }
        Button("Download") { model.download(row) }
        Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.path, forType: .string) }
    }
}

struct NativeServerThumbTile: View {
    let serverID: String
    let row: NativeServerFileRow
    let live: Bool
    var fixture: NSImage?
    let selected: Bool
    @State private var image: NSImage?
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(DeckTokens.selection)
                if let image = image ?? fixture {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
                } else {
                    Image(systemName: row.type == "video" ? "film" : "photo").font(.system(size: 22)).foregroundStyle(.tertiary)
                        .opacity(tried || !live ? 1 : 0.5)
                }
                if row.type == "video" {
                    Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white).padding(7)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.primary.opacity(0.55) : DeckTokens.hairline, lineWidth: selected ? 2 : 1))
            Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Text([NativeServerFilesWords.size(row.size), row.measure.map(NativeServerFilesWords.duration)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        .contentShape(.rect)
        .help(row.path)
        .task(id: row.id) {
            guard live, image == nil else { return }
            image = NativeServerThumbs.shared.cached(serverID + "|" + row.path)
            if image == nil { image = await NativeServerThumbs.shared.image(server: serverID, path: row.path) }
            tried = true
        }
    }
}

struct NativeServerGalleryRow: View {
    let serverID: String
    let row: NativeServerFileRow
    let live: Bool
    @State private var measure: Double?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol).foregroundStyle(.secondary).frame(width: 28, height: 28)
                .background(DeckTokens.selection, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(row.folder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(lengthText).foregroundStyle(.secondary).monospacedDigit().frame(width: 74, alignment: .trailing)
            Text(NativeServerFilesWords.size(row.size)).foregroundStyle(.secondary).monospacedDigit().frame(width: 74, alignment: .trailing)
            Text(NativeServerFilesWords.date(row.modified)).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .trailing)
        }.padding(.horizontal, 8).padding(.vertical, 6)
        .help(row.path)
        .task(id: row.id) {
            guard live, row.measure == nil, measure == nil else { return }
            measure = await NativeServerThumbs.shared.measure(server: serverID, path: row.path)
        }
    }
    private var lengthText: String {
        guard let value = measure ?? row.measure else { return "—" }
        return row.type == "document" ? "\(Int(value)) \(Int(value) == 1 ? "page" : "pages")" : NativeServerFilesWords.duration(value)
    }
}
