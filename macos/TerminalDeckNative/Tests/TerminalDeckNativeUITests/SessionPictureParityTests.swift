import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class SessionPictureParityTests: XCTestCase {
    func testSearchHitKeepsItsProjectFolderForTheBadge() throws {
        let hit = try JSONDecoder().decode(SessionHit.self, from: Data(#"{"sessionId":"past","cwd":"/scratch/Deck Dev","at":1,"role":"user","isSidechain":false,"snippet":{"text":"hello","ranges":[],"truncatedStart":false,"truncatedEnd":false}}"#.utf8))
        XCTAssertEqual(hit.cwd, "/scratch/Deck Dev")
        let old = try JSONDecoder().decode(SessionHit.self, from: Data(#"{"sessionId":"past","at":1,"role":"user","isSidechain":false,"snippet":{"text":"hello","ranges":[],"truncatedStart":false,"truncatedEnd":false}}"#.utf8))
        XCTAssertNil(old.cwd)
    }

    func testWhoLineUsesTheFullAINameAndKeepsShellNames() {
        XCTAssertEqual(SIDEBARSessionLine.subtitle(agent: "Decker", ai: SIDEBARSessionLine.aiName("claude")), "Decker · Claude Code")
        XCTAssertEqual(SIDEBARSessionLine.subtitle(agent: "Alex", ai: SIDEBARSessionLine.aiName("codex")), "Alex · Codex")
        XCTAssertEqual(SIDEBARSessionLine.subtitle(agent: nil, ai: SIDEBARSessionLine.aiName("powershell")), "PowerShell")
        XCTAssertNil(SIDEBARSessionLine.subtitle(agent: nil, ai: nil))
    }

    @MainActor func testIndependentNeverGetsAProjectBadge() throws {
        try SessionPictureFixture.prepare()
        let identity = NativeSessionRowIdentity(id: "picture-fixture-independent", project: .init(id: PROJProjects.independentID, name: "Independent", folders: []))
        XCTAssertNil(identity.project)
        XCTAssertNil(identity.agent)
    }

    @MainActor func testExplicitProjectAndAgentKeepTheirPictures() throws {
        try SessionPictureFixture.prepare()
        let agent = try XCTUnwrap(Self.agents.first { $0.id == "decker" })
        let project = PROJProject(id: "picture-fixture-deck", name: "Deck Dev", folders: ["/scratch/picture-fixture-deck"])
        let identity = NativeSessionRowIdentity(id: "picture-fixture", provider: "claude", chat: true, agent: agent, project: project)
        XCTAssertEqual(identity.agent?.icon, .symbol("chart.bar.fill"))
        XCTAssertEqual(identity.agent?.iconColour, "green")
        XCTAssertEqual(identity.project?.id, project.id)
        XCTAssertEqual(identity.subtitle, "Decker · Claude Code")
        XCTAssertTrue(identity.chat)
    }

    /// Fixed-frame views only. No app launch, server, hooks, sessions or install.
    @MainActor func testRenderPicturesBesidePhoneProportions() throws {
        guard let path = ProcessInfo.processInfo.environment["TD_SESSION_PICTURE_FRAMES"] else {
            throw XCTSkip("Set TD_SESSION_PICTURE_FRAMES to render the picture fixtures.")
        }
        try SessionPictureFixture.prepare()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let agent = try XCTUnwrap(Self.agents.first { $0.id == "decker" })
        let hoot = try XCTUnwrap(Self.agents.first { $0.isHoot })
        // A real image file tests the logo branch, beside a project with no logo.
        let logo = NSImage(size: .init(width: 40, height: 40), flipped: false) { rect in
            NSColor.systemOrange.setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            ("D" as NSString).draw(at: .init(x: 10, y: 7), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.white])
            return true
        }
        let logoPath = directory.appendingPathComponent("fixture-logo.png")
        let bitmap = try XCTUnwrap(logo.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: logoPath)
        let logoFolder = ProjectLogos.directory
        try FileManager.default.createDirectory(at: logoFolder, withIntermediateDirectories: true)
        let adopted = try ProjectLogos.adopt(logoPath, projectID: "fixture-logo")
        let project = PROJProject(id: "fixture-logo", name: "Deck Dev", folders: [], logo: adopted)
        XCTAssertNotNil(ProjectLogos.image(project))
        let letterProject = PROJProject(id: "fixture-letter", name: "CRM", folders: [])
        let samples: [(String, AGTAgent?, String, PROJProject?, Bool)] = [
            ("Agent with project", agent, "claude", project, true),
            ("Plain shell", nil, "powershell", letterProject, false),
            ("Hoot", hoot, "claude", project, true),
            ("Independent agent", agent, "codex", nil, true),
            ("Plain chat", nil, "codex", nil, true)
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = HStack(alignment: .top, spacing: 24) {
                column("Mac rows · 26 pt", size: 26, samples: samples)
                column("Phone spec · 28 pt (Mac glyphs)", size: 28, samples: samples, reference: true)
            }.padding(20).frame(width: 760, height: 600).background(DeckTokens.frame)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("pictures-\(scheme == .dark ? "dark" : "light").png"))
            XCTAssertGreaterThan(rep.pixelsWide, 1000)
        }
        XCTAssertFalse(NSApp.isActive)
    }

    @MainActor private static var agents: [AGTAgent] {
        AGTDirectory.build(profiles: [.init(id: "decker", name: "Decker", icon: "sf:chart.bar.fill@green", provider: "claude")], live: [], tasks: [])
    }

    // A separate arrangement of the phone's documented dimensions, using Mac glyphs and logos.
    // This is a source-spec reference, not a screenshot of the iPhone app.
    @MainActor private func phoneReference(agent: AGTAgent?, project: PROJProject?, chat: Bool, selected: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let agent { AgentAvatar(agent: agent, size: 28) }
                else { Image(systemName: chat ? "bubble.left" : "terminal").font(.system(size: 16.24)).foregroundStyle(.secondary) }
            }.frame(width: 28, height: 28)
            if let project {
                ProjectLogoView(project: project, size: 15)
                    .padding(1.5)
                    .background(selected ? Color.accentColor : DeckTokens.frame, in: .rect(cornerRadius: 5.25))
                    .offset(x: 5.6, y: 5.6)
            }
        }.frame(width: 28, height: 28)
    }

    @MainActor private func column(_ title: String, size: CGFloat,
        samples: [(String, AGTAgent?, String, PROJProject?, Bool)], reference: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                ForEach([false, true], id: \.self) { selected in
                    HStack(spacing: 12) {
                        if reference {
                            self.phoneReference(agent: sample.1, project: sample.3, chat: sample.4, selected: selected)
                        } else {
                            SIDEBARSessionPicture(agent: sample.1, provider: sample.2, project: sample.3, onAccent: selected, size: size, chat: sample.4)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sample.0).font(.system(size: 13, weight: .medium))
                            Text(SIDEBARSessionLine.subtitle(agent: sample.1?.name, ai: SIDEBARSessionLine.aiName(sample.2)) ?? "")
                                .font(.system(size: 11)).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(8).frame(width: 340, height: 46)
                        .foregroundStyle(selected ? Color.white : .primary)
                        .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 8))
                }
            }
        }
    }
}

@MainActor enum SessionPictureFixture {
    private static var ready = false
    static func prepare() throws {
        guard !ready else { return }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TD_NATIVE_DATA_DIR"], path.hasPrefix("/private/tmp/td-glitch-session-pictures-") else {
            throw XCTSkip("Picture checks require their private data folder.")
        }
        let data = URL(fileURLWithPath: path)
        let resources = data.deletingLastPathComponent().appendingPathComponent("resources")
        for relative in NativeWebAssets.required {
            let file = resources.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try AppModel.prepareForUITests(configuration: .init(source: .nativeOnly(try NativeWebAssets.discover(resources: resources)), dataRoot: data))
        ready = true
    }
}
