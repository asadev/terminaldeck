import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors src/renderer/memory/MemoryPage.test.tsx and graph-layout.test.ts.

private let alpha = MemorySpace(id: "a", kind: .claudeProject, label: "alpha", root: "/m/a", project: "/work/alpha")
private let shared = MemorySpace(id: "s", kind: .claudeProject, label: "shared", root: "/m/s", project: "/work/s",
                                 sharedWith: ["/work/one", "/work/two"])
private let unknown = MemorySpace(id: "u", kind: .claudeProject, label: "-Users-x", root: "/m/u")
private let hoot = MemorySpace(id: "h", kind: .hoot, label: "Hoot", root: "/m/h")
private let knowledge = MemorySpace(id: "k", kind: .knowledge, label: "alpha", root: "/m/k", project: "/work/alpha")
private let codex = MemorySpace(id: "c", kind: .codex, label: "Codex", root: "/m/c", accounts: ["work", "home"])

@Suite("Memory — the list of memories")
struct MemoryListTests {
    @Test func groupsByWhoseTheyAreAndSaysWhichAreShared() {
        let groups = MemoryRules.groups([alpha, codex, hoot, knowledge, shared])
        #expect(groups.map(\.kind) == [.hoot, .claudeProject, .codex, .knowledge])
        #expect(groups.map { MemoryRules.kindTitle($0.kind) } == ["Hoot", "Claude Code", "Codex", "Project knowledge"])
        #expect(groups[1].spaces.map(\.id) == ["a", "s"])
        #expect(MemoryRules.sharedLine(shared) == "Shared with 2 folders")
        #expect(MemoryRules.sharedLine(alpha) == nil)
        #expect(MemoryRules.place(codex) == "work, home")
        #expect(MemoryRules.place(hoot) == nil)
    }

    @Test func labelsAFolderItCouldNotConfirmHonestly() {
        #expect(MemoryRules.place(unknown) == "Folder name as Claude Code stores it")
        #expect(MemoryRules.place(alpha) == "/work/alpha")
    }

    @Test func opensOnTheOpenProjectsOwnMemoryElseHoots() {
        let all = [hoot, alpha, shared, knowledge]
        #expect(MemoryRules.firstSpace(all, projectPath: "/work/alpha")?.id == "a")
        #expect(MemoryRules.firstSpace(all, projectPath: "/work/two")?.id == "s")
        #expect(MemoryRules.firstSpace([hoot, knowledge], projectPath: "/work/alpha")?.id == "k")
        #expect(MemoryRules.firstSpace(all, projectPath: "/elsewhere")?.id == "h")
        #expect(MemoryRules.firstSpace(all, projectPath: nil)?.id == "h")
        #expect(MemoryRules.firstSpace([alpha], projectPath: nil)?.id == "a")
        #expect(MemoryRules.firstSpace([], projectPath: nil) == nil)
    }
}

@Suite("Memory — notes, search and an open note")
struct MemoryNotesTests {
    @Test func labelsAreTheNotesOwnElseItsType() {
        let typed = MemoryNoteRow(path: "rules.md", title: "deploy-rules", type: "feedback")
        #expect(MemoryRules.labels(typed) == [MemoryLabel(key: "type", value: "feedback")])
        let record = MemoryNoteRow(path: "k1.md", title: "storage", type: "decision", labels: [
            MemoryLabel(key: "kind", value: "decision"), MemoryLabel(key: "status", value: "verified"),
            MemoryLabel(key: "source", value: "review"), MemoryLabel(key: "verified", value: "2026-10-04"),
        ])
        #expect(MemoryRules.labels(record).map(MemoryRules.labelText) == ["decision", "verified", "review", "verified 2026-10-04"])
        #expect(MemoryRules.labels(MemoryNoteRow(path: "x", title: "x")).isEmpty)
        #expect(MemoryRules.danglingLine(1) == "1 link reaches no note.")
        #expect(MemoryRules.danglingLine(3) == "3 links reach no note.")
    }

