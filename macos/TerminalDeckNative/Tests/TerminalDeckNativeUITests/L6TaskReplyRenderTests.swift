import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor private final class L6TaskReplyLiveState { var status = "idle"; var hootBusy = false }
@MainActor private final class L6TaskReplyTransport {
    let taskID = "local:FIXES-task-109"
    var calls: [(String, [NativeRPCValue])] = []
    var ready = true, mentions = true, denyHoot = false, failPost = false
    var changed: (@MainActor () -> Void)?
    var writing: NativeRPCValue = .null
    var comments: [NativeRPCValue] = []
    var meta: NativeRPCValue = .object([])
    var candidates: [NativeRPCValue] = []
    /// #109 second scene: an @asked reviewer answered, the holder is still writing.
    func useMentionScene() {
        var asked = comment("own-ask", author: "me", body: "@portal-reviewer can you check the diff too?", receipt: "seen")
        asked = asked.setting("mentionDeliveries", .array([delivery("answered", agent: "reviewer", name: "portal-reviewer")]))
        comments = [comment("agent-start", author: "builder", body: "Picking this up. I will check the sign-in expiry."), asked,
                    comment("asked-reviewer-1", author: "reviewer", body: "Diff looks right. The expiry unit fix is correct, and the new test covers Safari.")]
        meta = .object([])
        candidates = [.object([.init("agentID", .string("builder")), .init("name", .string("portal-mechanic")), .init("sessionID", .string("stub-session-1"))])]
    }
    init() {
        comments = [comment("agent-start", author: "builder", body: "Picking this up. I will check the sign-in expiry."),
                    comment("own-question", author: "me", body: "Also check Safari — the old bug only showed up there.", receipt: "seen"),
                    comment("agent-finish", author: "builder", body: "The stub change passes. `expiry` uses the same unit now."),
                    comment("own-reply", author: "me", body: "Can you check this image too? [[file:fixture-image]]", receipt: "failed")]
        meta = .object([.init("own-reply", .object([.init("parentId", .string("agent-finish"))])),
                        .init("agent-finish", .object([.init("resolvedAt", .string("2026-10-10T00:20:00Z")), .init("resolvedBy", .string("me"))]))])
    }
    private func comment(_ id: String, author: String, body: String, receipt: String? = nil) -> NativeRPCValue {
        let names = ["me": "You", "builder": "portal-mechanic", "reviewer": "portal-reviewer"]
        var row = NativeRPCValue.object([.init("id", .string(id)), .init("taskId", .string(taskID)),
            .init("authorUserId", .string(author)), .init("authorName", .string(names[author] ?? author)),
            .init("authorInitials", .string(author == "me" ? "AI" : "PM")), .init("authorColor", .string("bg-violet-500")),
            .init("body", .string(body)), .init("createdAt", .string("2026-10-10T00:15:00Z"))])
        if let receipt { row = row.setting("delivery", delivery(receipt)) }
        return row
    }
    private func delivery(_ state: String, agent: String = "builder", name: String = "portal-mechanic") -> NativeRPCValue {
        .object([.init("state", .string(state)), .init("agentID", .string(agent)), .init("agentName", .string(name)),
            .init("deliveredAt", ["seen", "answered"].contains(state) ? .number(1_791_589_000_000) : .null),
            .init("seenAt", ["seen", "answered"].contains(state) ? .number(1_791_589_100_000) : .null),
            .init("error", state == "failed" ? .string("The stub could not reach its worker.") : .null)])
    }
    var transport: NativeFIXESTaskThreadTransport {
        .init(invoke: { [self] function, values in try invoke(function, values) },
              observe: { [self] callback in changed = callback; return .init { [weak self] in self?.changed = nil } })
    }
    private func invoke(_ function: String, _ values: [NativeRPCValue]) throws -> NativeRPCValue {
        calls.append((function, values))
        switch function {
        case "listTaskComments":
            return .object([.init("ok", .bool(true)), .init("comments", .array(comments)), .init("deliveryAvailable", .bool(ready)),
                .init("capabilities", .object([.init("retry", .bool(ready)), .init("askHoot", .bool(false)), .init("mentions", .bool(mentions))])),
                .init("writing", writing), .init("writingCandidates", .array(candidates))])
        case "fetchCommentExtras":
            return .object([.init("ok", .bool(true)), .init("extras", .object([.init("meta", meta),
                .init("reactions", .object([.init("agent-finish", .array([.object([.init("emoji", .string("👍")), .init("userIds", .array([.string("me")]))])]))]))]))])
        case "listTaskActivity":
            let row: NativeRPCValue = .object([.init("id", .string("system-created")), .init("taskId", .string(taskID)),
                .init("kind", .string("created")), .init("actorUserId", .string("hoot")), .init("createdAt", .string("2026-10-10T00:10:00Z")), .init("payload", .object([]))])
            return .object([.init("ok", .bool(true)), .init("rows", .array([row])), .init("total", .number(1))])
        case "retryCommentDelivery", "askHootInstead":
            if function == "askHootInstead", denyHoot { throw NSError(domain: "FIXES-stub-approval", code: 1, userInfo: [NSLocalizedDescriptionKey: "Asking Hoot was declined."]) }
            guard values.count > 1, let index = comments.firstIndex(where: { $0["id"].string == values[1].string }) else { throw NSError(domain: "FIXES-stub", code: 2) }
            comments[index] = comments[index].setting("delivery", delivery("sent")); changed?()
            return .object([.init("ok", .bool(true))])
        case "addTaskComment", "addTaskCommentWith":
            if failPost { return .object([.init("ok", .bool(false)), .init("error", .string("The stub refused this post."))]) }
            guard values.count > 1, let body = values[1].string else { throw NSError(domain: "FIXES-stub", code: 3) }
            let id = "posted-\(comments.count)"
            let scheduled = values.count > 2 && values[2]["scheduledFor"].string != nil
            comments.append(comment(id, author: "me", body: body, receipt: scheduled ? nil : "sent"))
            if values.count > 2 { meta = meta.setting(id, values[2].setting("deliveredAt", .null)) }
            changed?(); return .object([.init("ok", .bool(true)), .init("id", .string(id))])
        default:
            throw NSError(domain: "FIXES-unexpected-stub-call", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected call: " + function])
        }
    }
}

/// Actual pane and actual injected model. No AppModel, EngineBridge, app/NSApp,
/// window, panel, clipboard, capture helper, microphone or real AI is invoked.
/// #109 (L6-TASKREPLY, reusing the FIXES chat's drafted checks): the real task
/// pane and model over a stub transport. Capabilities mirror the real backend:
/// retry on, asking Hoot instead and @mentions off.
final class L6TaskReplyRenderTests: XCTestCase {
    @MainActor private func model(_ stub: L6TaskReplyTransport) async -> TaskDetailModel {
        let row = TaskRow(id: stub.taskID, keyId: "local", externalTaskId: "FIXES-task-109", title: "Sign-in button does nothing",
                          project: "/stub/project", local: true, assignee: "builder")
        let model = TaskDetailModel(row: row, agents: [.init(id: "builder", name: "portal-mechanic", icon: "sf:wrench"),
                                                       .init(id: "reviewer", name: "portal-reviewer", icon: "sf:checkmark.seal")],
                                    threadTransport: stub.transport, loadOnOpen: false)
        XCTAssertTrue(stub.calls.isEmpty, "Construction must perform no live fallback reads")
        await model.loadComments(); await model.loadCommentExtras(); await model.loadActivity()
        model.people = TaskPeople(primary: CrmPeople.person("builder", "portal-mechanic"),
                                  others: [CrmPeople.person("me", "You"), CrmPeople.person("hoot", "Hoot")])
        return model
    }
    @MainActor func testActualModelRetryUsesSameCommentAndDeclinedHootKeepsReceipt() async {
        let stub = L6TaskReplyTransport(), model = await model(stub)
        XCTAssertTrue(model.commentThreadUIReady)
        let count = model.comments?.count
        let retried = await model.retryCommentDelivery("own-reply")
        XCTAssertTrue(retried)
        XCTAssertEqual(model.comments?.count, count)
        XCTAssertEqual(stub.calls.filter { $0.0 == "retryCommentDelivery" }.first?.1[1].string, "own-reply")
        XCTAssertEqual(model.commentDeliveries["own-reply"]?.state, .sent)
        // Not offered by the backend yet: refused without any call.
        let asked = await model.askHootInstead("own-reply")
        XCTAssertFalse(asked)
        XCTAssertFalse(stub.calls.contains { $0.0 == "askHootInstead" })
    }
    @MainActor func testActualModelPostPreservesFilesScheduleAndStructuredMentionIdentity() async {
        let stub = L6TaskReplyTransport(), model = await model(stub)
        var draft = HootComposerDraft(); draft.text = "Please check "
        draft.insert(.init(id: "builder", kind: .agent, name: "portal-mechanic", project: "independent"))
        let posted = await model.postCommentDraft(draft, attachmentIDs: ["fixture-image"], assignee: "builder", scheduledFor: "2026-10-11T00:15:00Z")
        XCTAssertTrue(posted)
        let call = stub.calls.last { $0.0 == "addTaskCommentWith" }
        XCTAssertEqual(call?.1[2]["mentions"].elements?.first?["id"].string, "builder")
        XCTAssertEqual(call?.1[2]["assigneeUserId"].string, "builder")
        XCTAssertEqual(call?.1[2]["scheduledFor"].string, "2026-10-11T00:15:00Z")
        XCTAssertTrue(call?.1[1].string?.contains(CrmText.fileToken("fixture-image")) == true)
        stub.failPost = true
        let count = stub.comments.count
        let refused = await model.postCommentDraft(draft, attachmentIDs: ["fixture-image"], assignee: nil, scheduledFor: nil)
        XCTAssertFalse(refused)
        XCTAssertEqual(stub.comments.count, count); XCTAssertNotNil(model.error)
    }
    @MainActor func testMissingCapabilitiesRefuseMentionsAndNeverInventTyping() async {
        let stub = L6TaskReplyTransport(); stub.ready = false; stub.mentions = false
        let model = await model(stub)
        XCTAssertFalse(model.commentThreadUIReady); XCTAssertNil(model.commentWritingProof)
        var draft = HootComposerDraft(); draft.insert(.init(id: "builder", kind: .agent, name: "portal-mechanic"))
        let refused = await model.postCommentDraft(draft, attachmentIDs: [], assignee: nil, scheduledFor: nil)
        XCTAssertFalse(refused)
        XCTAssertFalse(stub.calls.contains { $0.0 == "addTaskCommentWith" })
        XCTAssertNil(model.commentWritingProof, "Running task or receipt does not imply writing")
    }
    @MainActor func testWritingProofRequiresActualCurrentBusyTurnAndClearsAtEnd() async {
        let stub = L6TaskReplyTransport(), model = await model(stub)
        stub.writing = .object([.init("busy", .bool(true)), .init("taskId", .string(stub.taskID)),
            .init("agentId", .string("builder")), .init("turnId", .string("stub-turn-1")),
            .init("name", .string("portal-mechanic")), .init("icon", .string("sf:wrench"))])
        await model.loadComments()
        XCTAssertEqual(model.commentWritingProof?.turnID, "stub-turn-1")
        stub.writing = stub.writing.setting("taskId", .string("local:someone-else"))
        await model.loadComments(); XCTAssertNil(model.commentWritingProof)
        stub.writing = .null
        await model.loadComments(); XCTAssertNil(model.commentWritingProof)
    }
    /// #109: an @asked agent has its own receipt; "is writing" follows the
    /// recipient's live session status (Hoot: its chat busy) and clears on answer.
    @MainActor func testMentionReceiptsAndWritingLineFollowLiveStatus() async {
        let stub = L6TaskReplyTransport(); stub.useMentionScene()
        stub.candidates.append(.object([.init("agentID", .string("hoot")), .init("name", .string("Hoot"))]))
        let model = await model(stub)
        XCTAssertEqual(model.commentReceipts("own-ask").map(\.agentID), ["builder", "reviewer"])
        XCTAssertEqual(model.commentReceipts("own-ask").last?.state, .answered)
        let live = L6TaskReplyLiveState()
        model.sessionStatusOverride = { _ in live.status }; model.hootBusyOverride = { live.hootBusy }
        XCTAssertNil(model.currentWriting)
        live.status = "working"
        XCTAssertEqual(model.currentWriting?.agentID, "builder"); XCTAssertEqual(model.currentWriting?.name, "portal-mechanic")
        live.status = "idle"; live.hootBusy = true
        XCTAssertEqual(model.currentWriting?.agentID, "hoot"); XCTAssertEqual(model.currentWriting?.isHoot, true)
        stub.candidates = []; await model.loadComments()
        XCTAssertNil(model.currentWriting, "An answered comment has nobody writing")
        let retried = await model.retryCommentDelivery("own-ask", agent: "reviewer")
        XCTAssertTrue(retried)
        XCTAssertEqual(stub.calls.last { $0.0 == "retryCommentDelivery" }?.1.count, 3)
        XCTAssertTrue(model.commentComposerCatalogue.mentions.contains { $0.id == "hoot" && $0.kind == .agent })
    }
    @MainActor func testOffscreenSecondAgentAnswerAndWritingLine() async throws {
        let stub = L6TaskReplyTransport(); stub.useMentionScene()
        let model = await model(stub)
        model.sessionStatusOverride = { _ in "working" }; model.hootBusyOverride = { false }
        XCTAssertEqual(model.currentWriting?.agentID, "builder")
        for dark in [false, true] {
            let pane = TaskActivityPane(model: model, commands: [], onAttach: { _ in XCTFail("Render tried to upload"); return [] }, fixtureMode: true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.agkitOffscreenSolid, true)
                .frame(width: 1000, height: 820)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: pane); host.sizingOptions = []
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 820)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let name = "L6-TASKREPLY-mentions-\(dark ? "dark" : "light")"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: FIXESTestRenderPaths.image(try artifactRoot().appendingPathComponent(name + ".png")))
        }
        XCTAssertFalse(stub.calls.contains { ["addTaskComment", "addTaskCommentWith", "retryCommentDelivery", "askHootInstead"].contains($0.0) })
    }
    @MainActor func testOffscreenActualCommentsAndActivityInLightAndDark() async throws {
        let stub = L6TaskReplyTransport(), model = await model(stub)
        XCTAssertTrue(model.commentThreadUIReady); XCTAssertEqual(model.commentCapabilities["retry"], true)
        model.attachments = [try XCTUnwrap(CrmDecode.attachment([
            "id": "fixture-image", "kind": "upload", "fileName": "login-snip.png", "mimeType": "image/png",
            "createdAt": "2026-10-10T00:15:00Z", "previewUrl": try imageDataURL()
        ]))]
        for dark in [false, true] {
            let pane = TaskActivityPane(model: model, commands: [], onAttach: { _ in XCTFail("Render tried to upload"); return [] }, fixtureMode: true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.agkitOffscreenSolid, true)
                .frame(width: 1000, height: 700)
            let host = NSHostingView(rootView: pane); host.sizingOptions = []
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
            for state in ["comments", "activity"] {
                model.commentPaneSelection = state == "activity" ? .activity : .comments
                await model.loadComments()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "L6-TASKREPLY-\(state)-\(dark ? "dark" : "light")"
                let root = try artifactRoot()
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: FIXESTestRenderPaths.image(root.appendingPathComponent(name + ".png")))
                let cg = try XCTUnwrap(bitmap.cgImage), scale = CGFloat(bitmap.pixelsWide) / 1000
                let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: 0, y: 440 * scale, width: 1000 * scale, height: 260 * scale)))
                try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])).write(to: FIXESTestRenderPaths.image(root.appendingPathComponent(name + "-composer.png")))
                XCTAssertEqual(host.frame.size, CGSize(width: 1000, height: 700))
            }
        }
        XCTAssertFalse(stub.calls.contains { ["addTaskComment", "addTaskCommentWith", "retryCommentDelivery", "askHootInstead"].contains($0.0) })
    }
    @MainActor private func imageDataURL() throws -> String {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<48 { for y in 0..<24 { bitmap.setColor(NSColor.systemBlue.withAlphaComponent(0.25), atX: x, y: y) } }
        return "data:image/png;base64," + (try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))).base64EncodedString()
    }
    private func artifactRoot() throws -> URL {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if folder.lastPathComponent == "macos" { return try FIXESTestRenderPaths.directory(folder.appendingPathComponent("design-2026-10-10/built.noindex", isDirectory: true)) }
            folder.deleteLastPathComponent()
        }
        throw NSError(domain: "FIXES-render-root", code: 1)
    }
}
