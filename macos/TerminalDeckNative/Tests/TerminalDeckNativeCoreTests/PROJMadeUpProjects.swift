import Foundation
import Testing
import XCTest
import TerminalDeckNativeCore

/// A made-up project list for tests (11 Oct). The app has no built-in projects any more: the person's
/// registered projects are the live list. A test that sorts something by its folder therefore says which
/// projects exist. The folders are made up; no folder of a real Mac is used.
enum PROJMadeUp {
    static let projects: [PROJProject] = [
        .init(id: "imatch", name: "iMatch", folders: ["/work/imatch"], colour: "blue"),
        .init(id: "crm", name: "CRM", folders: ["/work/crm"], colour: "purple"),
        PROJProjects.independent,
    ]
    /// The saved registry file of an existing install, the same shape as one written by the app.
    static let registryJSON = #"{"projects":[{"id":"imatch","name":"iMatch","folders":["/work/imatch"],"icon":"folder","colour":"blue"},{"id":"crm","name":"CRM","folders":["/work/crm"],"icon":"folder","colour":"purple"},{"id":"independent","name":"Independent","folders":[],"icon":"square.grid.2x2","colour":"graphite"}]}"#
    /// Writes an existing install's registry at `file` (made-up folders) and returns `file`.
    @discardableResult static func seed(_ file: URL) -> URL {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { try? Data(registryJSON.utf8).write(to: file) }
        return file
    }
    static func with<T>(_ body: () async throws -> T) async rethrows -> T {
        try await PROJRegisteredProjects.$scoped.withValue(projects, operation: body)
    }
    static func with<T>(_ body: () throws -> T) rethrows -> T {
        try PROJRegisteredProjects.$scoped.withValue(projects, operation: body)
    }
}

/// `@Suite(.madeUpProjects)` or `@Test(.madeUpProjects)`: the made-up list is the project list for that test.
struct PROJMadeUpProjectsTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await PROJRegisteredProjects.$scoped.withValue(PROJMadeUp.projects) { try await function() }
    }
}
extension Trait where Self == PROJMadeUpProjectsTrait {
    static var madeUpProjects: Self { .init() }
}

/// An XCTest class whose tests see the made-up list.
class PROJMadeUpTestCase: XCTestCase {
    override func invokeTest() {
        PROJRegisteredProjects.$scoped.withValue(PROJMadeUp.projects) { super.invokeTest() }
    }
}
