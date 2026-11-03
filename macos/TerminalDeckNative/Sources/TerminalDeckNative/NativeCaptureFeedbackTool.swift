import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func browserCaptureFeedbackTool(gate: BackendCompositionDeckToolsGate) throws -> BackendDeckToolsDefinition {
        guard let access = browserAccess else { throw BackendHOSTFailure.unavailable }
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let fraction = NativeRPCValue.object([.init("type", .string("number")), .init("minimum", .number(0)), .init("maximum", .number(1))])
        let mark = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("x", fraction), .init("y", fraction), .init("width", fraction), .init("height", fraction)])),
            .init("required", .array(["x", "y", "width", "height"].map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("window", string), .init("url", string), .init("sessionId", string), .init("note", string),
            .init("marks", .object([.init("type", .string("array")), .init("items", mark), .init("minItems", .number(1)), .init("maxItems", .number(50))]))])),
            .init("required", .array(["sessionId", "note", "marks"].map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        let tool = try BackendMCPTool(id: "browser.feedback", wireName: "browser_feedback",
            description: "Mark a permitted browser window, or a temporary isolated background URL, with normalized rectangles and send the privacy-masked picture/note to a session. Supply exactly one of window or url. Chat uses its persistent attachment queue; terminals receive the saved picture path. No tab selection or activation. Existing access/approvals apply.", inputSchema: schema, tier: .act)
        let registry = root.registry
        let captureDirectories = [RNMHootPaths(dataRoot: root.dataRoot).screenshots, root.dataRoot.appendingPathComponent("browser-screenshots")]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
        let lifecycle = sessions?.lifecycle
        return BackendDeckToolsDefinition(spec: tool, title: "Send marked browser feedback") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                guard resolved.caller.kind != .remote else { throw BackendHOSTFailure.authentication }
                let id = try args["sessionId"].requireString("sessionId", nonempty: true)
                _ = try await gate.authority.requireSession(id, native: caller)
                let window = args["window"].string, url = args["url"].string
                guard (window == nil) != (url == nil), !(window ?? url ?? "").isEmpty else {
                    throw NativeRPCError.invalidArguments("Supply exactly one browser window or URL.")
                }
                let note = try args["note"].requireString("note", nonempty: true)
                guard note.utf8.count <= 262_144, let marks = args["marks"].elements, (1...50).contains(marks.count) else {
                    throw NativeRPCError.invalidArguments("Supply a note and 1 to 50 normalized marks.")
                }
                let rectangles = try marks.map { mark -> CGRect in
                    guard let x = mark["x"].number, let y = mark["y"].number,
                          let w = mark["width"].number, let h = mark["height"].number,
                          x.isFinite, y.isFinite, w.isFinite, h.isFinite,
                          x >= 0, y >= 0, w > 0, h > 0, x + w <= 1, y + h <= 1 else {
                        throw NativeRPCError.invalidArguments("Marks must fit inside the picture.")
                    }
                    return CGRect(x: x, y: y, width: w, height: h)
                }
                try await gate.authorize(caller, .act, "Send marked browser feedback to this session", true)
                let rpc = try await access.rpc(caller)
                let principal = try await access.principal(rpc)
                // Capture through the same browser authority without selecting its tab.
                let payload = try await Task { @MainActor in
                    let browser = try NativeCompositionRoot.shared.browserForComposition()
                    var created: String?
                    let target: String
                    if let url {
                        let page = try await browser.service.nativeCreate(rpc, arguments: .object([.init("url", .string(url)), .init("isolated", .bool(true))]))
                        let tab = try page["id"].requireString("id", nonempty: true)
                        target = browser.bindings.displayName(tab) ?? tab
                        created = target
                        _ = await browser.runtime.settle(tab, timeoutMs: 10_000)
                    } else { target = window! }
                    do {
                        let arguments = NativeRPCValue.object([.init("window", .string(target))])
                        let value: NativeRPCValue
                        if principal.managesWindows {
                            value = try await browser.service.page(rpc, operation: "screenshot", arguments: arguments)
                        } else {
                            value = try await browser.service.drive(rpc, verb: .screenshot, arguments: arguments, attended: resolved.attended)
                        }
                        if let created { _ = try await browser.service.windows(rpc, arguments: .object([.init("action", .string("close")), .init("window", .string(created))])) }
                        return value
                    } catch {
                        if let created { _ = try? await browser.service.windows(rpc, arguments: .object([.init("action", .string("close")), .init("window", .string(created))])) }
                        throw error
                    }
                }.value
                let imagePath = payload["path"].string ?? payload["value"]["path"].string ?? payload["result"]["path"].string
                guard let imagePath else { throw NativeRPCError(code: "capture", message: "The browser did not return a saved picture.") }
                let resolvedPath = URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().standardizedFileURL.path
                guard captureDirectories.contains(where: resolvedPath.hasPrefix) else {
                    throw NativeRPCError.invalidArguments("The browser returned a picture outside its capture folder.")
                }
                let prepared = try await MainActor.run { () throws -> (Data, NativeRPCValue, [BrowserAnnotation], Int, Int) in
                    guard let image = NSImage(contentsOfFile: imagePath), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw NativeRPCError.invalidArguments("The captured picture could not be read.")
                    }
                    let annotations = rectangles.enumerated().map { BrowserAnnotation(n: $0.offset + 1, rect: $0.element, element: nil) }
                    guard let drawn = NativeBrowserRender.annotated(cg, annotations),
                          let png = NSBitmapImageRep(cgImage: drawn).representation(using: .png, properties: [:]) else {
                        throw NativeRPCError.invalidArguments("The marked picture could not be prepared.")
                    }
                    let round = BrowserAnnotate.round(id: UUID().uuidString.lowercased(), createdAt: Date().timeIntervalSince1970 * 1000,
                        list: annotations, url: "", title: "Marked browser page", note: note, width: drawn.width, height: drawn.height)
                    return (png, try NativeRPCValue.fromFoundation(round), annotations, drawn.width, drawn.height)
                }
                let saved = try await registry.invoke("annotate:save", context: rpc, arguments: [.string("data:image/png;base64," + prepared.0.base64EncodedString()), prepared.1])
                let path = try saved["path"].requireString("path", nonempty: true)
                let sender = await lifecycle?.conversationSender(resolved.caller)
                let source = NativeRPCValue.object([.init("kind", .string("browser")), .init("path", .string(path)),
                    .init("senderName", .string(sender?.name ?? "Agent")), .init("window", .string(window ?? url ?? ""))])
                let queued = try await Task { @MainActor in
                    let text = BrowserAnnotate.compose(prepared.2, url: "", title: "Marked browser page", note: note,
                        picturePath: path, width: prepared.3, height: prepared.4)
                    return try await NativeCapturedFeedback.send(sessionID: id, text: text, chatText: note, paths: [path], source: source)
                }.value
                _ = try await registry.invoke("annotate:sent", context: rpc, arguments: [prepared.1["id"], .object([.init("sessionId", .string(id)), .init("label", .string(id))])])
                return .value(.object([.init("sessionId", .string(id)), .init("path", .string(path)), .init("rawPath", .string(imagePath)), .init("roundId", prepared.1["id"]), .init("queuedId", queued.map(NativeRPCValue.string) ?? .null),
                    .init("marks", .number(Double(marks.count))), .init("accepted", .bool(true))]))
            }
        }
    }
}
