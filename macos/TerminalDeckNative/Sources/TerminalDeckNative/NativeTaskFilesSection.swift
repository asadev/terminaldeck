import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Files

/// #319: each attachment's picture is decoded once, by attachment id, not on every redraw (typing in the
/// title redrew and decoded every picture of the task).
@MainActor
enum TaskPictures {
    private static let cache: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 300; return cache }()
    static func image(id: String, _ dataURL: String) -> NSImage? {
        let key = "\(id)#\(dataURL.utf8.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = AttachmentsSection.image(dataURL) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct AttachmentsSection: View {
    let model: TaskDetailModel
    let rows: [TaskAttachment]
    @State private var lightbox: Int?
    @State private var search: TagSearch

    init(model: TaskDetailModel, rows: [TaskAttachment]) {
        self.model = model
        self.rows = rows
        _search = State(initialValue: TagSearch(area: "file", model: model))
    }

    private var photos: [(id: String, image: NSImage)] {
        rows.compactMap { r in
            guard CrmFiles.isImage(mime: r.mimeType, fileName: r.fileName), let url = r.previewUrl, let image = TaskPictures.image(id: r.id, url) else { return nil }
            return (r.id, image)
        }
    }

    static func image(_ dataURL: String) -> NSImage? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        if !rows.isEmpty || !model.pending.isEmpty || model.linking {
            VStack(alignment: .leading, spacing: 6) {
                TasksFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(rows) { r in chip(r) }
                    ForEach(model.pending) { p in
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(p.fileName).lineLimit(1)
                            Text("Uploading… \(fmtSize(p.sizeBytes))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.caption).padding(.horizontal, 6).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                        .opacity(0.6)
                        .help("Uploading \(p.fileName)")
                    }
                }
                .accessibilityLabel("Attachments")
                if model.linking { linkFromFiles }
            }
            .sheet(isPresented: Binding(get: { lightbox != nil }, set: { if !$0 { lightbox = nil } })) {
                PhotoLightbox(photos: photos.map(\.image), index: lightbox ?? 0) { lightbox = nil }
            }
        }
    }

    private func fmtSize(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(Int((Double(n) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }

    private func chip(_ r: TaskAttachment) -> some View {
        let image = CrmFiles.isImage(mime: r.mimeType, fileName: r.fileName) ? r.previewUrl.flatMap { TaskPictures.image(id: r.id, $0) } : nil
        let size = r.kind == "document" && r.documentId != nil ? "in Files" : r.sizeBytes.map { fmtSize(Int($0)) }
        return AttachmentChip(name: r.fileName, image: image, isImage: CrmFiles.isImage(mime: r.mimeType, fileName: r.fileName), size: size,
                              onOpen: {
                                  if image != nil, let i = photos.firstIndex(where: { $0.id == r.id }) { lightbox = i } else { model.openFile(r.id) }
                              },
                              onRemove: { model.detach(r) })
    }

    private var linkFromFiles: some View {
        let linked = Set(rows.compactMap(\.documentId))
        return VStack(spacing: 0) {
            HStack {
                SearchField(placeholder: "Search Files", text: $search.query, busy: search.busy) { model.linking = false }
                Button { model.linking = false } label: { Image(systemName: "xmark").font(.caption2).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).padding(.trailing, 8).accessibilityLabel("Close Files search")
            }
            Divider()
            SearchResults(search: search, none: "No document matches") { h in
                let already = linked.contains(h.id)
                Button { model.attachDocument(id: h.id, fileName: h.label) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.label).lineLimit(1)
                            if let s = h.secondary { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        if already { Text("Added").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(already).opacity(already ? 0.45 : 1)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
}

struct AttachmentChip: View {
    let name: String
    let image: NSImage?
    let isImage: Bool
    let size: String?
    let onOpen: () -> Void
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        Image(systemName: isImage ? "photo" : "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .windowBackgroundColor)))
                    }
                    Text(name).lineLimit(1)
                    if hovering, let size { Text(size).font(.caption2).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(image != nil ? "\(name) — click for the big view" : name)
            .accessibilityLabel("Open \(name)")
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
                    .accessibilityLabel("Remove attachment \"\(name)\"")
            }
        }
        .font(.caption)
        .padding(.leading, 4).padding(.trailing, 4)
        .frame(maxWidth: 256, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hovering ? 0.2 : 0.12)))
        .onHover { hovering = $0 }
    }
}

/// The photo viewer: the picture, n / N, ‹ › and ← →, × or Esc to close.
struct PhotoLightbox: View {
    let photos: [NSImage]
    @State var index: Int
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea().onTapGesture(perform: onClose)
            if photos.indices.contains(index) {
                Image(nsImage: photos[index]).resizable().scaledToFit().padding(40)
            } else {
                Text("Image unavailable").foregroundStyle(.white.opacity(0.7))
            }
            VStack {
                HStack {
                    Spacer()
                    if photos.count > 1 {
                        Text("\(index + 1) / \(photos.count)").font(.caption.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 4).background(Capsule().fill(.white.opacity(0.1)))
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 16)
            HStack {
                if photos.count > 1 { round("chevron.left", "Previous photo") { go(-1) } }
                Spacer()
                if photos.count > 1 { round("chevron.right", "Next photo") { go(1) } }
            }
            .padding(.horizontal, 12)
            VStack {
                HStack {
                    Spacer()
                    round("xmark", "Close photo viewer", action: onClose)
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onExitCommand(perform: onClose)
        .accessibilityLabel("Photo viewer")
    }

    private func go(_ step: Int) {
        guard !photos.isEmpty else { return }
        index = (index + step + photos.count) % photos.count
    }

    private func round(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(.white).frame(width: 48, height: 48)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// "Attach file": Upload from device, or Link from Files.
struct AttachFileRow: View {
    let model: TaskDetailModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("Attach file", systemImage: "paperclip").frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(ActionRowStyle())
        .help("Attach a file")
        .accessibilityLabel("Attach a file")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                menuRow("Upload from device", "arrow.up.doc") {
                    open = false
                    Task { _ = await model.chooseFromDevice() }
                }
                menuRow("Link from Files", "doc.text") {
                    open = false
                    model.reveal(.attachments)
                    model.linking = true
                }
            }
            .padding(.vertical, 4)
            .frame(width: 220)
        }
    }

    private func menuRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One of the action rows under the sections ("Add subtask", "Create checklist" …).
struct ActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionRowBody(configuration: configuration)
    }

    private struct ActionRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.callout)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.secondary.opacity(0.08) : .clear))
                .onHover { hovering = $0 }
        }
    }
}
