import Foundation
import Testing
@testable import TerminalDeckNative
import TerminalDeckNativeCore

/// Exercise the production drain without starting an app, engine or window.
@MainActor
struct BackgroundPopout21Tests {
    @Test func inactiveToolPagesOpenBeforeAnyActivationAndTwoObserversOpenEachOnce() throws {
        let fixture = try RequestFixture()
        let pages = [ScreenRef(kind: .panel, id: "tasks"), ScreenRef(kind: .panel, id: "agents-all"),
                     ScreenRef(kind: .panel, id: "hoot", isHoot: true)]
        for ref in pages { fixture.queue(ref, bringForward: false) }

        fixture.observe() // main scene
        fixture.observe() // screen scene sees the same request counter

        #expect(!fixture.personActing)
        #expect(fixture.opened == pages)
        #expect(fixture.prepared == pages)
        #expect(fixture.gateCalls == 0)
        #expect(fixture.pending.isEmpty)
        #expect(pages.allSatisfy(fixture.store.keepsCurrentFocus))
    }

    @Test func inactiveMixedBatchOpensToolPageAndDefersPersonScreen() throws {
        let fixture = try RequestFixture()
        let person = ScreenRef(kind: .session, id: "person-session")
        let tool = ScreenRef(kind: .panel, id: "tasks")
        fixture.queue(person, bringForward: true)
        fixture.queue(tool, bringForward: false)

        fixture.observe()
        fixture.observe()
        #expect(fixture.opened == [tool])
        #expect(fixture.prepared == [tool])
        #expect(fixture.gateCalls == 1)

        fixture.personReturns()
        #expect(fixture.opened == [tool, person])
        #expect(fixture.prepared == fixture.opened)
        fixture.personReturns()
        #expect(fixture.opened == [tool, person])
    }

    @Test func replacedActivationCallbackRetainsEarlierBatchesAndDeduplicatesScreens() throws {
        let fixture = try RequestFixture()
        let first = ScreenRef(kind: .session, id: "first-session")
        let second = ScreenRef(kind: .browser, id: "second-browser")
        fixture.queue(first, bringForward: true)
        fixture.observe()
        fixture.queue(second, bringForward: true)
        fixture.queue(first, bringForward: true)
        fixture.observe()

        #expect(fixture.opened.isEmpty)
        #expect(fixture.gateCalls == 2)
        fixture.personReturns()
        #expect(fixture.opened == [first, second])
        #expect(fixture.prepared == fixture.opened)
    }

    @Test func toolRequestSupersedesDeferredPersonOpeningOfTheSamePage() throws {
        let fixture = try RequestFixture()
        let page = ScreenRef(kind: .panel, id: "agents-all")
        fixture.queue(page, bringForward: true)
        fixture.observe()
        #expect(fixture.opened.isEmpty)

        fixture.queue(page, bringForward: false)
        fixture.observe()
        #expect(fixture.opened == [page])
        fixture.personReturns()
        #expect(fixture.opened == [page])
        #expect(fixture.prepared == [page])
    }
}

@MainActor
private final class RequestFixture {
    let store: NativePageWindows
    private let drain = NativeScreenRequestDrain()
    private let defaults: UserDefaults
    private let suiteName: String
    private var deferred: (@MainActor () -> Void)?
    var pending: [ScreenRef] = []
    var opened: [ScreenRef] = []
    var prepared: [ScreenRef] = []
    var personActing = false
    var gateCalls = 0

    init() throws {
        suiteName = "background-popout21-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = NativePageWindows(defaults: defaults)
    }

    func queue(_ ref: ScreenRef, bringForward: Bool) {
        store.requested(ref, bringForward: bringForward)
        if !pending.contains(ref) { pending.append(ref) }
    }

    func observe() {
        drain.drain(takePending: {
            let requests = self.pending
            self.pending = []
            return requests
        }, keepingCurrentFocus: store.keepsCurrentFocus, prepare: { self.prepared.append($0) },
        whenPersonActs: { action in
            self.gateCalls += 1
            if self.personActing { action() }
            else { self.deferred = action } // NativeFront keeps the newest same-key callback.
        }, open: { self.opened.append($0) })
    }

    func personReturns() {
        personActing = true
        let action = deferred
        deferred = nil
        action?()
    }

    isolated deinit { defaults.removePersistentDomain(forName: suiteName) }
}
