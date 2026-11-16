import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud boot files: the only reads and writes in a person's folder")
struct CloudBootFilesDiskTests {
    typealias F = CloudBootFilesFixture
    typealias Disk = BackendCloudBootFilesDisk

    func hash(_ text: String) -> String { BackendCloudBrainMemoryHash.bytes(Data(text.utf8)) }
    func leftovers(_ f: F, _ path: String) -> [String] { f.listing(path).filter { $0.contains(".td-cloud-") } }

    @Test func aNewFileIsCreatedOnlyWhereNothingHoldsTheName() throws {
        let f = try F(); defer { f.close() }
        let root = try f.folder("r")
        try Disk.create(root: root, relative: "a/b/new.md", bytes: Data("one\n".utf8))
        #expect(f.text("r/a/b/new.md") == "one\n")
        #expect(f.mode("r/a/b/new.md") & 0o111 == 0)
        // The same name again, a twin of the name, a twin of a folder on the way.
        #expect(throws: Disk.Stop(reason: "changed")) { try Disk.create(root: root, relative: "a/b/new.md", bytes: Data("two\n".utf8)) }
        #expect(throws: Disk.Stop(reason: "twin")) { try Disk.create(root: root, relative: "a/b/NEW.md", bytes: Data("two\n".utf8)) }
        #expect(throws: Disk.Stop(reason: "twin")) { try Disk.create(root: root, relative: "A/b/other.md", bytes: Data("two\n".utf8)) }
        #expect(f.text("r/a/b/new.md") == "one\n")
        // A link under the name (even one that points nowhere) holds the name: nothing is written through it.
        try FileManager.default.createSymbolicLink(atPath: f.url("r/a/b/dangling.md").path, withDestinationPath: f.url("elsewhere.md").path)
        #expect(throws: Disk.Stop(reason: "changed")) { try Disk.create(root: root, relative: "a/b/dangling.md", bytes: Data("x\n".utf8)) }
        #expect(!f.exists("elsewhere.md"))
        #expect(f.files("r") == ["a/b/new.md"])
        #expect(leftovers(f, "r").isEmpty)
    }

    @Test func anExistingFileIsReplacedOnlyWhenItHoldsExactlyWhatWasExpected() throws {
        let f = try F(); defer { f.close() }
        let root = try f.folder("r")
        try f.write("r/x.md", "old\n")
        #expect(throws: Disk.Stop(reason: "changed")) { try Disk.replace(root: root, relative: "x.md", bytes: Data("new\n".utf8), expecting: hash("something else\n")) }
        #expect(f.text("r/x.md") == "old\n")
        let replaced = try Disk.replace(root: root, relative: "x.md", bytes: Data("new\n".utf8), expecting: hash("old\n"))
        #expect(replaced == Data("old\n".utf8))
        #expect(f.text("r/x.md") == "new\n")
        #expect(f.mode("r/x.md") & 0o111 == 0)
        // Nothing there: nothing is created by a replace.
        #expect(throws: Disk.Stop(reason: "changed")) { try Disk.replace(root: root, relative: "missing.md", bytes: Data("n\n".utf8), expecting: hash("n\n")) }
        #expect(!f.exists("r/missing.md"))
        // A link under the name stays a link, and its target is not touched.
        try f.write("target.md", "target\n")
        try FileManager.default.createSymbolicLink(atPath: f.url("r/link.md").path, withDestinationPath: f.url("target.md").path)
        #expect(throws: Disk.Stop(reason: "changed")) { try Disk.replace(root: root, relative: "link.md", bytes: Data("x\n".utf8), expecting: hash("target\n")) }
        #expect(f.text("target.md") == "target\n")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: f.url("r/link.md").path)
        #expect(destination == f.url("target.md").path)
        #expect(leftovers(f, "r").isEmpty)
    }

    @Test func noLinkIsFollowedBelowTheFolderButTheFolderItselfMayBeReachedThroughThePersonsOwnLink() throws {
        let f = try F(); defer { f.close() }
        let root = try f.folder("r")
        try f.write("outside/x.md", "outside\n")
        try FileManager.default.createSymbolicLink(atPath: f.url("r/dir").path, withDestinationPath: f.url("outside").path)
        #expect(Disk.read(root: root, relative: "dir/x.md") == .blocked("link"))
        #expect(throws: Disk.Stop(reason: "link")) { try Disk.create(root: root, relative: "dir/new.md", bytes: Data("n\n".utf8)) }
        #expect(throws: Disk.Stop(reason: "link")) { try Disk.replace(root: root, relative: "dir/x.md", bytes: Data("n\n".utf8), expecting: hash("outside\n")) }
        #expect(f.files("outside") == ["x.md"])
        #expect(f.text("outside/x.md") == "outside\n")
        // The chosen folder may itself be named through a link (as `~/Projects/<name>` is on the owner's Mac).
        try FileManager.default.createSymbolicLink(atPath: f.url("alias").path, withDestinationPath: root.path)
        try Disk.create(root: f.url("alias"), relative: "via.md", bytes: Data("via\n".utf8))
        #expect(f.text("r/via.md") == "via\n")
        #expect(Disk.read(root: f.url("alias"), relative: "via.md") == .file(Data("via\n".utf8)))
    }

    @Test func aReadSeesOnlyAPlainFileUnderItsExactName() throws {
        let f = try F(); defer { f.close() }
        let root = try f.folder("r")
        try f.write("r/Name.md", "text\n")
        #expect(Disk.read(root: root, relative: "Name.md") == .file(Data("text\n".utf8)))
        #expect(Disk.read(root: root, relative: "name.md") == .blocked("twin"))
        #expect(Disk.read(root: root, relative: "missing.md") == .absent)
        #expect(Disk.read(root: root, relative: "no/such/folder.md") == .absent)
        #expect(Disk.read(root: root, relative: "Name.md/inside.md") == .blocked("in-the-way"))
        try f.folder("r/folder.md")
        #expect(Disk.read(root: root, relative: "folder.md") == .blocked("in-the-way"))
        try f.write("r/big.md", data: Data(repeating: 0x61, count: CloudBootFilesFormat.maximumFileBytes + 1))
        #expect(Disk.read(root: root, relative: "big.md") == .blocked("too-large"))
        try FileManager.default.linkItem(at: f.url("r/Name.md"), to: f.url("r/second-name.md"))
        #expect(Disk.read(root: root, relative: "second-name.md") == .blocked("link"))
        #expect(Disk.read(root: f.url("not-there"), relative: "x.md") == .blocked("unreachable"))
    }
}
