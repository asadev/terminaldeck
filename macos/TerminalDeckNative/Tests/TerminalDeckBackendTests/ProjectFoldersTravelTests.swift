import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Folders that travel with a project (19 Nov): two Macs, each with the same project in a DIFFERENT folder, one owner
/// over many project folders each, records passed as the sync core passes them. Scratch folders only.
struct ProjectFoldersTravelTests {
    struct Two {
        let f: CloudFolderFixture
        let key = CloudProjectFoldersRules.key(projectId: "project-deck")
        func project(_ mac: String) -> URL { f.base.appendingPathComponent(mac + "/home/" + (mac == "a" ? "Deck Dev" : "Work/Deck"), isDirectory: true) }
        func owner(_ mac: String, device: String, roots: [String: URL]? = nil) async throws -> BackendCloudFolder {
            try FileManager.default.createDirectory(at: project(mac), withIntermediateDirectories: true)
            let clock = f.clock
            let made = try BackendCloudFolder(deviceId: device, folder: f.base.appendingPathComponent(mac + "/data/root"),
                                              stateRoot: f.base.appendingPathComponent(mac + "/data/project-folders"), kind: .projectFolders,
                                              roots: CloudFolderRoots(many: roots ?? [key: project(mac)]),
                                              everyMacUnderstands: { true }, freeDisk: { 500_000_000_000 }, now: { clock.ms })
            await made.setDeleteRuleAnnounced { _ in false }
            try await made.markCloudRead()
            return made
        }
        func write(_ mac: String, _ path: String, _ data: Data) throws {
            let url = project(mac).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(f.clock.ms) / 1000)], ofItemAtPath: url.path)
        }
        func data(_ mac: String, _ path: String) -> Data? { try? Data(contentsOf: project(mac).appendingPathComponent(path)) }
    }

    @Test func everyFolderOfAProjectArrivesInThatProjectsFolderOnTheOtherMac() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let t = Two(f: f)
        let picture = Data([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 1, 2, 3])
        let large = Data((0..<200_000).map { UInt8($0 % 251) })   // several parts
        try t.write("a", "team/cloud/card.md", Data("seat card\n".utf8))
        try t.write("a", "notes/shot.png", picture)
        try t.write("a", "logs/run/big.bin", large)
        try t.write("a", "notes/.env", Data("KEY=secret-value\n".utf8))
        // Left out: built, checked out, scratch.
        try t.write("a", "code/app/main.swift", Data("code\n".utf8))
        try t.write("a", "notes/web/node_modules/p/index.js", Data("pkg\n".utf8))
        try t.write("a", "tools/repo/.git/HEAD", Data("ref\n".utf8))
        try t.write("a", "tools/repo/readme.md", Data("checkout\n".utf8))
        try t.write("a", "notes/.DS_Store", Data([0, 1]))
        let a = try await t.owner("a", device: f.deviceA), b = try await t.owner("b", device: f.deviceB)
        try await f.settle(a)
        var cursor: String?
        let sent = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(!sent.isEmpty)
        try await b.look()
        #expect(t.data("b", "team/cloud/card.md") == Data("seat card\n".utf8))
        #expect(t.data("b", "notes/shot.png") == picture)
        #expect(t.data("b", "logs/run/big.bin") == large)
        #expect(t.data("b", "notes/.env") == Data("KEY=secret-value\n".utf8))
        for path in ["code/app/main.swift", "notes/web/node_modules/p/index.js", "tools/repo/readme.md", "notes/.DS_Store"] {
            #expect(t.data("b", path) == nil, "\(path)")
        }
        // No path of either Mac travels: only the project key and the path inside the project.
        for op in sent { #expect(!op.source.recordId.contains("Deck Dev") && !op.source.recordId.contains("/Work/")) }
    }

    @Test func anEditComesBackAndAFileOfAProjectNotOnThisMacWaits() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let t = Two(f: f)
        try t.write("a", "notes/plan.md", Data("one\n".utf8))
        let a = try await t.owner("a", device: f.deviceA)
        // Mac b does not have the project yet.
        let b = try await t.owner("b", device: f.deviceB, roots: [:])
        try await f.settle(a)
        var toB: String?, toA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &toB)
        try await b.look()
        #expect(t.data("b", "notes/plan.md") == nil)
        // The project appears on b: its file is placed at the next look.
        await b.setRoots([t.key: t.project("b")])
        try await b.look()
        #expect(t.data("b", "notes/plan.md") == Data("one\n".utf8))
        // An edit on b travels back to a; a's older file is replaced (and kept as a version).
        f.clock.advance(60_000)
        try t.write("b", "notes/plan.md", Data("two\n".utf8))
        try await f.settle(b)
        try await f.send(b, device: f.deviceB, to: a, cursor: &toA)
        try await a.look()
        #expect(t.data("a", "notes/plan.md") == Data("two\n".utf8))
    }

    @Test func aFirstUploadGoesInStepsAndNeverWaitsForADayCap() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let t = Two(f: f)
        #expect(CloudFileKind.projectFolders.dailySendBytes == nil && !CloudFileKind.projectFolders.obeysRoomFloor)
        #expect(CloudFileKind.projectFolders.maximumFileBytes == .max)
        for index in 0..<5 { try t.write("a", "notes/n\(index).md", Data("note \(index)\n".utf8)) }
        let a = try await t.owner("a", device: f.deviceA)
        try await f.settle(a)
        let journal = try await CloudFolderFixture.journal(a)
        #expect(Set(journal.compactMap { op -> String? in
            let id = op.source.recordId
            return id.hasPrefix("file/projects/") ? String(id.dropFirst("file/projects/".count)) : nil
        }) == Set((0..<5).map { t.key + "/notes/n\($0).md" }))
    }

    @Test func inAProjectThatIsACodeCheckoutTrackedFilesStayAndUntrackedOnesTravel() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let t = Two(f: f)
        try FileManager.default.createDirectory(at: t.project("a"), withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", t.project("a").path, "-c", "user.name=t", "-c", "user.email=t@example.invalid"] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments)")
        }
        try t.write("a", "src/app.ts", Data("code\n".utf8))
        try t.write("a", "docs/guide.md", Data("in git\n".utf8))
        try git(["init", "-q"])
        try git(["add", "src/app.ts", "docs/guide.md"])
        try git(["commit", "-q", "-m", "x"])
        // Not in git: they travel.
        try t.write("a", "src/.env", Data("LOCAL=1\n".utf8))
        try t.write("a", "docs/evidence.png", Data([0x89, 0x50, 0, 1]))
        try t.write("a", "storage/upload.pdf", Data("%PDF\n".utf8))
        try t.write("a", "src/web/node_modules/p/index.js", Data("pkg\n".utf8))
        let a = try await t.owner("a", device: f.deviceA)
        try await f.settle(a)
        let journal = try await CloudFolderFixture.journal(a)
        let paths = Set(journal.compactMap { op -> String? in
            let id = op.source.recordId
            return id.hasPrefix("file/projects/" + t.key + "/") ? String(id.dropFirst(("file/projects/" + t.key + "/").count)) : nil
        })
        #expect(paths == ["src/.env", "docs/evidence.png", "storage/upload.pdf"])
    }
}
