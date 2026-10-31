import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Offscreen pictures of the Context handoff canvas in its states (fixture data, no chat, no store).
@MainActor @Test
func L5HandoffFrames() throws {
    let now = Date()
    func topic(_ id: String, _ title: String) -> DeckMemoryTopic {
        DeckMemoryTopic(id: id, owner: .hoot, title: title, body: "", open: true, path: "hoot/topics/\(id).md",
                        labels: .init(owner: .hoot, project: nil, date: now, type: "topic"), updatedAt: now)
    }
    let text = "# Handoff: Brokers page\n\n**Where it stands:** the list and the invite flow work on the dev copy.\n\n## Decided\n- Staging first, never straight to live.\n- One blue button per screen.\n\n## Left to do\n1. Bulk import of brokers (CSV parser drafted).\n2. The empty state.\n\n## Proof\n`npm run typecheck` clean; invite link opens the right company.\n\n## Open questions\n- Which columns does the import need?"
    func model(_ phase: NativeHandoffModel.Phase) -> NativeHandoffModel {
        let made = NativeHandoffModel(owner: .hoot, fixture: true)
        made.isOpen = true
        made.topics = [topic("brokers-page", "Brokers page"), topic("billing", "Billing move")]
        made.topic = "brokers-page"
        made.phase = phase
        if phase == .ready {
            let doc = NativeHandoffDoc(id: "h2", topicID: "brokers-page", title: "Brokers page", markdown: text, createdAt: now, kept: true)
            made.doc = doc; made.text = text; made.note = "Saved with this topic"
            made.earlier = [doc, NativeHandoffDoc(id: "h1", topicID: "brokers-page", title: "Brokers page", markdown: text, createdAt: now.addingTimeInterval(-86400), kept: true)]
        }
        return made
    }
    for dark in [false, true] {
        try L5HandoffRender(NativeHandoffPanel(model: model(.writing("Hoot is writing the handoff…"))), dark: dark, name: "writing")
        try L5HandoffRender(NativeHandoffPanel(model: model(.ready)), dark: dark, name: "ready")
        try L5HandoffRender(NativeHandoffPanel(model: model(.failed("Hoot finished without writing a handoff."))), dark: dark, name: "failed")
    }
}

@MainActor
private func L5HandoffRender<V: View>(_ view: V, dark: Bool, name: String) throws {
    let size = CGSize(width: 460, height: 680)
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("design-2026-10-10/built.noindex")
    try data.write(to: folder.appendingPathComponent("L5-handoff-\(name)-\(dark ? "dark" : "light").png"))
}
