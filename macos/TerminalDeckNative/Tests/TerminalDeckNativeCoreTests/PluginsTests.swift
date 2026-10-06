import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Settings → Plugins, native. Mirrors plugins-model.test.ts and PluginsSection.test.tsx:
// the engine's answers narrowed the same way, and the same words on screen.

private let stateFixture = CodingAIJSON.parse(#"""
{
  "folder": "/Users/me/Library/Application Support/terminaldeck/plugins",
  "confinement": "Each plugin runs in its own process.",
  "projects": ["/work/api", "/work/web"],
  "plugins": [
    {"id": "notes", "name": "Notes", "summary": "Keeps notes", "version": "1.2.0", "enabled": true, "state": "running",
     "note": "Running since 10:00", "declared": ["tasks.read", "knowledge.read", "bogus"], "granted": ["knowledge.read"],
     "projects": ["/work/api"], "allowed": true,
     "tools": [{"name": "add", "wire": "notes.add", "title": "Add a note", "tier": "act"}, {"name": "x", "wire": "", "tier": "act"}, {"name": "y", "wire": "y", "tier": "nope"}]},
    {"id": "fresh", "state": "needs-ok", "allowed": 1, "enabled": 1},
    {"id": "old", "name": "Old", "state": "changed", "declared": [], "allowed": false},
    {"id": "bad", "state": "weird"},
    {"name": "no id", "state": "off"}
  ]
}
"""#)

@Test func pluginsStateNarrowsLikeTheWeb() throws {
    let state = try #require(PluginsState.from(stateFixture))
    #expect(state.folder.hasSuffix("/plugins"))
    #expect(state.projects == ["/work/api", "/work/web"])
    #expect(state.plugins.map(\.id) == ["notes", "fresh", "old"])
    let notes = state.plugins[0]
    #expect(notes.declared == ["tasks.read", "knowledge.read"])
    #expect(notes.tools.map(\.title) == ["Add a note"])
    let fresh = state.plugins[1]
    #expect(fresh.name == "fresh")
    #expect(fresh.allowed == false)
    #expect(fresh.enabled == false)
    #expect(PluginsState.from(CodingAIJSON.parse(#"{"folder":"x"}"#)) == nil)
}

@Test func pluginsWordsMatchTheSection() throws {
    let state = try #require(PluginsState.from(stateFixture))
    let notes = state.plugins[0]
    #expect(notes.capabilityLine("knowledge.read") == "Read what is recorded about the projects you choose: api — allowed")
    #expect(notes.capabilityLine("tasks.read") == "Read your tasks — not allowed")
    #expect(notes.toolsLine == "Tools for Hoot: Add a note (act)")
    #expect(PluginState.needsOk.words == "Not allowed")
    #expect(PluginState.broken.words == "Cannot be used")
    #expect(notes.editLabel(editing: false) == "Change")
    #expect(notes.editLabel(editing: true) == "Close")
    #expect(state.plugins[1].editLabel(editing: false) == "Allow…")
    #expect(state.plugins[2].editLabel(editing: false) == "Allow again…")
    #expect(PluginCatalog.words("tools.contribute") == "Give Hoot new tools")
    #expect(PluginCatalog.projectName("/work/api/") == "api")
}

@Test func pluginsAllowDraftAsksOnlyForSomethingNew() throws {
    let state = try #require(PluginsState.from(stateFixture))
    var draft = PluginAllowDraft(plugin: state.plugins[0])
    #expect(draft.chosen == ["knowledge.read"])
    #expect(draft.places == ["/work/api"])
    #expect(draft.asks == false)
    #expect(draft.buttonLabel == "Save")
    draft.setProject("/work/web", true)
    #expect(draft.asks == true)
    #expect(draft.buttonHelp == "You are asked to confirm in a dialog.")
    draft.setProject("/work/web", false)
    draft.setProject("/work/api", false)
    #expect(draft.missingPlace == true)
    #expect(draft.buttonHelp == "Choose at least one project, or turn that one off.")
    draft.setCapability("knowledge.read", false)
    #expect(draft.missingPlace == false)
    #expect((draft.input["projects"] as? [String]) == [])

    let fresh = PluginAllowDraft(plugin: state.plugins[1])
    #expect(fresh.asks == true)
    #expect(fresh.buttonLabel == "Allow…")
}

@Test func pluginsResultReadsTheAnswer() {
    let ok = PluginsResult.from(CodingAIJSON.parse(#"{"ok":true,"state":{"plugins":[]}}"#))
    #expect(ok.ok)
    #expect(ok.state?.plugins.isEmpty == true)
    let refused = PluginsResult.from(CodingAIJSON.parse(#"{"ok":false,"message":"No."}"#))
    #expect(refused.ok == false)
    #expect(refused.message == "No.")
    #expect(PluginsResult.from(.null).message == PluginsResult.unreadable)
}
