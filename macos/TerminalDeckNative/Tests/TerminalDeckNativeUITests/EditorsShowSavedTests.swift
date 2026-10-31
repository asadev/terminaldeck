import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Editors show what is really saved: a change made elsewhere is shown, typing is never thrown away,
/// and an old copy is never written back over a newer one.
@MainActor @Suite
struct EditorsShowSavedTests {
    @Test func projectNameSavesOncePerPauseAndFollowsTheRegistry() async throws {
        var saves: [String] = []
        let model = PROJPAGESettingsModel(invoke: { channel, args in
            if channel == "project-registry:save" { saves.append(try NativeRPCValue.fromFoundation(args.first ?? nil)["name"].string ?? "") }
            return [String: Any]()
        })
        var project = PROJProject(id: "fixture-project", name: "Old", folders: ["/tmp/fixture-project"])
        model.registryChanged(project)
        for name in ["N", "Ne", "New"] { project.name = name; model.saveProject(project) }
        #expect(model.edited?.name == "New")
        // An older copy arriving while the save waits never replaces what is being typed.
        model.registryChanged(PROJProject(id: "fixture-project", name: "Ne", folders: ["/tmp/fixture-project"]))
        #expect(model.edited?.name == "New")
        for _ in 0..<50 where saves.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(saves == ["New"])
        model.registryChanged(project)
        #expect(model.edited == nil)
        // Renamed elsewhere with no save waiting: the window shows the registry's copy, not its own.
        project.name = "Renamed elsewhere"
        model.registryChanged(project)
        #expect(model.edited == nil)
    }

    @Test func mcpSettingsWindowFollowsRenamesAndLetsRemovedServersGo() throws {
        let path = "/tmp/fixture-mcp-" + UUID().uuidString
        func server(_ name: String, command: String) throws -> McpServerStatus {
            let raw = try #require(OrderedJSON.parse(
                #"{"id":"user:\#(name)","name":"\#(name)","scope":"user","transport":"stdio","command":"\#(command)","source":"user"}"#))
            return try #require(McpServerStatus.from(raw))
        }
        let foo = try server("foo", command: "old-command")
        let first = NativeCatalogMcpSettingsWindow.held(server: foo, projectPath: path) {}
        #expect(NativeCatalogMcpSettingsWindow.held(server: foo, projectPath: path) {}.settings === first.settings)
        // Renamed to "bar": opening "bar" from the list raises the same window, never a second one.
        first.settings.onIdentityChanged("user:bar")
        let renamed = NativeCatalogMcpSettingsWindow.held(server: try server("bar", command: "old-command"), projectPath: path) {}
        #expect(renamed.windowID == first.windowID)
        #expect(renamed.settings === first.settings)
        // A new "foo" while "bar" is open gets its own window, showing its own command.
        let newFoo = NativeCatalogMcpSettingsWindow.held(server: try server("foo", command: "new-command"), projectPath: path) {}
        #expect(newFoo.windowID != first.windowID)
        #expect(newFoo.settings !== first.settings)
        #expect(newFoo.settings.draft.command == "new-command")
        // Removing a server lets its model (and the secret values it read) go.
        newFoo.settings.onRemoved()
        let again = NativeCatalogMcpSettingsWindow.held(server: try server("foo", command: "newest-command"), projectPath: path) {}
        #expect(again.settings !== newFoo.settings)
        #expect(again.settings.draft.command == "newest-command")
        NativeCatalogMcpSettingsWindow.forget(first.windowID)
        NativeCatalogMcpSettingsWindow.forget(again.windowID)
    }

    @Test func mcpSettingsOpenShowsTheSavedDefinition() async throws {
        let raw = try #require(OrderedJSON.parse(
            #"{"id":"user:foo","name":"foo","scope":"user","transport":"stdio","command":"old-command","source":"user"}"#))
        let held = try #require(McpServerStatus.from(raw))
        let model = NativeCatalogMcpSettingsModel(server: held, projectPath: nil)
        model.invoke = { channel, _ in
            #expect(channel == "mcp:list")
            return try #require(OrderedJSON.parse(
                #"[{"id":"user:foo","name":"foo","scope":"user","transport":"stdio","command":"changed-elsewhere","source":"user","env":{}}]"#))
        }
        await model.readSaved()
        #expect(model.draft.command == "changed-elsewhere")
    }

    @Test func memoryCardKeepsEarlyTypingAndTakesUntouchedChanges() {
        #expect(NativeMemoryCardPart.adopting(text: "", base: "", saved: "Saved card") == "Saved card")
        #expect(NativeMemoryCardPart.adopting(text: "Typed before it loaded", base: "", saved: "Saved card") == "Typed before it loaded")
        #expect(NativeMemoryCardPart.adopting(text: "Saved card", base: "Saved card", saved: "Changed elsewhere") == "Changed elsewhere")
        #expect(NativeMemoryCardPart.adopting(text: "Draft", base: "Saved card", saved: "Changed elsewhere") == "Draft")
    }
}
