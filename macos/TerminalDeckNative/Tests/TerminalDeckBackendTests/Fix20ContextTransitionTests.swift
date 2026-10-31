import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class Fix20ContextTransitionTests: XCTestCase {
    func testChangingAIWithdrawsThePreviousAIsMeasuredContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-fix20-transition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake.py")
        try Data(#"""
        import sys,json
        def send(value):
            print(json.dumps(value),flush=True)
        for line in sys.stdin:
            row=json.loads(line); method=row.get('method'); ident=row.get('id')
            if method=='initialize': send({'id':ident,'result':{}})
            elif method=='thread/start': send({'id':ident,'result':{'thread':{'id':'thread'},'model':'fixture'}})
            elif method=='skills/list': send({'id':ident,'result':{'data':[]}})
            elif method=='turn/start':
                send({'id':ident,'result':{'turn':{'id':'turn'}}})
                send({'method':'turn/started','params':{'threadId':'thread','turn':{'id':'turn'}}})
                send({'method':'thread/tokenUsage/updated','params':{'threadId':'thread','tokenUsage':{'last':{'totalTokens':100},'modelContextWindow':1000}}})
                send({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'completed'}}})
        """#.utf8).write(to: script)
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"), provider: .codex)
        try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", script.path], cwd: root.path,
            environment: [:], setup: .init(cwd: root.path)))
        try await store.initialize()
        _ = try await store.say("fixture")
        var snapshot = await store.snapshot()
        for _ in 0..<200 where snapshot["busy"].bool == true || snapshot["contextReading"]["tokens"].number == nil {
            try await Task.sleep(for: .milliseconds(10)); snapshot = await store.snapshot()
        }
        XCTAssertEqual(snapshot["contextReading"]["tokens"].number, 100)
        XCTAssertEqual(snapshot["contextReading"]["window"].number, 1000)
        try await store.rebindProvider(.gemini)
        let changed = await store.snapshot()
        XCTAssertTrue(changed["contextReading"].isNullish)
        XCTAssertEqual(changed["provider"].string, "gemini")
        await store.stop()
    }
}
