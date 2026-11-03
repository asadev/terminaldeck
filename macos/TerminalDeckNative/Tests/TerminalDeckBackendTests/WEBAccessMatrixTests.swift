import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Inventory read from td-web/src/features plus app/state.ts, wire/connection.ts,
/// protocol-client.ts hello and the active credential-refusal helper (1 Nov 2026).
/// These are the coarse message gate expectations. Session visibility, device
/// kind, browser grants and each provider's secondary restrictions still apply.
@Suite("Web outgoing access matrix")
struct WEBAccessMatrixTests {
    private struct Row {
        let family: String
        let messages: [String]
        let look: Bool
        let work: Bool
        let full: Bool
    }
    private static let rows: [Row] = [
        .init(family: "Connection and terminal reads", messages: ["hello", "ping", "list", "attach", "detach", "resize", "take"], look: true, work: true, full: true),
        .init(family: "Terminal changes", messages: ["input", "create", "close", "rename"], look: false, work: true, full: true),
        .init(family: "Chat reads and choices", messages: ["chats.watch", "chats.unwatch", "chats.older", "chats.options", "chats.choices", "folders.browse"], look: true, work: true, full: true),
        .init(family: "Chat changes", messages: ["chats.say", "chats.steer", "chats.interrupt", "chats.new", "chats.set"], look: false, work: true, full: true),
        .init(family: "Chat approvals", messages: ["chats.answer"], look: false, work: false, full: true),
        .init(family: "Hoot reads", messages: ["hoot.hello", "hoot.attach", "hoot.detach", "hoot.state", "hoot.sessions", "hoot.log", "hoot.pending", "hoot.older", "hoot.options.read", "hoot.account.read"], look: true, work: true, full: true),
        .init(family: "Hoot routine changes", messages: ["hoot.say", "hoot.cancel", "hoot.stop"], look: false, work: true, full: true),
        .init(family: "Hoot approvals, box settings and account switch", messages: ["hoot.answer", "hoot.options.set", "hoot.account.switch"], look: false, work: false, full: true),
        .init(family: "Attachments", messages: ["upload.begin", "upload.data", "upload.end", "upload.cancel"], look: false, work: true, full: true),
        .init(family: "Browser and ports reads", messages: ["browser.windows", "browser.watch", "browser.unwatch", "browser.frame.ack", "ports"], look: true, work: true, full: true),
        .init(family: "Mac browser actions", messages: ["browser.window.open", "browser.window.shot"], look: false, work: false, full: true),
        .init(family: "Activity and read-only changes", messages: ["activity.watch", "activity.unwatch", "git.status", "git.diff"], look: true, work: true, full: true),
        // account.read and usage.read pass this coarse read gate, then their
        // actual services require BackendRemoteOwnerScope.permits == true.
        .init(family: "Owner-scoped account and usage reads", messages: ["account.read", "usage.read"], look: true, work: true, full: true),
        .init(family: "Session account switch", messages: ["account.switch"], look: false, work: false, full: true),
        // The copied active connection helper acknowledges and refuses legacy
        // credential requests. It never supplies a GitHub credential.
        .init(family: "Legacy credential refusal", messages: ["credential.ack", "credential.deny"], look: false, work: false, full: true),
    ]

    @Test func everyOutgoingMessageHasExplicitLookWorkFullExpectations() {
        let names = Self.rows.flatMap(\.messages)
        #expect(names.count == Set(names).count)
        for row in Self.rows {
            for type in row.messages {
                #expect(BackendINT2PhoneAccessLevel.look.permits(type) == row.look, "Look: \(row.family) / \(type)")
                #expect(BackendINT2PhoneAccessLevel.work.permits(type) == row.work, "Work: \(row.family) / \(type)")
                #expect(BackendINT2PhoneAccessLevel.full.permits(type) == row.full, "Full: \(row.family) / \(type)")
            }
        }
    }

    @Test func everyWebPanelUsesTheSameExplicitReadAndActionMatrix() {
        let expected: [(String, [Bool], [Bool])] = [
            ("tasks", [true, true, true], [false, true, true]),
            ("goals", [true, true, true], [false, true, true]),
            ("projects", [true, true, true], [false, false, true]),
            ("agents", [true, true, true], [false, false, true]),
            ("artifacts", [true, true, true], [false, false, true]),
            ("mcp", [true, true, true], [false, false, true]),
            ("receiver", [false, true, true], [false, false, true]),
        ]
        let levels: [BackendINT2PhoneAccessLevel] = [.look, .work, .full]
        for (panel, reads, acts) in expected {
            for (index, level) in levels.enumerated() {
                #expect(level.permits("panel.read", panel: panel) == reads[index], "\(level.rawValue) reads \(panel)")
                #expect(level.permits("panel.act", panel: panel) == acts[index], "\(level.rawValue) changes \(panel)")
            }
        }
        // A gate permit is necessary, not a promise of an action: Projects,
        // Agents, MCP and Receiver are read-only providers in web v1. Artifact
        // bytes use panel.read; they do not start the panel.act preview server.
    }

    @Test func secondaryOwnerAndChatChoiceGuardsKeepSensitiveChangesAtFull() {
        for level in [BackendINT2PhoneAccessLevel.look, .work, .full] {
            let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: "fixture-browser", kind: .mine, address: "fixture", peerPublicKey: nil,
                claimedCapabilities: [], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false), phoneAccess: level)
            // Actual account.read/account.switch and usage.read services call
            // this guard before entering the owner's profile/account context.
            #expect(BackendRemoteOwnerScope.permits(context) == (level == .full))
            #expect(BackendPhoneChats.fullControl(context) == (level == .full))
            #expect(BackendPhoneChats.mayChooseLoginAndMode(.init(model: "fixture-model", effort: "high"), context))
            #expect(BackendPhoneChats.mayChooseLoginAndMode(.init(permissionMode: "bypass"), context) == (level == .full))
            #expect(BackendPhoneChats.mayChooseLoginAndMode(.init(account: "fixture-account"), context) == (level == .full))
            // chats.set model/effort is Work, but its permissionMode handler
            // additionally calls fullControl. Hoot's entire options.set and
            // both families' approvals are already Full at the coarse gate.
            #expect(level.permits("hoot.options.set") == (level == .full))
            #expect(level.permits("chats.answer") == (level == .full))
            #expect(level.permits("hoot.answer") == (level == .full))
        }
    }
}
