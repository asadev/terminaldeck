import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Actual project service, in-memory state, owned temporary folders, and a
/// recording presenter. No app/window, running host or real data is involved.
final class BackendProjectFocus21Tests: XCTestCase {
    private actor Presenter {
        private var paths: [String] = []
        func show(_ path: String) -> Bool { paths.append(path); return true }
        func calls() -> [String] { paths }
    }

    private struct Fixture {
        let root: URL
        let folder: URL
        let store: NativeStateStore
        let presenter: Presenter
        let projects: BackendProjectService
        func context(_ caller: NativeRPCContext.Caller) -> NativeRPCContext {
            .init(caller: caller, ownerID: caller == .page ? "core-call:fixture" : "project-focus-fixture",
                  capabilities: ["files.read", "projects.read", "projects.write"])
        }
        func dispose() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backend-project-focus21-" + UUID().uuidString + ".noindex")
            .resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = NativeStateStore(), presenter = Presenter()
        let authority = BackendFilesystemAuthority(scope: { _ in .init(readRoots: [folder], writeRoots: [folder]) })
        let projects = try BackendProjectService(store: store, files: .init(authority: authority), home: root.path,
            appDataRoot: root.appendingPathComponent("app-data"), liveSessions: { [] },
            showInWindow: { await presenter.show($0) })
        return Fixture(root: root, folder: folder, store: store, presenter: presenter, projects: projects)
    }

    func testCoreCallAddsAndReaddsFolderWithoutDispatchingWindowSelection() async throws {
        let f = try fixture(); defer { f.dispose() }
        let first = try await f.projects.add(path: f.folder.path, context: f.context(.page))
        let again = try await f.projects.add(path: f.folder.path, context: f.context(.page))
        let saved = await f.projects.list(), shown = await f.presenter.calls()
        XCTAssertEqual(first["already"], .bool(false))
        XCTAssertEqual(again["already"], .bool(true))
        XCTAssertEqual(first["inWindow"], .bool(false))
        XCTAssertEqual(again["inWindow"], .bool(false))
        XCTAssertEqual(saved.elements?.compactMap { $0["path"].string }, [f.folder.path])
        XCTAssertEqual(shown, [])
    }

    func testNativeWindowStillPresentsNewAndAlreadyOpenFolders() async throws {
        let f = try fixture(); defer { f.dispose() }
        let first = try await f.projects.add(path: f.folder.path, context: f.context(.nativeApp))
        let again = try await f.projects.add(path: f.folder.path, context: f.context(.nativeApp))
        let saved = await f.projects.list(), shown = await f.presenter.calls()
        XCTAssertEqual(first["inWindow"], .bool(true))
        XCTAssertEqual(again["inWindow"], .bool(true))
        XCTAssertEqual(again["already"], .bool(true))
        XCTAssertEqual(saved.elements?.count, 1)
        XCTAssertEqual(shown, [f.folder.path, f.folder.path])
    }

    func testOtherBackgroundCallersAlsoSaveWithoutPresenting() async throws {
        let f = try fixture(); defer { f.dispose() }
        for caller in [NativeRPCContext.Caller.internalEngine, .pairedDevice] {
            let result = try await f.projects.add(path: f.folder.path, context: f.context(caller))
            XCTAssertEqual(result["inWindow"], .bool(false))
        }
        let saved = await f.projects.list(), shown = await f.presenter.calls()
        XCTAssertEqual(saved.elements?.count, 1)
        XCTAssertEqual(shown, [])
    }

    func testUnownedFolderStillFailsBeforeSavingOrPresenting() async throws {
        let f = try fixture(); defer { f.dispose() }
        let outsideGrant = f.root.appendingPathComponent("outside-grant")
        try FileManager.default.createDirectory(at: outsideGrant, withIntermediateDirectories: true)
        do {
            _ = try await f.projects.add(path: outsideGrant.path, context: f.context(.page))
            XCTFail("A core caller must retain its existing folder limits")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "access-denied")
        }
        let saved = await f.projects.list(), shown = await f.presenter.calls()
        XCTAssertEqual(saved.elements?.count, 0)
        XCTAssertEqual(shown, [])
    }
}