    @Test func searchHitsSayWhichMemoryTheyCameFrom() {
        let hit = MemoryHit(spaceId: "a", path: "rules.md", title: "deploy-rules", snippet: "Deploy means…")
        #expect(MemoryRules.hitSource(hit, spaces: [alpha, hoot]) == "Claude Code · alpha")
        #expect(MemoryRules.hitSource(MemoryHit(spaceId: "zz", path: "p", title: "t", snippet: ""), spaces: [alpha]) == "")
    }

    @Test func willNotSaveANoteItCouldNotShowWhole() {
        #expect(MemoryRules.saveBecause(truncated: true, dirty: true) == "This note is larger than the page can show, so saving it here would cut it short.")
        #expect(MemoryRules.saveBecause(truncated: false, dirty: false) == "Nothing has changed.")
        #expect(MemoryRules.saveBecause(truncated: false, dirty: true) == nil)
    }

    @Test func provenanceAndTrashWords() {
        let write = MemoryWrite(conversationId: "1234567890abcdef", folder: "/work/a", at: 0, tool: "Write", edit: false)
        #expect(MemoryRules.writeLine(write) == "Written in conversation 12345678")
        #expect(MemoryRules.readLine(MemoryProvenance(writes: [], conversationsRead: 1, truncated: false)) == "1 recent conversation read.")
        #expect(MemoryRules.readLine(MemoryProvenance(writes: [], conversationsRead: 30, truncated: true)) == "30 recent conversations read; older ones were not.")
        #expect(MemoryRules.deletedMessage(indexLineRemoved: true) == "Moved to the Trash, and its line taken out of MEMORY.md.")
        #expect(MemoryRules.deletedMessage(indexLineRemoved: false) == "Moved to the Trash.")
        #expect(MemoryRules.dateOf(0) == "")
    }
}

@Suite("Memory — reading what crosses the bridge")
struct MemoryWireTests {
    @Test func fillsEveryMissingFieldRatherThanFailing() {
        let spaces = MemoryWire.spaces(["spaces": [["id": "x", "kind": "nonsense"], ["label": "no id"]]])
        #expect(spaces.count == 1)
        #expect(spaces[0].kind == .claudeProject)
        #expect(spaces[0].label == "x")
        #expect(MemoryWire.spaces(nil).isEmpty)
        #expect(MemoryWire.notes(["ok": false]) == .failed("This memory could not be read."))
        #expect(MemoryWire.read(["ok": false, "error": "gone"]) == .failed("gone"))
        #expect(MemoryWire.change(["ok": false]) == .failed("Nothing was changed."))
        #expect(MemoryWire.provenance([String: Any]()) == .failed("This could not be worked out."))
        let row = MemoryWire.noteRow(["path": "a.md", "labels": [["key": "k", "value": ""], ["key": "kind", "value": "x"]]])
        #expect(row.title == "a.md")
        #expect(row.labels == [MemoryLabel(key: "kind", value: "x")])
    }

    @Test func readsNotesGraphAndAnOpenNote() {
        let notes = MemoryWire.notes([
            "ok": true,
            "notes": [["path": "MEMORY.md", "title": "Memory Index", "modifiedAt": 5], ["title": "no path"]],
            "graph": ["nodes": [["path": "MEMORY.md"], ["path": "a.md"]],
                      "edges": [["from": "MEMORY.md", "to": "a.md"], ["from": "", "to": "x"]],
                      "dangling": [["from": "a.md", "target": "gone.md"]]],
        ]).value
        #expect(notes?.notes.map(\.path) == ["MEMORY.md"])
        #expect(notes?.graph.nodes == ["MEMORY.md", "a.md"])
        #expect(notes?.graph.edges == [MemoryEdge(from: "MEMORY.md", to: "a.md")])
        #expect(notes?.graph.dangling.first?.target == "gone.md")

        let read = MemoryWire.read([
            "ok": true, "spaceId": "a", "path": "a.md", "text": "hi", "truncated": true,
            "version": ["modifiedAt": 7, "bytes": 2], "note": ["path": "a.md", "title": "A"],
            "links": [["target": "b", "to": "b.md"], ["target": "c", "to": nil], ["to": "x"]],
            "backlinks": ["MEMORY.md", 3], "indexed": true,
        ]).value
        #expect(read?.links.count == 2)
        #expect(read?.links[1].to == nil)
        #expect(read?.backlinks == ["MEMORY.md"])
        #expect(read?.version == MemoryVersion(modifiedAt: 7, bytes: 2))
        #expect(read?.indexed == true)
        #expect(read?.truncated == true)

        let hits = MemoryWire.hits(["hits": [["spaceId": "a", "path": "p"], ["spaceId": "", "path": "q"]]])
        #expect(hits.count == 1)
        #expect(hits[0].title == "p")

        let provenance = MemoryWire.provenance(["ok": true, "writes": [["conversationId": "c1", "action": "edit", "at": 3], ["action": "write"]],
                                                "conversationsRead": 4]).value
        #expect(provenance?.writes.count == 1)
        #expect(provenance?.writes[0].edit == true)
        #expect(provenance?.conversationsRead == 4)
        #expect(MemoryWire.change(["ok": true, "indexLineRemoved": true]).value?.indexLineRemoved == true)
        #expect(MemoryWire.change(["ok": true]).value?.version == nil)
    }
}

