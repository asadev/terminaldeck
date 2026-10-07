import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendFoundationTestsConfinePlan: XCTestCase {
    private struct Fixture {
        let root: URL
        init() throws {
            // The planner resolves with realpath (plan.ts resolver.real): use the kernel form here too.
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("foundation-confine-plan-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            root = URL(fileURLWithPath: BackendMacConfinement.kernelPath(made.path))
        }
        var owner: String { root.appendingPathComponent("owner").path }
        var folder: String { root.appendingPathComponent("owner/Projects/app").path }
        var home: String { root.appendingPathComponent("data/device-home/abc").path }
        func directory(_ relative: String) throws -> String {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        func plan(path: String = "/usr/bin:/bin", writable: [String] = [], files: [String] = [], projects: [String] = []) throws -> BackendMacConfinement.Plan {
            try BackendMacConfinement.plan(folder: folder, home: home, accountHome: owner, path: path, writable: writable, files: files, projects: projects)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    // plan.test.ts:32 through the actual planner's project/ancestor guard.
    func testSharedPrefixSiblingIsNotInsideTheGrantedFolder() throws {
        let f = try Fixture(); defer { f.clean() }
        let sibling = try f.directory("owner/Projects-old"), ancestor = try f.directory("owner/Projects")
        let plan = try f.plan(projects: [sibling, ancestor])
        XCTAssertEqual(plan.readOnlyProjects, [sibling])
    }
    // plan.test.ts:39, through canonicalization and grant deduplication.
    func testFolderCountsAsInsideItselfWithTrailingSlash() throws {
        let f = try Fixture(); defer { f.clean() }; let path = try f.directory("owner/Projects/app")
        let plan = try f.plan(writable: [path + "/"])
        XCTAssertEqual(plan.writable.filter { $0 == path }.count, 1)
    }
    // plan.test.ts:44 Mac clause. Synthetic nonexistent paths deliberately
    // avoid depending on whether the host volume folds filename case.
    func testPOSIXContainmentDoesNotFoldCase() throws {
        let prefix = "/foundation-case-" + UUID().uuidString, upper = prefix + "/Users/Asad/proj", lower = prefix + "/users/asad"
        let plan = try BackendMacConfinement.plan(folder: upper, home: lower, accountHome: prefix + "/owner", path: "", writable: [], files: [], projects: [])
        XCTAssertEqual(Set(plan.writable), Set([upper, lower]))
    }
    // plan.test.ts:53 via plan's real collapse (no test-side copy of collapse).
    func testCoveredWritableDirectoryIsCollapsed() throws {
        let plan = try BackendMacConfinement.plan(folder: "/opt", home: "/opt/homebrew", accountHome: "/foundation-account-home", path: "", writable: ["/usr"], files: [], projects: [])
        XCTAssertEqual(plan.writable, ["/opt", "/usr"])
    }
    // plan.test.ts:57
    func testWritableDirectoriesSharingOnlyAPrefixRemainSeparate() throws {
        let plan = try BackendMacConfinement.plan(folder: "/a/b", home: "/a/bc", accountHome: "/foundation-account-home", path: "", writable: [], files: [], projects: [])
        XCTAssertEqual(plan.writable, ["/a/b", "/a/bc"])
    }
    // plan.test.ts:65
    func testToolRootsAlreadyCoveredBySystemRootsAreNotAdded() throws {
        let f = try Fixture(); defer { f.clean() }
        let plan = try f.plan(path: "/usr/bin:/bin:/opt/homebrew/bin")
        XCTAssertEqual(Set(plan.readable), Set(BackendMacConfinement.systemReadRoots))
    }
    // plan.test.ts:70
    func testToolBinGrantsItsLibraryPrefix() throws {
        let f = try Fixture(); defer { f.clean() }; let bin = try f.directory("owner/.nvm/versions/node/v22/bin")
        let plan = try f.plan(path: bin)
        XCTAssertTrue(plan.readable.contains(URL(fileURLWithPath: bin).deletingLastPathComponent().path))
        XCTAssertFalse(plan.readable.contains(bin))
    }
    // plan.test.ts:78
    func testHomeBinDoesNotGrantTheWholeAccountHome() throws {
        let f = try Fixture(); defer { f.clean() }; let bin = try f.directory("owner/bin")
        let plan = try f.plan(path: bin)
        XCTAssertTrue(plan.readable.contains(bin)); XCTAssertFalse(plan.readable.contains(f.owner))
    }
    // plan.test.ts:85
    func testToolPrefixCannotExposeSiblingsOfGrantedProject() throws {
        let f = try Fixture(); defer { f.clean() }; let bin = try f.directory("owner/Projects/app/node_modules/.bin")
        let plan = try f.plan(path: bin)
        XCTAssertFalse(plan.readable.contains(f.root.appendingPathComponent("owner/Projects").path))
    }
    // plan.test.ts:93
    func testMissingPATHDirectoriesAreDropped() throws {
        let f = try Fixture(); defer { f.clean() }; let bin = try f.directory("owner/here/bin"), gone = f.root.appendingPathComponent("owner/gone/bin").path
        let plan = try f.plan(path: gone + ":" + bin)
        let extra = plan.readable.filter { !BackendMacConfinement.systemReadRoots.contains($0) }
        XCTAssertEqual(extra, [f.root.appendingPathComponent("owner/here").path])
    }
    // plan.test.ts:115
    func testOnlyGrantedFolderAndDeviceHomeAreWritable() throws {
        let f = try Fixture(); defer { f.clean() }; let plan = try f.plan()
        XCTAssertEqual(plan.writable, [f.folder, f.home])
    }
    // plan.test.ts:120
    func testAccountHomeIsNeverAGrant() throws {
        let f = try Fixture(); defer { f.clean() }; let bin = try f.directory("owner/bin")
        let plan = try f.plan(path: bin + ":/usr/bin")
        XCTAssertFalse((plan.writable + plan.readable).contains(f.owner))
        for root in plan.writable + plan.readable { XCTAssertFalse(f.owner == root || f.owner.hasPrefix(root + "/")) }
    }
    // plan.test.ts:127
    func testGrantedFolderSymlinkResolvesToItsRealDirectory() throws {
        let f = try Fixture(); defer { f.clean() }; let actual = try f.directory("work-real"), link = f.root.appendingPathComponent("work-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: actual))
        let plan = try BackendMacConfinement.plan(folder: link.path, home: f.home, accountHome: f.owner, path: "/usr/bin:/bin", writable: [], files: [], projects: [])
        XCTAssertTrue(plan.writable.contains(actual)); XCTAssertFalse(plan.writable.contains(link.path))
    }
    // plan.test.ts:140
    func testAgentConfigIsWritableOnlyWhenNamed() throws {
        let f = try Fixture(); defer { f.clean() }; let config = f.root.appendingPathComponent("data/profiles/work").path
        XCTAssertFalse(try f.plan().writable.contains(config)); XCTAssertTrue(try f.plan(writable: [config]).writable.contains(config))
    }
    // plan.test.ts:146
    func testHelperIsAFileGrantWithItsParentClosed() throws {
        let f = try Fixture(); defer { f.clean() }; let file = f.root.appendingPathComponent("data/guest-git/askpass.sh"), parent = file.deletingLastPathComponent().path
        let plan = try f.plan(files: [file.path])
        XCTAssertEqual(plan.readableFiles, [file.path]); XCTAssertFalse(plan.readable.contains(parent)); XCTAssertFalse(plan.writable.contains(parent))
    }
    // plan.test.ts:155
    func testAlreadyCoveredFileNeedsNoAdditionalLiteralRule() throws {
        let f = try Fixture(); defer { f.clean() }; XCTAssertEqual(try f.plan(files: ["/usr/bin/git"]).readableFiles, [])
    }
    // plan.test.ts:160
    func testContextDocumentsDoNotOpenAppStorageDirectory() throws {
        let f = try Fixture(); defer { f.clean() }
        let docs = ["INDEX.md", "browser-windows.md"].map { f.root.appendingPathComponent("data/context/" + $0).path }
        let plan = try f.plan(files: docs)
        XCTAssertEqual(plan.readableFiles, docs)
        XCTAssertFalse(plan.readable.contains(f.root.appendingPathComponent("data/context").path)); XCTAssertFalse(plan.readable.contains(f.root.appendingPathComponent("data").path))
    }
    // plan.test.ts:192
    func testReadOnlyProjectsNeverBecomeWritable() throws {
        let f = try Fixture(); defer { f.clean() }; let one = try f.directory("owner/Projects/one"), two = try f.directory("owner/Projects/two")
        let plan = try f.plan(projects: [one, two])
        for project in [one, two] { XCTAssertTrue(plan.readable.contains(project)); XCTAssertFalse(plan.writable.contains(project)) }
        XCTAssertEqual(plan.writable, [f.folder, f.home])
    }
    // plan.test.ts:201
    func testProjectListIsSeparateFromSystemRoots() throws {
        let f = try Fixture(); defer { f.clean() }; let one = try f.directory("owner/Projects/one"), two = try f.directory("owner/Projects/two")
        XCTAssertEqual(try f.plan(projects: [one, two]).readOnlyProjects, [one, two])
    }
    // plan.test.ts:205 uses actual generated rules; source public readExclusions
    // shape/why metadata remains an additional API gap.
    func testEachReadOnlyProjectReceivesCredentialExclusions() throws {
        let f = try Fixture(); defer { f.clean() }; let one = try f.directory("owner/Projects/one"), two = try f.directory("owner/Projects/two")
        let text = BackendMacConfinement.profile(try f.plan(projects: [one, two]))
        for project in [one, two] { XCTAssertTrue(text.contains("(deny file-read* (regex #\"^" + project)) }
    }
    // plan.test.ts:213
    func testNoProjectMeansNoReadOnlyGrantOrCredentialExclusion() throws {
        let f = try Fixture(); defer { f.clean() }; let plan = try f.plan()
        XCTAssertEqual(plan.readOnlyProjects, []); XCTAssertFalse(BackendMacConfinement.profile(plan).contains("(deny file-read* (regex"))
    }
    // plan.test.ts:219
    func testAccountHomeIsRejectedAsReadOnlyProject() throws {
        let f = try Fixture(); defer { f.clean() }; _ = try f.directory("owner")
        XCTAssertEqual(try f.plan(projects: [f.owner]).readOnlyProjects, [])
    }
    // plan.test.ts:228
    func testFilesystemRootIsRejectedAsReadOnlyProject() throws {
        let f = try Fixture(); defer { f.clean() }; XCTAssertEqual(try f.plan(projects: ["/"]).readOnlyProjects, [])
    }
    // plan.test.ts:232
    func testProjectCannotContainAppStorage() throws {
        let f = try Fixture(); defer { f.clean() }; let data = try f.directory("data")
        XCTAssertEqual(try f.plan(projects: [data]).readOnlyProjects, [])
    }
    // plan.test.ts:243
    func testRemovedProjectIsNotGranted() throws {
        let f = try Fixture(); defer { f.clean() }; XCTAssertEqual(try f.plan(projects: [f.root.appendingPathComponent("owner/Projects/gone").path]).readOnlyProjects, [])
    }
    // plan.test.ts:250
    func testNestedProjectsCollapseToOneGrant() throws {
        let f = try Fixture(); defer { f.clean() }; let one = try f.directory("owner/Projects/one"), nested = try f.directory("owner/Projects/one/packages/ui")
        XCTAssertEqual(try f.plan(projects: [one, nested]).readOnlyProjects, [one])
    }
    // plan.test.ts:270
    func testPATHAboveReadOnlyProjectCannotExposeSiblingProjects() throws {
        let f = try Fixture(); defer { f.clean() }; let one = try f.directory("owner/Projects/one"), bin = try f.directory("owner/Projects/bin")
        let plan = try f.plan(path: bin + ":/usr/bin", projects: [one])
        XCTAssertFalse(plan.readable.contains(f.root.appendingPathComponent("owner/Projects").path))
    }
}
