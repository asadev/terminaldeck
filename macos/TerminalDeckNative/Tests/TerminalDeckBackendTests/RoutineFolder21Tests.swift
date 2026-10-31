import Foundation
import XCTest
@testable import TerminalDeckBackend

@MainActor
final class RoutineFolder21Tests: XCTestCase {
    func testKnownProjectAndChildArmAndRunThroughEngine() async throws {
        let project = BackendRoutinesTestRig.project
        let rig = try await BackendRoutinesTestRig.make(allow: {
            BackendRoutinesFolderPolicy.problem($0, allowedRoots: [project])
        })
        addTeardownBlock { await rig.clean() }
        try rig.write("project", folder: project)
        try rig.write("child", folder: project + "/Sources")
        await rig.engine.reload()
        for id in ["project", "child"] {
            let view = await rig.engine.get(id)
            XCTAssertNotEqual(view?.state, "unarmed")
            XCTAssertNil(view?.reason)
            let result = await rig.engine.runNow(id)
            XCTAssertTrue(result.started, result.reason ?? "")
        }
        await BackendRoutinesTestRig.settle()
        let calls = await rig.runner.calls
        XCTAssertEqual(Set(calls.map { $0.routine.id }), ["project", "child"])
        XCTAssertTrue(calls.allSatisfy { !$0.attended })
    }

    func testHootRootArmsWithoutOpeningUnrelatedFolders() async throws {
        let hoot = "/tmp/td-routines-hoot"
        let rig = try await BackendRoutinesTestRig.make(allow: {
            BackendRoutinesFolderPolicy.problem($0, allowedRoots: [BackendRoutinesTestRig.project, hoot])
        })
        addTeardownBlock { await rig.clean() }
        try rig.write("hoot", folder: hoot + "/memory")
        try rig.write("outside", folder: "/tmp/ungranted-routines-project")
        await rig.engine.reload()
        let allowed = await rig.engine.runNow("hoot")
        let denied = await rig.engine.runNow("outside")
        XCTAssertTrue(allowed.started, allowed.reason ?? "")
        XCTAssertFalse(denied.started)
        XCTAssertTrue(denied.reason?.contains("outside the known projects and Hoot folder") == true)
        await BackendRoutinesTestRig.settle()
        let calls = await rig.runner.calls
        XCTAssertEqual(calls.map { $0.routine.id }, ["hoot"])
    }

    func testSiblingPrefixAndParentTraversalStayUnarmed() async throws {
        let project = BackendRoutinesTestRig.project
        let rig = try await BackendRoutinesTestRig.make(allow: {
            BackendRoutinesFolderPolicy.problem($0, allowedRoots: [project])
        })
        addTeardownBlock { await rig.clean() }
        try rig.write("sibling", folder: project + "-outside")
        try rig.write("parent", folder: project + "/../outside")
        await rig.engine.reload()
        for id in ["sibling", "parent"] {
            let view = await rig.engine.get(id)
            let result = await rig.engine.runNow(id)
            XCTAssertEqual(view?.state, "unarmed")
            XCTAssertFalse(result.started)
            XCTAssertTrue(result.reason?.contains("Add its project") == true)
        }
        let calls = await rig.runner.calls
        XCTAssertTrue(calls.isEmpty)
    }
}
