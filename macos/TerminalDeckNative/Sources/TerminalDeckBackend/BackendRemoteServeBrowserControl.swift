import Foundation
import TerminalDeckNativeCore

/// One redraw per verb, with payload replies only for successful screenshots,
/// recorded flows and element picks. Browser failures never leave a phone waiting.
@MainActor
public final class BackendRemoteServeBrowserControl {
    public static let requestTags: Set<String> = ["browser.windows", "browser.window.open", "browser.window.go",
        "browser.window.act", "browser.window.size", "browser.window.bind", "browser.window.shot",
        "browser.window.steps", "browser.window.pick"]
    public let operations: any BackendRemoteServeBrowserOperations
    public init(operations: any BackendRemoteServeBrowserOperations) { self.operations = operations }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "browser.control", messageTypes: Self.requestTags, policy: .ownerOnly) { [self] message, host in
            [await answer(message, deviceID: host.deviceID, kind: host.kind, context: host.rpcContext)]
        }
    }

    public func answer(_ message: BackendRemoteClientMessage, deviceID: String,
                       kind: BackendRemoteDeviceKind, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        guard kind == .mine, context.caller == .pairedDevice, context.ownerID == deviceID,
              await operations.isMine(deviceID) else { return Self.refusal("This machine does not let this phone drive its browser.") }
        do {
            switch message.type {
            case "browser.windows": return await rows("", context: context)
            case "browser.window.open": return await open(message, context: context)
            case "browser.window.go": return await go(message, context: context)
            case "browser.window.act": return await act(message, context: context)
            case "browser.window.bind": return await bind(message, context: context)
            case "browser.window.shot": return await shot(message, context: context)
            case "browser.window.steps": return await steps(message, context: context)
            case "browser.window.pick": return await pick(message, context: context)
            case "browser.window.size": return await size(message, context: context)
            default: return try .error(code: "bad-message", message: "This build does not know that browser request.")
            }
        } catch { return Self.refusal("This machine's browser could not be reached.") }
    }

    private static func refusal(_ message: String) -> BackendRemoteServerMessage {
        // Both fields are fixed protocol literals, so schema validation cannot fail.
        try! .error(code: "unavailable", message: message)
    }
    private func text(_ value: String, _ maximum: Int = BackendRemoteServeBrowserLimits.rowText) -> String {
        BackendRemoteServeBrowserText.line(value, maximum: maximum)
    }
    private func name(_ window: BackendRemoteServeBrowserWindow) -> String {
        let title = text(window.title); if !title.isEmpty { return title }
        let url = text(window.url); return url.isEmpty ? "That window" : url
    }
    private var bindingPrincipal: BackendBrowserPrincipal { .init(ownerID: "remote-browser-binding-view", managesWindows: true) }
    private func rows(_ notice: String, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        var windows: [BackendRemoteServeBrowserWindow] = [], sessions: [BackendRemoteServeBrowserSession] = [], trouble = ""
        do { windows = try await operations.list(context: context) }
        catch { trouble = "This machine's browser could not be listed: \(BackendRemoteServeBrowserText.why(error))." }
        do { sessions = try await operations.sessions(context: context) }
        catch { if trouble.isEmpty { trouble = "This machine could not list its sessions: \(BackendRemoteServeBrowserText.why(error))." } }
        let titles = Dictionary(sessions.map { ($0.id, $0.title) }, uniquingKeysWith: { _, last in last })
        let shared = operations.bindings.bindings(for: bindingPrincipal)
        let windowRows: [NativeRPCValue] = windows.prefix(BackendRemoteServeBrowserLimits.windowRows).map { entry in
            var fields: [NativeRPCValue.Field] = [.init("id", .string(entry.id)), .init("title", .string(text(entry.title))),
                .init("url", .string(text(entry.url, BackendRemoteServeBrowserLimits.rowURL)))]
            if !entry.profile.isEmpty { fields.append(.init("profile", .string(text(entry.profile)))) }
            if entry.isolated { fields.append(.init("isolated", .bool(true))) }
            if entry.recording { fields.append(.init("recording", .bool(true))) }
            if entry.loading { fields.append(.init("loading", .bool(true))) }
            if let owner = operations.bindings.owner(of: entry.id), let bound = shared.of(owner).first(where: { $0.tabID == entry.id }) {
                fields.append(.init("slot", .string(bound.name))); fields.append(.init("session", .string(owner.sessionId)))
                if let title = titles[owner.sessionId], !text(title).isEmpty { fields.append(.init("sessionTitle", .string(text(title)))) }
            }
            return .object(fields)
        }
        let sessionRows: [NativeRPCValue] = sessions.prefix(BackendRemoteServeBrowserLimits.sessionRows).map { session in
            .object([.init("id", .string(session.id)), .init("title", .string(text(session.ended ? session.title + " (exited)" : session.title))),
                .init("windows", .number(Double(shared.of(.init(sessionId: session.id, machineId: operations.machineID)).count)))])
        }
        let signIn = windows.contains { BackendBrowserSignIn.diagnose($0.url)?.kind == "refused" }
            ? "Google will not sign in in this machine's browser. Finish it in a normal browser on the machine, or use an account already signed in here." : ""
        var cut: [String] = []
        if windows.count > BackendRemoteServeBrowserLimits.windowRows { cut.append("32 of \(windows.count) windows") }
        if sessions.count > BackendRemoteServeBrowserLimits.sessionRows { cut.append("32 of \(sessions.count) sessions") }
        let line = [notice, trouble, signIn, cut.isEmpty ? "" : "Listing \(cut.joined(separator: " and "))."].filter { !$0.isEmpty }.joined(separator: " ")
        var fields: [NativeRPCValue.Field] = [.init("windows", .array(windowRows)), .init("sessions", .array(sessionRows))]
        if !line.isEmpty { fields.append(.init("notice", .string(text(line, BackendRemoteServeBrowserLimits.rowURL)))) }
        return try! .init(.browserWindowRows, fields: fields)
    }
    private func find(_ id: String, context: NativeRPCContext) async -> BackendRemoteServeBrowserWindow? {
        (try? await operations.list(context: context))?.first { $0.id == id }
    }
    private func sessionNamed(_ id: String, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserSession {
        let sessions: [BackendRemoteServeBrowserSession]
        do { sessions = try await operations.sessions(context: context) }
        catch { throw NativeRPCError(code: "unavailable", message: "This machine could not list its sessions: \(BackendRemoteServeBrowserText.why(error)).") }
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw NativeRPCError(code: "unavailable", message: "No session by that name is running here.")
        }
        return session
    }
    private func attach(_ window: BackendRemoteServeBrowserWindow, to session: BackendRemoteServeBrowserSession,
                        context: NativeRPCContext) async throws -> String {
        let bound = try await operations.attach(id: window.id, sessionID: session.id, context: context)
        return "\(name(window)) is \(bound.name) in \(text(session.title))."
    }
    private func open(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        let isolated = message["isolated"].bool == true
        var wanted: BackendRemoteServeBrowserSession?
        if let id = message["session"].string {
            do { wanted = try await sessionNamed(id, context: context) }
            catch { return await rows((error as? NativeRPCError)?.message ?? BackendRemoteServeBrowserText.why(error), context: context) }
        }
        let id: String?
        do { id = try await operations.open(url: message["url"].string ?? "", profile: message["profile"].string ?? "", isolated: isolated, context: context) }
        catch { return await rows("This machine's browser could not open a window: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
        guard let id else {
            let said = operations.whyNotOpen() ?? ""
            return await rows(said.isEmpty ? "This machine's browser did not open a window." : said, context: context)
        }
        guard let wanted else { return await rows(isolated ? "Opened an isolated window." : "Opened a window.", context: context) }
        let opened = await find(id, context: context) ?? .init(id: id, url: message["url"].string ?? "")
        do { return await rows(try await attach(opened, to: wanted, context: context), context: context) }
        catch { return await rows("\(name(opened)) could not be reached: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
    }
    private func go(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        let id = message["id"].string ?? ""
        guard await find(id, context: context) != nil else { return await rows("That window is not open any more.", context: context) }
        do { try await operations.go(id: id, url: message["url"].string ?? "", context: context) }
        catch { return await rows("That address could not be opened: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
        return await rows("", context: context)
    }
    private func act(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        let id = message["id"].string ?? "", action = message["action"].string ?? ""
        guard let window = await find(id, context: context) else { return await rows("That window is not open any more.", context: context) }
        let named = name(window)
        do {
            switch action {
            case "back", "forward", "reload": try await operations.history(id: id, move: action, context: context); return await rows("", context: context)
            case "close":
                try await operations.close(id: id, context: context); operations.bindings.closed(id)
                return await rows("Closed \(named).", context: context)
            case "record.on", "record.off":
                guard operations.canRecord else { return await rows("This machine's browser cannot record a click flow.", context: context) }
                let on = action == "record.on"; try await operations.setRecording(id: id, on: on, context: context)
                return await rows(on ? "Recording \(named)." : "Stopped recording \(named).", context: context)
            case "share", "isolate":
                guard operations.canRepartition else { return await rows("This machine's browser has one cookie jar and cannot isolate a window.", context: context) }
                let isolated = action == "isolate"
                if window.isolated == isolated { return await rows(isolated ? "\(named) is already isolated." : "\(named) is already shared.", context: context) }
                guard let moved = try await operations.repartition(id: id, isolated: isolated, context: context) else {
                    return await rows("\(named) could not be \(isolated ? "isolated" : "shared").", context: context)
                }
                if var known = operations.bindings.window(id) { known.viewID = moved.viewID ?? ""; operations.bindings.observe(known) }
                return await rows(isolated ? "\(named) is isolated." : "\(named) is shared.", context: context)
            default: return await rows("This build does not know how to \(text(action, 32)) a window.", context: context)
            }
        } catch { return await rows("\(named) could not be reached: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
    }
    private func bind(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        let id = message["id"].string ?? ""
        guard let window = await find(id, context: context) else { return await rows("That window is not open any more.", context: context) }
        let named = name(window)
        if let sessionID = message["session"].string {
            do {
                let session = try await sessionNamed(sessionID, context: context)
                return await rows(try await attach(window, to: session, context: context), context: context)
            }
            catch { return await rows((error as? NativeRPCError)?.message ?? BackendRemoteServeBrowserText.why(error), context: context) }
        }
        guard operations.bindings.owner(of: id) != nil else { return await rows("\(named) was not attached to anything.", context: context) }
        do { try await operations.detach(id: id, context: context) }
        catch { return await rows("\(named) could not be reached: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
        return await rows("\(named) is no longer attached to a session.", context: context)
    }
    private func size(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        guard operations.canResize else { return await rows("This machine's browser lays its own windows out, so this one cannot be resized from here.", context: context) }
        let id = message["id"].string ?? ""
        guard let window = await find(id, context: context) else { return await rows("That window is not open any more.", context: context) }
        do { try await operations.resize(id: id, width: message["width"].number ?? 0, height: message["height"].number ?? 0, context: context) }
        catch { return await rows("\(name(window)) could not be laid out at that size: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
        return await rows("", context: context)
    }
    private func shot(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        let id = message["id"].string ?? ""
        guard let window = await find(id, context: context) else { return await rows("That window is not open any more.", context: context) }
        let named = name(window)
        var target: BackendRemoteServeBrowserSession?
        if let sessionID = message["session"].string {
            target = (try? await operations.sessions(context: context))?.first { $0.id == sessionID }
            guard let target else { return await rows("No session by that name is running here.", context: context) }
            if target.ended { return await rows("\(text(target.title)) has exited.", context: context) }
        }
        let captured: BackendRemoteServeBrowserCapture
        do { captured = try await operations.capture(id: id, context: context) }
        catch { return await rows("\(named) could not be photographed: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
        if let target {
            guard !captured.path.isEmpty else { return await rows("\(named) was photographed, but this machine saved no file to send.", context: context) }
            let line = BackendRemoteServeBrowserText.shotLine(captured, url: window.url, note: message["note"].string ?? "")
            let (typed, submit) = BackendRemoteServeBrowserText.replayWrites(line)
            do {
                try await operations.write(sessionID: target.id, data: typed, context: context)
                try await operations.wait(milliseconds: BackendRemoteServeBrowserLimits.submitGapMilliseconds)
                try await operations.write(sessionID: target.id, data: submit, context: context)
            } catch { return await rows("\(text(target.title)) could not be written to: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
            return await rows("Sent \(named) to \(text(target.title)).", context: context)
        }
        guard !captured.preview.isEmpty else { return await rows("\(named) was photographed, but no picture small enough to send could be made.", context: context) }
        let png = captured.preview.base64EncodedString()
        guard png.count <= BackendRemoteServeBrowserLimits.shotCharacters else {
            let kb = Int((Double(captured.preview.count) / 1024).rounded())
            return await rows("\(named) is \(kb) KB, over the 47 KB this link carries. It is saved at \(captured.path.isEmpty ? "no file on this machine" : captured.path) — send it to a session instead.", context: context)
        }
        let at = operations.now()
        guard at.isFinite else { return await rows("This machine's browser could not be reached.", context: context) }
        return try! .init(.browserShot, fields: [.init("id", .string(id)), .init("png", .string(png)), .init("at", .number(at))])
    }
    private func steps(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        guard operations.canRecord else { return await rows("This machine's browser cannot record a click flow.", context: context) }
        let id = message["id"].string ?? ""
        guard await find(id, context: context) != nil else { return await rows("That window is not open any more.", context: context) }
        let collected: [BrowserRecordedStep]
        do { collected = try await operations.recordedSteps(id: id, context: context) }
        catch { return await rows("That flow could not be read: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
        var listed: [NativeRPCValue] = collected.prefix(BackendRemoteServeBrowserLimits.wireSteps).map { step in
            var fields: [NativeRPCValue.Field] = [.init("at", .number(step.at)), .init("kind", .string(step.kind.rawValue))]
            let detail = text(BrowserFlow.describe(step), BackendRemoteServeBrowserLimits.stepText)
            if !detail.isEmpty { fields.append(.init("detail", .string(detail))) }
            let selector = text(step.selector, BackendRemoteServeBrowserLimits.stepText)
            if !selector.isEmpty { fields.append(.init("selector", .string(selector))) }
            let value = step.redacted ? "" : text(step.value, BackendRemoteServeBrowserLimits.stepText)
            if !value.isEmpty { fields.append(.init("value", .string(value))) }
            return .object(fields)
        }
        if collected.count > BackendRemoteServeBrowserLimits.wireSteps {
            let dropped = collected.count - BackendRemoteServeBrowserLimits.wireSteps
            listed.append(.object([.init("at", .number(collected[BackendRemoteServeBrowserLimits.wireSteps].at)), .init("kind", .string("truncated")),
                .init("detail", .string("\(dropped) more step\(dropped == 1 ? "" : "s") recorded — the whole flow is on this machine."))]))
        }
        return try! .init(.browserRecordRows, fields: [.init("id", .string(id)), .init("steps", .array(listed))])
    }
    private func pick(_ message: BackendRemoteClientMessage, context: NativeRPCContext) async -> BackendRemoteServerMessage {
        guard operations.canPick else { return await rows("This machine's browser cannot point at one thing on a page.", context: context) }
        let id = message["id"].string ?? ""
        guard let window = await find(id, context: context) else { return await rows("That window is not open any more.", context: context) }
        let facts: BackendRemoteServeBrowserPicked
        do { facts = try await operations.pick(id: id, x: message["x"].number ?? 0, y: message["y"].number ?? 0, up: Int(message["up"].number ?? 0), context: context) }
        catch { return await rows("\(name(window)) could not be looked at: \(BackendRemoteServeBrowserText.why(error)).", context: context) }
        guard facts.found else { return await rows(facts.moved ? "\(name(window)) has scrolled since that picture — tap the same thing again." : "There is nothing at that spot on \(name(window)).", context: context) }
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
        func whole(_ value: Double) -> Double { max(0, floor(finite(value))) }
        return try! .init(.browserWindowPicked, fields: [.init("id", .string(id)), .init("tag", .string(text(facts.tag, BackendRemoteServeBrowserLimits.pickWord))),
            .init("selector", .string(text(facts.selector, BackendRemoteServeBrowserLimits.pickSelector))), .init("label", .string(text(facts.label))),
            .init("labelSource", .string(text(facts.labelSource, BackendRemoteServeBrowserLimits.pickWord))), .init("url", .string(text(window.url, BackendRemoteServeBrowserLimits.rowURL))),
            .init("rect", .object([.init("x", .number(finite(facts.x))), .init("y", .number(finite(facts.y))), .init("w", .number(finite(facts.width))), .init("h", .number(finite(facts.height)))])),
            .init("depth", .number(whole(facts.depth))), .init("maxUp", .number(whole(facts.maxUp)))])
    }
}
