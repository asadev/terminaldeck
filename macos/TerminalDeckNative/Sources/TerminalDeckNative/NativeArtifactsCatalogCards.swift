import AppKit
import QuickLookThumbnailing
import SwiftUI
import TerminalDeckNativeCore

struct NativeArtifactsCatalogCard: View {
    let row: NativeArtifactsCatalogModel.Row
    let model: NativeArtifactsCatalogModel
    @State private var thumbnail: NSImage?
    @State private var hovered = false
    var body: some View {
        Button { model.showPreview(row) } label: {
            VStack(alignment: .leading, spacing: 0) {
                preview.frame(height: 132).frame(maxWidth: .infinity).clipped()
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.artifact.name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle().fill(projectColor).frame(width: 8, height: 8)
                        Text(model.subtitle(row))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(Date(timeIntervalSince1970: row.artifact.lastAt / 1000), format: .dateTime.hour().minute())
                            .monospacedDigit().lineLimit(1)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? NativeCatalogTokens.hover : NativeCatalogTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.selected?.id == row.id ? Color.accentColor : NativeCatalogTokens.hairline, lineWidth: model.selected?.id == row.id ? 2 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(NativeCatalogRowStyle())
            .onHover { hovered = $0 }
            .focusable()
            .onKeyPress(.space) { model.showPreview(row); return .handled }
            .help(model.pathHelp(row))
            .accessibilityLabel("Preview \(row.artifact.name), from \(model.sourceName(row))")
            .contextMenu { NativeArtifactsCatalogActions(row: row, model: model) }
            .task(id: row.id + String(row.artifact.onDisk?.modifiedAt ?? 0)) {
                if model.isFixture { thumbnail = model.fixtureThumbnails[row.id]; return }
                guard let url = row.url, let disk = row.artifact.onDisk else { thumbnail = nil; return }
                if isPage {
                    // A page gets a real picture of itself, made once per version; its title holds the card meanwhile.
                    thumbnail = NativeArtifactsPageThumbnails.shared.held(url, modifiedAt: disk.modifiedAt)
                    model.preview(row)
                    if thumbnail == nil { thumbnail = await NativeArtifactsPageThumbnails.shared.picture(for: url, modifiedAt: disk.modifiedAt) }
                    return
                }
                guard [.pictures, .videos].contains(NativeArtifactsCatalogModel.Kind.of(row.artifact.relPath)) || ArtifactRules.extensionOf(row.artifact.relPath) == "pdf" else { return }
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 480, height: 264), scale: 2, representationTypes: .thumbnail)
                if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail = result.nsImage }
            }
    }
    @ViewBuilder private var preview: some View {
        if let image = model.fixtureThumbnails[row.id] ?? thumbnail {
            if isPage {
                // The top of the page, filling the card from its top edge.
                Color.clear.overlay(alignment: .top) { Image(nsImage: image).resizable().scaledToFill() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().background(NativeCatalogTokens.page)
            } else {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).background(NativeCatalogTokens.page)
            }
        } else {
            ZStack {
                NativeCatalogTokens.page
                VStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    // A page waiting for its picture (or one that cannot be drawn) says what it is called.
                    if isPage, row.artifact.onDisk != nil, let title = model.titles[row.id], !title.isEmpty {
                        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 14)
                    }
                }
                if row.artifact.onDisk == nil {
                    Text("File no longer on disk").font(.caption).foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10)
                }
            }
        }
    }
    private var isPage: Bool { ArtifactRules.kindOf(row.artifact.relPath) == "Web page" }
    private var symbol: String {
        switch NativeArtifactsCatalogModel.Kind.of(row.artifact.relPath) {
        case .pictures: "photo"
        case .videos: "play.rectangle"
        default: isPage ? "globe" : "doc.richtext"
        }
    }
    private var projectColor: Color {
        NativeCatalogProjectColour.value(NativePROJLabels.shared.projects.first { $0.id == row.projectID }?.colour ?? "graphite")
    }
}

struct NativeArtifactsCatalogActions: View {
    let row: NativeArtifactsCatalogModel.Row
    let model: NativeArtifactsCatalogModel
    var body: some View {
        Button("Open in chat") { model.openSource(row) }
        Button("Show in Finder") { model.reveal(row) }.disabled(row.artifact.onDisk == nil)
        Button("Copy") { model.copy(row) }.disabled(row.artifact.onDisk == nil)
        Menu("Send to…") {
            Button("Hoot") { model.send(row, to: "hoot") }
            ForEach(model.sessions, id: \.id) { session in
                Button(session.title) { model.send(row, to: session.id) }
            }
        }.disabled(row.artifact.onDisk == nil || model.pendingAction != nil)
        Divider()
        Button("Delete from list", role: .destructive) { model.requestDelete(row) }.disabled(model.pendingAction != nil)
    }
}

struct NativeArtifactsCatalogPreview: View {
    let row: NativeArtifactsCatalogModel.Row
    let model: NativeArtifactsCatalogModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.artifact.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(model.detailLine(row))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(model.pathHelp(row))
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).frame(width: 28, height: 28).help("Close preview").accessibilityLabel("Close preview")
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            Group {
                if model.isFixture {
                    if let image = model.fixtureThumbnails[row.id] {
                        Image(nsImage: image).resizable().scaledToFit().padding(16)
                    } else if let text = model.texts[row.id] {
                        ScrollView { Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                    } else {
                        ContentUnavailableView("No fixture preview", systemImage: "doc.richtext")
                    }
                } else if row.artifact.onDisk != nil, let url = row.url {
                    ArtifactsQuickLook(url: url, revision: row.artifact.onDisk?.modifiedAt ?? 0)
                } else {
                    ContentUnavailableView("File no longer on disk", systemImage: "doc.richtext", description: Text("Its source is still in the chat."))
                }
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Open in chat") { model.openSource(row) }.buttonStyle(.borderless)
                Button("Show in Finder") { model.reveal(row) }.buttonStyle(.borderless).disabled(row.artifact.onDisk == nil)
                Spacer()
                Menu { NativeArtifactsCatalogActions(row: row, model: model) } label: { Label("More", systemImage: "ellipsis") }
                    .menuIndicator(.hidden).help("Artifact actions")
            }.padding(16)
        }.frame(width: 760, height: 560).background(NativeCatalogTokens.card)
    }
}
