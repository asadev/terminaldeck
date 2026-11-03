import AppKit
import SwiftUI
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Captures actual existing components in the test process. No app main,
/// NSApplication, NSWindow, panel presentation, engine or AI is started.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROJ_RENDER_TESTS"] == "1"))
@MainActor
struct PROJRenderTests {
    @Test func projectLabelsAndBatchChoiceRenderInBothAppearances() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design-2026-10-10/built.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let labels = NativePROJLabels.shared
        labels.projects = PROJProjects.defaults + [.init(id: "research", name: "Research", folders: ["/projects/research"], colour: "pink")]
        let profiles = [
            AgentProfile(id: "proj-imatch", name: "iMatch reviewer", role: "Checks iMatch changes", defaultProject: "/work/imatch", projectID: "imatch"),
            AgentProfile(id: "proj-crm", name: "CRM database", role: "Checks CRM data", defaultProject: "/work/crm", projectID: "crm"),
            AgentProfile(id: "proj-independent", name: "Independent reviewer", role: "Checks any assigned work", defaultProject: "/work/crm", projectID: "independent"),
            AgentProfile(id: "proj-research", name: "Research reviewer", role: "Checks research notes", defaultProject: "/projects/research", projectID: "research")
        ]
        AGTAgentsStore.shared.fixture = TasksState(agents: profiles)
        AGTAgentsStore.shared.liveLoaded = true
        let agents = AGTAgentsStore.shared.agents.filter { $0.kind == .profile }
        #expect(agents.count == 4)
        #expect(labels.name(for: nil, folder: "/projects/research/notes") == "Research")
        #expect(labels.name(for: "independent", folder: "/work/crm") == "Independent")
        let servers = CodingAIServer.parseList(CodingAIJSON([
            ["id": "proj-crm-server", "name": "CRM server", "address": "46.28.44.154", "username": "root", "port": 22, "projectId": "crm"],
            ["id": "proj-imatch-server", "name": "iMatch server", "address": "imza-server", "username": "root", "port": 22, "projectId": "imatch"]
        ]))
        #expect(servers.count == 2)
        var route = NativeServersRoute.list
        let crmRow = NativeServerRow(server: servers[0], state: nil, now: 0, open: { route = .server(servers[0].id) })
        crmRow.open()
        #expect(route == .server("proj-crm-server"))
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            let cards = HStack(alignment: .top, spacing: 12) {
                ForEach(agents) { AGFRAMEAgentCard(agent: $0).frame(maxWidth: .infinity) }
            }.padding(20)
            let bitmap = try capture(cards, dark: dark, size: CGSize(width: 1120, height: 350),
                output: output.appendingPathComponent("PROJ-agents-\(appearance).png"))
            if let image = bitmap.cgImage,
               let crop = image.cropping(to: CGRect(x: 0, y: 0, width: min(image.width, 560), height: image.height)),
               let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("PROJ-agent-label-crop-\(appearance).png"))
            }
            let rows = VStack(spacing: 12) {
                crmRow
                NativeServerRow(server: servers[1], state: nil, now: 0, open: {})
            }.padding(20)
            _ = try capture(rows, dark: dark, size: CGSize(width: 820, height: 220),
                output: output.appendingPathComponent("PROJ-servers-\(appearance).png"))
        }
    }
    private func capture<V: View>(_ view: V, dark: Bool, size: CGSize, output: URL) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        return try capture(host, output: output)
    }
    private func capture(_ view: NSView, output: URL) throws -> NSBitmapImageRep {
        #expect(output.deletingLastPathComponent().lastPathComponent == "built.noindex")
        #expect(output.lastPathComponent.hasPrefix("PROJ-"))
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        print("PROJ offscreen test: \(output.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        return bitmap
    }
}
