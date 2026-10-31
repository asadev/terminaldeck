import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Offscreen pictures of the Memory area and the Templates screen (fixture data, no store, no window).
@MainActor @Test
func L5MemoryAreaFrames() throws {
    let owner = DeckMemoryOwner.lead("crm")
    let store = NativeMemoryStore(owner: owner, fixture: true)
    let now = Date()
    func labels(_ type: String, _ back: Double) -> DeckMemoryLabels { .init(owner: owner, project: "crm", date: now.addingTimeInterval(-back), type: type) }
    let template = DeckMemoryTemplate(category: .lead, card: "## Top rules\n- Report in the report form: done or not, result in three lines, proof, what you need.\n- Check exact facts at the source, never from memory.\n\n## How to use memory\nWrite a decision note when something is decided.",
        checklist: "- A decision was made\n- The person corrected something\n- A result with proof\n- Something left open",
        parts: Set(DeckMemoryPart.allCases), helperAI: "claude", helperModel: "sonnet")
    store.template = template
    store.card = DeckMemoryCard(owner: owner, text: "# CRM lead\n\n- Staging first, never straight to live.\n- Brokers page is the priority this week.", path: "projects/crm/lead/card.md", limit: 6000, updatedAt: now, sharedCharacters: template.card.count)
    let types: [DeckMemoryNoteType] = [.decision, .preference, .correction, .result, .openItem, .decision, .result]
    let titles = ["Ship the dev copy first", "Short plain replies", "Use the staging database for crawls", "Broker invite flow works", "Password reset mail lands in spam", "One blue button per screen", "Import of 24 agents verified"]
    var notes: [DeckMemoryNote] = []
    for (i, title) in titles.enumerated() {
        notes.append(DeckMemoryNote(id: "n-\(i)", title: title, body: "Body \(i)", type: types[i], labels: labels(types[i].rawValue, Double(i) * 5400), path: "projects/crm/notes/n-\(i).md",
                                    supersedes: i == 0 ? "n-old" : nil, source: i % 2 == 0 ? "helper" : "user", updatedAt: now))
    }
    store.notes = notes
    store.topics = [DeckMemoryTopic(id: "brokers-page", owner: owner, title: "Brokers page", body: "Where we are: the list and the invite flow work. Left: bulk import and the empty state.", open: true, path: "projects/crm/lead/topics/brokers-page.md", labels: labels("topic", 600), updatedAt: now.addingTimeInterval(-600)),
                    DeckMemoryTopic(id: "billing", owner: owner, title: "Billing move", body: "Closed after the Stripe webhooks were verified.", open: false, path: "projects/crm/lead/topics/billing.md", labels: labels("topic", 86400), updatedAt: now.addingTimeInterval(-86400))]
    store.playbook = DeckMemoryPlaybook(owner: owner, rows: [
        .init(jobKind: "default", ai: "claude", model: "", effort: "high", permission: "asks first", instructions: "Report in the report form."),
        .init(jobKind: "bug fix", ai: "claude", model: "", effort: "xhigh", permission: "edits on its own", instructions: "Reproduce first, then fix, then prove."),
        .init(jobKind: "review", ai: "codex", model: "", effort: "medium", permission: "plans only", instructions: "Read only. List findings by severity.")],
        path: "projects/crm/lead/playbook.md", updatedAt: now)
    store.board = [
        DeckMemoryBoardRow(id: "session:1", kind: .session, title: "CRM session", labels: labels("session", 120), doing: "Fixing the broker invite mail", lastResult: "Invite link opens the right company. Tests pass.", state: .reported, updatedAt: now.addingTimeInterval(-120)),
        DeckMemoryBoardRow(id: "agent:1", kind: .agent, title: "crm-db", labels: labels("agent", 900), doing: "Idle", lastResult: "Slow query on leads fixed with an index.", state: .verified, proof: "EXPLAIN shows index scan, 4 ms", updatedAt: now.addingTimeInterval(-900)),
        DeckMemoryBoardRow(id: "task:1", kind: .task, title: "Bulk import of brokers", labels: labels("task", 3600), doing: "Waiting", lastResult: "CSV parser drafted.", waitingForUser: "Which columns are required?", state: .attempted, updatedAt: now.addingTimeInterval(-3600))]
    store.diary = [
        DeckMemoryDiaryEntry(id: 3, labels: .init(owner: owner, project: "crm", agent: "claude", date: now.addingTimeInterval(-60), type: "diary"), role: .assistant, text: "The invite link now opens the right company. I ran the focused tests and they pass."),
        DeckMemoryDiaryEntry(id: 2, labels: .init(owner: owner, project: "crm", date: now.addingTimeInterval(-200), type: "diary"), role: .user, text: "the invite mail opens the wrong company, fix it"),
        DeckMemoryDiaryEntry(id: 1, labels: .init(owner: owner, project: "crm", agent: "claude", date: now.addingTimeInterval(-400), type: "diary"), role: .assistant, text: "Brokers list is done. Next is the invite flow.")]
    store.questions = [DeckMemoryQuestion(id: 1, owner: owner, text: "Two notes disagree: “staging first” and “ship straight to live for hotfixes”. Which one holds?", context: "n-2 (3 Oct) and n-9 (9 Oct)", askedAt: now.addingTimeInterval(-7200))]
    store.settings = [DeckMemoryKeys.helperLastRun: "12 min ago: read 1 session, wrote 2 notes.", DeckMemoryKeys.tidyLastRun: "Last night: 2 merged, 1 question for you."]
    store.loaded = true
    for dark in [false, true] {
        for part in NativeMemoryPart.allCases {
            let view = NativeMemoryArea(owner: owner, name: "CRM", filledBy: "Alex", fixture: store, part: part)
            try L5MemoryRender(view, size: CGSize(width: 1100, height: 680), dark: dark, name: "area-\(part.rawValue)")
        }
        try L5MemoryRender(NativeMemoryTemplatesView(category: .agent, fixture: [.agent: DeckMemoryTemplate(category: .agent, card: template.card, checklist: template.checklist, parts: Set(DeckMemoryPart.allCases).subtracting([.playbook])), .lead: template,
            .orchestrator: DeckMemoryTemplate(category: .orchestrator, card: template.card, checklist: template.checklist, parts: Set(DeckMemoryPart.allCases))]),
            size: CGSize(width: 900, height: 640), dark: dark, name: "templates")
    }
}

@MainActor
private func L5MemoryRender<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    var out = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { out.deleteLastPathComponent() }
    out = out.appendingPathComponent("design-2026-10-10/built.noindex")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try png.write(to: out.appendingPathComponent("L5-memory-\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
}
