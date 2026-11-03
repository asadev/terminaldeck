import AppKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U80 (18 Oct): the task popup's small bugs.
@MainActor @Suite
struct TaskPopupSmallBugsTests {
    private static let row = TaskRow(id: "fixture-task", keyId: "local", externalTaskId: "fixture-task", title: "Ship the release",
                                     project: "/stub/project", local: true, assignee: "builder", instructions: "Build, sign and upload it.")
    private static let bundle: NativeRPCValue = .object([.init("ok", .bool(true)), .init("bundle", .object([
        .init("subtasks", .array([.object([.init("id", .string("s1")), .init("title", .string("Write the notes")), .init("done", .bool(true))]),
                                  .object([.init("id", .string("s2")), .init("title", .string("Upload")), .init("done", .bool(false))])]))]))])

    // #316: Print prints the task itself, not the app window.
    @Test func printShowsTheTaskItself() async throws {
        let transport = NativeFIXESTaskThreadTransport(invoke: { function, _ in
            function == "fetchTaskDetailBundle" ? Self.bundle : .object([.init("ok", .bool(true))])
        }, observe: { _ in .init {} })
        let model = TaskDetailModel(row: Self.row, agents: [], threadTransport: transport, loadOnOpen: false)
        await model.loadBundle()
        let text = TaskPrint.text(model).string
        #expect(text.hasPrefix("Ship the release\n"))
        #expect(text.contains("Build, sign and upload it."))
        #expect(text.contains("☑ Write the notes") && text.contains("☐ Upload"))
    }

    // #319: a picture is decoded once, not on every redraw.
    @Test func picturesAreDecodedOnce() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = "data:image/png;base64," + png.base64EncodedString()
        let first = try #require(TaskPictures.image(id: "picture-1", url))
        #expect(TaskPictures.image(id: "picture-1", url) === first)
    }

    @Test func refreshKeepsKnownPicturesAndLoadsNewOnes() async throws {
        var refresh = false
        let transport = NativeFIXESTaskThreadTransport(invoke: { function, args in
            guard function == "fetchTaskDetailBundle" else { return .object([.init("ok", .bool(true))]) }
            let known = args.count > 1 ? args[1].elements?.compactMap(\.string) ?? [] : []
            #expect(known == (refresh ? ["picture"] : []))
            let rows: [NativeRPCValue] = [.object([.init("id", .string("picture")), .init("fileName", .string("shot.png")),
                .init("previewUrl", refresh ? .null : .string("data:image/png;base64,aGVsbG8="))])]
            refresh = true
            return .object([.init("ok", .bool(true)), .init("bundle", .object([.init("attachments", .array(rows))]))])
        }, observe: { _ in .init {} })
        let model = TaskDetailModel(row: Self.row, agents: [], threadTransport: transport, loadOnOpen: false)
        await model.loadBundle()
        let preview = model.attachments?.first?.previewUrl
        #expect(preview != nil)
        await model.loadBundle()
        #expect(model.attachments?.first?.previewUrl == preview)
    }

    // #317: a Fields button's refresh keeps the comments' receipts (the guarded read).
    @Test func fieldButtonRefreshKeepsReceipts() async throws {
        let comments: NativeRPCValue = .object([.init("ok", .bool(true)), .init("deliveryAvailable", .bool(true)), .init("comments", .array([
            .object([.init("id", .string("c1")), .init("body", .string("Done.")), .init("authorName", .string("You")),
                     .init("delivery", .object([.init("agentName", .string("Builder")), .init("agentID", .string("builder")), .init("state", .string("delivered"))]))])]))])
        let transport = NativeFIXESTaskThreadTransport(invoke: { function, _ in
            switch function {
            case "fetchTaskDetailBundle": return Self.bundle
            case "listTaskComments": return comments
            default: return .object([.init("ok", .bool(true))])
            }
        }, observe: { _ in .init {} })
        let model = TaskDetailModel(row: Self.row, agents: [], threadTransport: transport, loadOnOpen: false)
        model.refetchAll()
        for _ in 0..<100 where model.commentDeliveries["c1"] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.comments?.map(\.id) == ["c1"])
        #expect(model.commentDeliveries["c1"]?.state == .delivered)
    }

    // #327: a Files field refuses a file the task's Attach refuses, before it is read or sent.
    @Test func filesFieldChecksTheFileFirst() async throws {
        var calls: [String] = []
        let transport = NativeFIXESTaskThreadTransport(invoke: { function, _ in
            calls.append(function)
            return function == "fetchTaskDetailBundle" ? Self.bundle : .object([.init("ok", .bool(true))])
        }, observe: { _ in .init {} })
        let model = TaskDetailModel(row: Self.row, agents: [], threadTransport: transport, loadOnOpen: false)
        await model.loadBundle()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("task-popup-u80-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("big.zip")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: 30 * 1024 * 1024); try handle.close()
        let store = FieldsStore(model: model)
        await store.upload(TaskField(id: "f1", taskId: Self.row.id, label: "Files", kind: .files, config: FieldConfig()), [big])
        #expect(!calls.contains("uploadTaskFile"))
        #expect(store.errors["f1"]?.contains("too big") == true)
    }
}