@Suite("Memory — placing the notes")
struct MemoryGraphTests {
    let w = 800.0, h = 480.0

    @Test func placesEveryNodeInsideTheFrame() {
        let nodes = ["a", "b", "c", "d", "e"]
        let at = MemoryRules.layout(nodes: nodes, edges: [MemoryEdge(from: "a", to: "b"), MemoryEdge(from: "a", to: "ghost")],
                                    width: w, height: h, margin: 32)
        #expect(Set(at.keys) == Set(nodes))
        for point in at.values {
            #expect(point.x >= 32 && point.x <= 768)
            #expect(point.y >= 32 && point.y <= 448)
        }
    }

    @Test func isTheSamePictureEveryTime() {
        let nodes = ["MEMORY.md", "a.md", "b.md", "c.md"]
        let edges = [MemoryEdge(from: "MEMORY.md", to: "a.md"), MemoryEdge(from: "MEMORY.md", to: "b.md")]
        let one = MemoryRules.layout(nodes: nodes, edges: edges, width: w, height: h, margin: 32)
        let two = MemoryRules.layout(nodes: nodes, edges: edges, width: w, height: h, margin: 32)
        for node in nodes {
            #expect(one[node]?.x == two[node]?.x)
            #expect(one[node]?.y == two[node]?.y)
        }
    }

    @Test func pullsLinkedNotesCloser() {
        let nodes = ["hub", "a", "b", "c", "lonely-1", "lonely-2"]
        let edges = [MemoryEdge(from: "hub", to: "a"), MemoryEdge(from: "hub", to: "b"), MemoryEdge(from: "hub", to: "c")]
        let at = MemoryRules.layout(nodes: nodes, edges: edges, width: w, height: h, margin: 32)
        func d(_ p: String, _ q: String) -> Double {
            let a = at[p]!, b = at[q]!
            return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        #expect((d("hub", "a") + d("hub", "b") + d("hub", "c")) / 3 < d("lonely-1", "lonely-2"))
    }

    @Test func handlesNothingAndOneNote() {
        #expect(MemoryRules.layout(nodes: [], edges: [], width: w, height: h, margin: 32).isEmpty)
        let one = MemoryRules.layout(nodes: ["only"], edges: [], width: w, height: h, margin: 32)["only"]
        #expect(one?.x == 400 && one?.y == 240)
    }

    @Test func staysQuickForALargeMemory() {
        let nodes = (0..<600).map { "n\($0).md" }
        let edges = (1..<600).map { MemoryEdge(from: nodes[$0 - 1], to: nodes[$0]) }
        let started = Date()
        _ = MemoryRules.layout(nodes: nodes, edges: edges, width: w, height: h, margin: 32)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func dotSizeFollowsItsLinks() {
        let graph = MemoryGraph(nodes: ["a", "b"], edges: [MemoryEdge(from: "a", to: "b")], dangling: [])
        #expect(MemoryRules.degrees(graph) == ["a": 1, "b": 1])
        #expect(MemoryRules.radius(degree: 0) == 4)
        #expect(MemoryRules.radius(degree: 100) == 10)
    }
}
