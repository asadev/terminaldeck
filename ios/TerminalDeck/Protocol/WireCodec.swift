/**
 * The only door inbound text comes through, and the only thing that writes to
 * the socket. A port of `pwa/src/protocol-client.ts`.
 *
 * ## Why a client validates the desktop
 *
 * The desktop is not hostile, but it is not always what answers. A captive
 * portal on hotel wifi answers every request with its own login page, and the
 * first thing an unguarded client would do with that is parse an HTML document
 * and read `.sessions` off the result. Narrowing here means the app can say
 * "that is not the desktop" instead of throwing inside a socket callback and
 * leaving a terminal on screen with nothing behind it.
 *
 * ## Why not Codable
 *
 * Three of the rules here are ones a synthesised `Codable` cannot express:
 *
 *  - A `welcome` whose `token` is JSON `null` means "you already have one"; a
 *    `welcome` with no `token` key at all is not a message this protocol
 *    defines. `Optional<String>` decodes both to `nil` and the difference —
 *    between a paired device and a client that believes it is paired while
 *    holding nothing — disappears.
 *  - One malformed row must not discard a session list. A phone showing four of
 *    five sessions is useful; one showing none because the fifth had a null
 *    title is not.
 *  - `lastActivityAt` is read off a row that `RemoteSession` has no field for,
 *    so that the list improves on the day the desktop starts sending it without
 *    a change on this side. A strict decoder would either reject it or need the
 *    field added here first.
 */

import Foundation

enum DecodeResult: Equatable {
    /// `activity` carries last-activity times for the rows in a `welcome` or
    /// `sessions` frame, when the desktop timestamped them. Beside the message
    /// rather than inside it, because `RemoteSession` has no such field.
    case ok(ServerMessage, activity: [String: Double])
    case failed(reason: String)
}

enum WireCodec {

    // MARK: - Inbound

    /// Mirrors `decodeServerMessage`. Never throws: a caller answers a bad frame
    /// by dropping it or closing, and an exception on a socket's data path is
    /// how an app dies in the background where nobody sees the crash.
    static func decode(_ raw: String) -> DecodeResult {
        guard let data = raw.data(using: .utf8) else { return .failed(reason: "not UTF-8") }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failed(reason: "not JSON")
        }
        guard let object = parsed as? [String: Any] else { return .failed(reason: "not an object") }

        switch object["t"] as? String {
        case "welcome":
            guard let version = whole(object["protocol"]),
                  let deviceId = string(object["deviceId"]),
                  let deviceName = string(object["deviceName"]),
                  let list = sessionList(object["sessions"]) else {
                return .failed(reason: "incomplete welcome")
            }
            // Present-and-null and absent are different answers; see the header.
            let rawToken = object["token"]
            let token: String?
            if rawToken is NSNull {
                token = nil
            } else if let supplied = string(rawToken) {
                token = supplied
            } else {
                return .failed(reason: "welcome without a token field")
            }
            return .ok(
                .welcome(protocolVersion: version, deviceId: deviceId, deviceName: deviceName,
                         token: token, sessions: list.sessions,
                         capabilities: capabilities(object["capabilities"]),
                         // Absent from every desktop before 0.1.9, and absent is
                         // its own answer: `.unknown` makes this screen say
                         // "Running on the desktop" rather than guess "Mac",
                         // which is the whole bug. See `HostPlatform`.
                         hostPlatform: HostPlatform(wire: string(object["hostPlatform"])),
                         /*
                          * What that machine calls itself.
                          *
                          * The switcher chips read the relay slot code — `2JJGF8`,
                          * `9ZA6K3` — for somebody who owns one Mac and one
                          * Windows PC, because the only name this phone ever had
                          * was the one on the pairing link, read once, at the
                          * desk. A machine paired before that field existed has
                          * none at all and no way to get one short of pairing
                          * again. This frame arrives on every connection.
                          *
                          * Display text from another machine, so it is cleaned
                          * the way every other such string here is: control
                          * characters out, bounded, and empty read as absent —
                          * a machine that said nothing must not overwrite a name
                          * with the empty string.
                          */
                         hostName: hostName(object["hostName"]),
                         folders: folders(object["folders"]),
                         // Absent is `.silent`, and so is malformed — both mean
                         // "this phone has no copilot on that machine", which is
                         // what a guest device is told by omission. The presence
                         // of the field is the whole answer now, and it is a
                         // different question from what the capability list
                         // claims. See `CopilotConnection`.
                         copilot: copilotConnection(object["copilot"]),
                         // What build the host runs, and which shell serves. Both
                         // absent from every desktop before 0.10.0, and absent is
                         // its own answer: the version reads as "older" and the
                         // kind as `.unknown`, which name the box neutrally
                         // rather than guessing. Display text with nothing to act
                         // on, so `appVersion` is stripped and bounded on arrival
                         // the same way `hostName` is.
                         appVersion: hostName(object["appVersion"]),
                         hostKind: HostKind(wire: string(object["hostKind"]))),
                activity: list.activity)

        case "sessions":
            guard let list = sessionList(object["sessions"]) else {
                return .failed(reason: "sessions without a list")
            }
            return .ok(.sessions(list.sessions), activity: list.activity)

        case "folders":
            // An absent or malformed list is fatal here and merely means
            // "nothing said" in a `welcome`, and the difference is not
            // pedantry: this frame exists *to change* the list, so a version of
            // it that cannot say what to change it to has nothing to deliver.
            guard let list = folders(object["folders"]) else {
                return .failed(reason: "folders without a list")
            }
            return .ok(.folders(list), activity: [:])

        case "folders.entries":
            // `path` is required and the list is not: a readable folder with no
            // sub-folders in it is an ordinary answer and draws an empty picker,
            // whereas an answer that cannot say *which* folder it describes
            // cannot be drawn under any heading at all.
            guard let path = string(object["path"]) else {
                return .failed(reason: "folders.entries without a path")
            }
            let rows = (object["entries"] as? [Any] ?? []).compactMap { row -> FolderEntry? in
                guard let entry = row as? [String: Any],
                      let name = string(entry["name"]),
                      let full = string(entry["path"])
                else { return nil }
                /*
                 * Both flags default the safe way for a client older than the
                 * host: an unsaid `readable` draws a row somebody may try, and an
                 * unsaid `granted` draws one they may add. The machine refuses
                 * either honestly, which is the layer that matters.
                 *
                 * `granted` is read **strictly** on top of that, and `readable`
                 * is not, because only one of them is a permission. `granted`
                 * says this folder is already shared with an agent, and
                 * `NSNumber(1)` bridges to `Bool` through the ObjC bridge — so
                 * the lenient spelling reads `{"granted":1}` as *already shared*
                 * and draws the row as `Shared`. That is the same read
                 * `copilotFolder` already gives the same concept one frame over;
                 * the two spellings were simply inconsistent. `readable` decides
                 * nothing but whether a tap is worth trying, and its `?? true`
                 * default is deliberate — `literalTrue` would collapse absent to
                 * false and grey out every row a host does not annotate.
                 */
                return FolderEntry(name: name,
                                   path: full,
                                   readable: entry["readable"] as? Bool ?? true,
                                   granted: literalTrue(entry["granted"]))
            }
            return .ok(.folderEntries(path: path,
                                      parent: string(object["parent"]),
                                      entries: rows),
                       activity: [:])

        case "browser.profile.rows":
            // Never `.failed`. A machine with no profiles is not a malformed
            // frame, a dangling `current` is repaired against the rows that
            // survived, and one bad row is dropped rather than discarding the
            // answer.
            return .ok(.browserProfileRows(machineProfileList(object)), activity: [:])

        case "files.rows":
            guard let path = string(object["path"]) else { return .failed(reason: "files.rows without a path") }
            let rows = (object["entries"] as? [Any] ?? []).compactMap { row -> FileRow? in
                guard let e = row as? [String: Any],
                      let name = string(e["name"]), let full = string(e["path"]) else { return nil }
                // A malformed row is dropped, never the listing — the rule this
                // codec already follows for session lists.
                let millis = (e["at"] as? NSNumber)?.doubleValue
                return FileRow(name: name,
                               path: full,
                               directory: e["directory"] as? Bool ?? false,
                               readable: e["readable"] as? Bool ?? true,
                               size: (e["size"] as? NSNumber)?.intValue,
                               at: millis.map { Date(timeIntervalSince1970: $0 / 1000) })
            }
            return .ok(.fileRows(FileListing(path: path,
                                             parent: string(object["parent"]),
                                             entries: rows)),
                       activity: [:])

        case "files.text":
            guard let path = string(object["path"]) else { return .failed(reason: "files.text without a path") }
            return .ok(.fileText(FileText(path: path,
                                          text: string(object["text"]) ?? "",
                                          at: (object["at"] as? NSNumber)?.intValue ?? 0,
                                          truncated: object["truncated"] as? Bool ?? false,
                                          binary: object["binary"] as? Bool ?? false)),
                       activity: [:])

        case "git.state":
            guard let path = string(object["path"]) else { return .failed(reason: "git.state without a path") }
            return .ok(.gitState(path: path, status: GitState(wire: object["status"])), activity: [:])

        case "git.patch":
            guard let path = string(object["path"]), let file = string(object["file"]) else {
                return .failed(reason: "git.patch without a path")
            }
            return .ok(.gitPatch(path: path,
                                 file: file,
                                 staged: object["staged"] as? Bool ?? false,
                                 patch: string(object["patch"]) ?? ""),
                       activity: [:])

        case "panel.rows":
            /*
             * Decoded by `PanelsWire.panelData`, which is the only decoder for
             * this frame — there were two for a while, and the one that was
             * **not** being called was the better of the pair: it runs every
             * string through `displayLine` and caps the list at
             * `PanelsWire.maxPanelRows`, and the live one did neither. A panel's
             * rows are text from another machine going straight onto a screen,
             * so losing the sanitiser to a duplicate was the more serious half
             * of the duplication.
             */
            guard let data = panelData(object) else {
                return .failed(reason: "panel.rows for a panel this build does not draw")
            }
            return .ok(.panelRows(data), activity: [:])

        case "browser.window.rows":
            return .ok(.machineWindowRows(machineWindows(object)), activity: [:])

        case "browser.shot":
            guard let id = string(object["id"]), let raw = string(object["png"]),
                  let png = Data(base64Encoded: raw) else {
                return .failed(reason: "browser.shot without a picture in it")
            }
            return .ok(.machineShot(MachineShot(id: id,
                                                png: png,
                                                at: object["at"] as? Double ?? 0)),
                       activity: [:])

        case "browser.window.picked":
            guard let picked = pickedElement(object) else {
                return .failed(reason: "browser.window.picked without an element in it")
            }
            return .ok(.machineWindowPicked(id: picked.id, element: picked.element), activity: [:])

        case "browser.record.rows":
            guard let id = string(object["id"]) else {
                return .failed(reason: "browser.record.rows without a window")
            }
            return .ok(.machineRecordRows(id: id, steps: recordedSteps(object)), activity: [:])

        case "attached":
            guard let id = string(object["id"]) else { return .failed(reason: "attached without an id") }
            return .ok(.attached(id: id), activity: [:])

        case "detached":
            guard let id = string(object["id"]) else { return .failed(reason: "detached without an id") }
            return .ok(.detached(id: id), activity: [:])

        case "output":
            guard let id = string(object["id"]), let payload = string(object["data"]) else {
                return .failed(reason: "output without id and data")
            }
            // `replay` is `true` or absent in the protocol; anything else is not
            // a marker this client will act on.
            let replay = (object["replay"] as? Bool) == true
            return .ok(.output(id: id, data: payload, replay: replay), activity: [:])

        case "status":
            guard let id = string(object["id"]), let status = string(object["status"]) else {
                return .failed(reason: "status without id and status")
            }
            return .ok(.status(id: id, status: status), activity: [:])

        case "exit":
            guard let id = string(object["id"]), let code = whole(object["exitCode"]) else {
                return .failed(reason: "exit without id and code")
            }
            return .ok(.exit(id: id, exitCode: code), activity: [:])

        case "error":
            guard let raw = string(object["code"]), let code = ProtocolErrorCode(rawValue: raw) else {
                return .failed(reason: "error with an unknown code")
            }
            return .ok(.error(code: code, message: string(object["message"]) ?? ""), activity: [:])

        case "pong":
            return .ok(.pong, activity: [:])

        /* ---- capability `create` ------------------------------------------ */

        case "created":
            // The same lenient row decoder the list uses, so a `created` and a
            // `sessions` row can never disagree about what a session is. A row
            // that will not decode is fatal *here* — unlike in a list, where
            // four of five is useful — because this frame is one row and the
            // whole point of it is to name the session the user just started.
            guard let session = decodeSession(object["session"]) else {
                return .failed(reason: "created without a session")
            }
            return .ok(.created(session: session),
                       activity: lastActivity(object["session"]).map { [session.id: $0] } ?? [:])

        /* ---- capability `close` -------------------------------------------- */

        case "closed":
            // The id is the whole frame, so a nameless one is refused rather
            // than read as "something closed": a client that took it would have
            // to guess which row to remove, and the only available guess is the
            // one the person was last looking at.
            guard let id = string(object["id"]) else { return .failed(reason: "closed without an id") }
            return .ok(.closed(id: id), activity: [:])

        /* ---- capability `localhost` --------------------------------------- */

        case "ports":
            guard let rows = object["ports"] as? [Any] else { return .failed(reason: "ports without a list") }
            // One malformed row does not discard the list, for the same reason
            // one bad session row does not: a phone showing four of five ports
            // is useful and one showing none is not.
            return .ok(.ports(rows.compactMap { localPort($0) }), activity: [:])

        case "tunnel.opened":
            guard let id = string(object["id"]), let port = port(object["port"]) else {
                return .failed(reason: "tunnel.opened without an id and a port")
            }
            return .ok(.tunnelOpened(id: id, port: port), activity: [:])

        case "tunnel.closed":
            guard let id = string(object["id"]) else { return .failed(reason: "tunnel.closed without an id") }
            // The sentence is what the user reads, so it is sanitised the way
            // any other display string from the wire would be — but its absence
            // is not fatal, because the *closing* is the message.
            return .ok(.tunnelClosed(id: id, message: string(object["message"]) ?? "The tunnel closed."),
                       activity: [:])

        /* ---- capability `web` ---------------------------------------------- */

        case "web.opened":
            // The URL is the whole payload and it is what the confirmation
            // names, so an absent one is fatal rather than defaulted: a line
            // reading "Opened" with nothing after it is a claim about a page
            // this end cannot identify.
            guard let url = string(object["url"]) else { return .failed(reason: "web.opened without a url") }
            return .ok(.webOpened(url: url), activity: [:])

        case "net.data":
            guard let ch = string(object["ch"]), let encoded = string(object["data"]) else {
                return .failed(reason: "net.data without a channel and data")
            }
            guard let bytes = strictBase64(encoded) else {
                return .failed(reason: "net.data is not base64")
            }
            return .ok(.netData(ch: ch, data: bytes), activity: [:])

        case "net.ack":
            guard let ch = string(object["ch"]), let bytes = whole(object["bytes"]),
                  bytes > 0, bytes <= Wire.netWindowBytes else {
                return .failed(reason: "net.ack out of range")
            }
            return .ok(.netAck(ch: ch, bytes: bytes), activity: [:])

        case "net.close":
            guard let ch = string(object["ch"]) else { return .failed(reason: "net.close without a channel") }
            return .ok(.netClose(ch: ch), activity: [:])

        /* ---- capability `devserver` ---------------------------------------- */

        case "dev.state":
            guard let report = devServerReport(object["state"]) else {
                return .failed(reason: "dev.state without a usable state")
            }
            return .ok(.devState(report), activity: [:])

        /* ---- capability `upload` ------------------------------------------ */

        case "upload.ready":
            guard let id = string(object["id"]), let path = string(object["path"]), !path.isEmpty else {
                return .failed(reason: "upload.ready without an id and a path")
            }
            return .ok(.uploadReady(id: id, path: path), activity: [:])

        case "upload.ack":
            guard let id = string(object["id"]), let bytes = whole(object["bytes"]),
                  bytes > 0, bytes <= Wire.maxUploadChunkBytes else {
                return .failed(reason: "upload.ack out of range")
            }
            return .ok(.uploadAck(id: id, bytes: bytes), activity: [:])

        case "upload.done":
            guard let id = string(object["id"]), let path = string(object["path"]), !path.isEmpty,
                  let bytes = whole(object["bytes"]), bytes >= 0,
                  let digest = string(object["sha256"]) else {
                return .failed(reason: "incomplete upload.done")
            }
            return .ok(.uploadDone(id: id, path: path, bytes: bytes, sha256: digest), activity: [:])

        case "upload.failed":
            guard let id = string(object["id"]) else { return .failed(reason: "upload.failed without an id") }
            // The sentence is what the user reads, and its absence is not fatal:
            // the *failing* is the message. Same rule as `tunnel.closed`.
            return .ok(.uploadFailed(id: id, message: string(object["message"]) ?? "That file did not arrive."),
                       activity: [:])

        /* ---- capability `credential` --------------------------------------- */

        case "credential.request":
            guard let id = string(object["id"]), !id.isEmpty,
                  let host = string(object["host"]), !host.isEmpty,
                  host.count <= Wire.maxCredentialHostLength,
                  let raw = string(object["operation"]),
                  let operation = CredentialOperation(rawValue: raw) else {
                return .failed(reason: "incomplete credential.request")
            }
            /*
             * A missing `repo` and an unusable one are the same answer, and it
             * is nil rather than a failure.
             *
             * The desktop sends JSON null when git gave it no path to derive a
             * name from, which is a legitimate outcome it passes along rather
             * than papering over — so refusing the frame here would turn "this
             * machine does not know what the repository is called" into "that
             * push is not answerable at all". What the prompt does with nil is
             * say so; see `CredentialPromptView`.
             */
            let repo = string(object["repo"]).flatMap { name in
                name.isEmpty || name.count > Wire.maxCredentialRepoLength ? nil : name
            }
            /*
             * `prompt` is an instruction to interrupt a person and ask them for
             * a secret, so it is acted on only when the desktop said it in so
             * many words. Anything else — absent, a string, a number — reads as
             * false, which answers silently.
             *
             * That sentence was already here and the code underneath it did not
             * keep it. `as? Bool` **succeeds** for `NSNumber(1)` through the ObjC
             * bridge, so `{"prompt":1}` raised the credential sheet: a number
             * read as the desktop saying it in so many words. `literalTrue` is
             * what the comment always described.
             */
            let prompt = literalTrue(object["prompt"])
            return .ok(.credentialRequest(id: id, host: host, repo: repo,
                                          operation: operation, prompt: prompt),
                       activity: [:])

        /* ---- capability `copilot` ------------------------------------------ */

        case "copilot.state":
            guard let state = copilotState(object["state"]) else {
                return .failed(reason: "copilot.state without a status")
            }
            return .ok(.copilotState(state), activity: [:])

        case "copilot.chat":
            // The run is required and the messages are not. An empty `reset` is
            // a real frame — it is what a freshly started run answers with, and
            // what a run that was cleared sends — so refusing it would leave the
            // last run's conversation on screen under a new one.
            guard let run = string(object["run"]), !run.isEmpty,
                  let rows = object["messages"] as? [Any] else {
                return .failed(reason: "copilot.chat without a run and messages")
            }
            // One malformed message does not discard the frame, for the same
            // reason one bad session row does not discard a list: a phone
            // showing four of five turns is useful and one showing none is not.
            return .ok(.copilotChat(run: run,
                                    messages: rows.compactMap { copilotMessage($0) },
                                    reset: (object["reset"] as? Bool) == true),
                       activity: [:])

        case "copilot.tool":
            guard let row = copilotAction(object["row"]) else {
                return .failed(reason: "copilot.tool without a usable row")
            }
            return .ok(.copilotTool(row), activity: [:])

        case "copilot.sessions":
            guard let rows = object["sessions"] as? [Any] else {
                return .failed(reason: "copilot.sessions without a list")
            }
            return .ok(.copilotSessions(rows.compactMap { copilotSessionRow($0) }), activity: [:])

        case "copilot.log":
            guard let rows = object["rows"] as? [Any] else {
                return .failed(reason: "copilot.log without rows")
            }
            return .ok(.copilotLog(rows: rows.compactMap { copilotAction($0) }.suffix(Copilot.maxLogRows),
                                   more: (object["more"] as? Bool) == true),
                       activity: [:])

        case "copilot.pending":
            guard let rows = object["questions"] as? [Any] else {
                return .failed(reason: "copilot.pending without a list")
            }
            /*
             * The cap is the desktop's own `maxPending`, mirrored.
             *
             * `ConsentBroker` refuses a fourth outstanding question with
             * `too-many-pending`, so more than three here is a frame that did
             * not come from a broker this app understands. Bounding it matters
             * more than usual because these are drawn as full-height cards with
             * every argument on them: a host sending sixty would be a screen a
             * person scrolls rather than reads, which is the exact failure mode
             * a consent surface must not have.
             */
            return .ok(.copilotPending(rows.compactMap { copilotQuestion($0) }.prefix(3).map { $0 }),
                       activity: [:])

        case "copilot.grant":
            /*
             * `link`, not `grant`, and the difference is not cosmetic.
             *
             * `server.ts` sends `{ t: 'copilot.grant', link: CopilotLinkWire }`
             * — `linked`, `open` and the grant inside it. This client read
             * `object["grant"]` for a while against a desktop that has never
             * sent that key, which decodes as "no access" for every push: a
             * connection would open and the phone would immediately draw the
             * not-connected screen over it.
             *
             * Absent and malformed collapse to `.silent` one layer down, which
             * is the safe answer for a frame whose whole job is to say what this
             * device may do. See `copilotConnection`.
             */
            return .ok(.copilotGrant(copilotConnection(object["link"])), activity: [:])

        /*
         * There is no `copilot.linked` case here any more, and this note is so
         * that nobody adds one back by reading an older desktop.
         *
         * It carried the copilot credential, exactly once, in answer to a
         * `copilot.connect`. Both frames went on 2026-08-19 with the second act
         * of authorisation itself — *"if we are connecting as my device copilot
         * automatically comes, if we connect as guest then copilot don't come"*
         * — so there is no code to redeem, no credential to be handed, and
         * nothing this codec would do with the frame if one arrived. An unknown
         * `t` falls through to the default below and is reported rather than
         * half-applied, which is the right answer for a host speaking a
         * vocabulary this build does not share.
         */

        case "copilot.ask":
            // `raw` is passed through so the arguments keep the order the tool
            // wrote them in — Foundation's reader loses it. See
            // `CopilotArguments`, which is the whole argument for the second
            // read.
            guard let question = copilotConsentQuestion(object["question"], raw: raw) else {
                return .failed(reason: "copilot.ask without a question to judge")
            }
            return .ok(.copilotAsk(question), activity: [:])

        case "copilot.files.rows":
            guard let rows = object["files"] as? [Any] else {
                return .failed(reason: "copilot.files.rows without a list")
            }
            /*
             * One unreadable row costs a row, never the frame — the rule every
             * list on this wire keeps. A memory file whose name this build cannot
             * address is a line missing from the list; refusing the whole frame
             * would take the copilot's instructions off the screen because
             * something in `memory/` was odd.
             *
             * Capped at what the desktop already caps itself at, so a host ahead
             * of this build cannot make this phone hold an unbounded directory.
             */
            return .ok(.copilotFiles(rows.compactMap { copilotFileRow($0) }.prefix(Copilot.maxFileRows).map { $0 }),
                       activity: [:])

        case "copilot.file.text":
            // The id has to be one this build can address, for the reason the
            // rows above drop an unknown one: text arriving for a file nothing
            // asked about is either a build ahead of this one or something that
            // is not this app, and putting it in an editor would be putting
            // unattributed bytes in front of a Save button.
            guard let id = string(object["id"]), Copilot.isFileId(id) else {
                return .failed(reason: "copilot.file.text without a known file")
            }
            // Absent text is empty rather than a refusal: the frame's contract is
            // that `text` is always there and empty whenever `error` is, and a
            // desktop that sent only the error has still answered the question.
            let failure = string(object["error"]).flatMap { $0.isEmpty ? nil : $0 }
            return .ok(.copilotFileText(id: id,
                                        text: string(object["text"]) ?? "",
                                        error: failure),
                       activity: [:])

        case "copilot.settled":
            guard let settlement = copilotSettlement(object["settled"]) else {
                return .failed(reason: "copilot.settled without an id")
            }
            return .ok(.copilotSettled(settlement), activity: [:])

        /*
         * The session bar and its conversation. Three answers, one rule: a
         * figure this build cannot read is an **absence**, drawn as no chip at
         * all, never as zero and never as a sentence explaining the gap.
         */

        case "usage.reading":
            guard let rid = string(object["rid"]),
                  let id = string(object["id"]),
                  let want = string(object["want"]).flatMap({ UsageWant(rawValue: $0) }) else {
                return .failed(reason: "usage.reading without a request, session and reading")
            }
            // `answer.reading` is the far machine's own record and may be JSON
            // null, which is "there is no reading" rather than an empty one.
            let answer = object["answer"] as? [String: Any]
            let reading = answer?["reading"]
            return .ok(.usageReading(rid: rid, id: id, want: want,
                                     figures: usageFigures(want: want,
                                                           reading: reading is NSNull ? nil : reading)),
                       activity: [:])

        case "account.state":
            guard let rid = string(object["rid"]), let id = string(object["id"]) else {
                return .failed(reason: "account.state without a request and session")
            }
            let current = object["current"]
            return .ok(.accountState(rid: rid, id: id,
                                     current: current is NSNull ? nil : account(current),
                                     accounts: accounts(object["accounts"])),
                       activity: [:])

        case "account.switched":
            guard let rid = string(object["rid"]), let id = string(object["id"]) else {
                return .failed(reason: "account.switched without a request and session")
            }
            // The far end's `message` is read and dropped on purpose. Whether it
            // took is what this client acts on, and the sentence would be the
            // one piece of prose on a bar that has none.
            return .ok(.accountSwitched(rid: rid, id: id, ok: object["ok"] as? Bool == true), activity: [:])

        case "enrolled":
            guard let deviceId = string(object["deviceId"]),
                  let deviceName = string(object["deviceName"]),
                  let credential = string(object["credential"]) else {
                return .failed(reason: "enrolled without an id, name and credential")
            }
            return .ok(.enrolled(deviceId: deviceId, deviceName: deviceName, credential: credential),
                       activity: [:])

        case "controls.reading":
            guard let rid = string(object["rid"]), let id = string(object["id"]) else {
                return .failed(reason: "controls.reading without a request and session")
            }
            return .ok(.controlsReading(rid: rid, id: id, reading: controlsReading(object["reading"])),
                       activity: [:])

        case "controls.applied":
            // No `control` field on the wire: the asking side knows which control
            // this answers from the `rid` it minted, and the `reading` is what
            // redraws. See `controls.applied` in `protocol.ts`.
            guard let rid = string(object["rid"]), let id = string(object["id"]) else {
                return .failed(reason: "controls.applied without a request and session")
            }
            return .ok(.controlsApplied(rid: rid, id: id,
                                        ok: object["ok"] as? Bool == true,
                                        message: displayLine(object["message"]) ?? "",
                                        reading: controlReading(object["reading"])),
                       activity: [:])

        case "settings.state":
            guard let rid = string(object["rid"]) else {
                return .failed(reason: "settings.state without a request")
            }
            return .ok(.settingsState(rid: rid, settings: serverSettings(object["settings"])),
                       activity: [:])

        case "settings.applied":
            guard let rid = string(object["rid"]), let setting = serverSetting(object["setting"]) else {
                return .failed(reason: "settings.applied without a request and setting")
            }
            return .ok(.settingsApplied(rid: rid,
                                        ok: object["ok"] as? Bool == true,
                                        message: displayLine(object["message"]) ?? "",
                                        setting: setting),
                       activity: [:])

        case "settings.changed":
            return .ok(.settingsChanged(settings: serverSettings(object["settings"])), activity: [:])

        case "devices.rows":
            guard let rid = string(object["rid"]) else {
                return .failed(reason: "devices.rows without a request")
            }
            return .ok(.devicesRows(rid: rid, devices: deviceRoster(object["devices"])), activity: [:])

        case "devices.revoked":
            guard let rid = string(object["rid"]) else {
                return .failed(reason: "devices.revoked without a request")
            }
            return .ok(.devicesRevoked(rid: rid,
                                       ok: object["ok"] as? Bool == true,
                                       message: displayLine(object["message"]) ?? "",
                                       devices: deviceRoster(object["devices"])),
                       activity: [:])

        case "devices.changed":
            return .ok(.devicesChanged(devices: deviceRoster(object["devices"])), activity: [:])

        case "browser.frame":
            guard let frame = browserFrame(object) else {
                return .failed(reason: "browser.frame without usable geometry or data")
            }
            return .ok(.browserFrame(frame), activity: [:])

        case "browser.surfaces.rows":
            // `rid` is present when it answers a `browser.surfaces` and absent
            // when it is an unsolicited push — the same split `settings.state`
            // and `settings.changed` make, folded onto one case here.
            return .ok(.browserSurfaces(rid: string(object["rid"]),
                                        surfaces: browserSurfaces(object["surfaces"])),
                       activity: [:])

        case "browser.handover.state":
            // The window is the only thing that must be there. A state frame
            // naming no surface cannot be applied to one, and applying it to
            // the wrong surface is a claim button under somebody else's page.
            guard let state = browserHandover(object) else {
                return .failed(reason: "browser.handover.state without a window")
            }
            return .ok(.browserHandover(state), activity: [:])

        case "routines.rows":
            /*
             * Never `.failed`. A machine with no routines is an answer rather
             * than a malformed frame, and one bad row is dropped instead of
             * discarding the list — the rule this codec keeps for every list it
             * reads. See `RoutinesWire`.
             */
            return .ok(.routineRows(routines: WireCodec.routineRows(object),
                                    notice: displayLine(object["notice"])),
                       activity: [:])

        case "routine.text.rows":
            // The id is the one field worth refusing over: it says *which*
            // routine this text belongs to, and two taps two seconds apart must
            // not draw the second answer under the first heading.
            guard let file = WireCodec.routineFile(object) else {
                return .failed(reason: "routine.text.rows without a routine")
            }
            return .ok(.routineFile(file), activity: [:])

        default:
            return .failed(reason: "unknown message type")
        }
    }

    /// One row of the port list, or nil. Exposed for the tests.
    static func localPort(_ value: Any?) -> LocalPort? {
        guard let row = value as? [String: Any],
              let number = port(row["port"]),
              let process = string(row["process"]) else { return nil }
        return LocalPort(port: number, process: process, guessed: (row["guessed"] as? Bool) == true)
    }

    /// A port number, or nil for anything that is not one.
    private static func port(_ value: Any?) -> Int? {
        guard let number = whole(value), number >= 1, number <= 65_535 else { return nil }
        return number
    }

    /**
     * One project's dev server. Exposed for the tests, which check the field
     * rules directly rather than through a whole frame.
     *
     * Two things are refused outright and everything else is read leniently,
     * which is the split the rest of this file makes for the same reason: the
     * two refused fields are what the *row exists to say*, and a row with
     * neither is not a shorter row, it is a row about nothing.
     *
     *  - **A folder.** It is the identity — the key a row is replaced under —
     *    so a frame without one could only ever be filed under a guess.
     *  - **A status this build knows.** All five draw different controls and
     *    there is no honest default among them; mapping an unknown word onto
     *    `idle` would put a Start button under a state nobody here understands.
     *
     * ## Why `port` and `url` are dropped unless the status is `ready`
     *
     * The desktop promises they appear only on `ready`, and tests that promise
     * on its own side. This end enforces it anyway, because it is the one field
     * pair on this frame that does not merely get *drawn*: `port` is handed to
     * `HostLink.openLocalhost`, which opens a tunnel and points a web view at
     * it. The header of this file explains why a client narrows a peer it
     * supposedly trusts — the desktop is not always what answers — and this is
     * that argument at its sharpest. A `starting` row carrying a port from a
     * frame nobody checked is exactly the dead address under a live row that the
     * replace-never-merge rule exists to prevent, arriving from the wire instead
     * of from a merge.
     */
    static func devServerReport(_ value: Any?) -> DevServerReport? {
        guard let row = value as? [String: Any],
              let folder = string(row["folder"]), !folder.isEmpty,
              let word = string(row["status"]),
              let status = DevServerStatus(rawValue: word) else { return nil }
        let ready = status == .ready
        return DevServerReport(folder: folder,
                               status: status,
                               script: displayLine(row["script"]),
                               command: displayLine(row["command"]),
                               sessionId: string(row["sessionId"]).flatMap { SessionID.isValid($0) ? $0 : nil },
                               port: ready ? port(row["port"]) : nil,
                               url: ready ? displayLine(row["url"]) : nil,
                               note: displayLine(row["note"]),
                               message: displayLine(row["message"]))
    }

    /**
     * A string from the wire that a person is about to read, on one line.
     *
     * Every optional field on a `dev.state` goes through here, and it is worth
     * saying why all four rather than only the one the protocol labels
     * untrusted. `note` is bytes a process printed and is the obvious case.
     * `script` and `command` are read out of a `package.json` — a file in a
     * repository that may well have been cloned from a stranger — so they are
     * somebody else's text too. `message` is written by a desktop this phone has
     * authenticated, which makes it the most trustworthy of the four and still
     * not a reason to have a second rule.
     *
     * Two things happen: control characters are removed, and the result is cut
     * to the same 200 characters the desktop caps a note at. Neither is a
     * security boundary — SwiftUI's `Text` draws a string as glyphs and has no
     * markup to be injected with — they are about a row that stays a row. A
     * stray newline turns one line into three and pushes the button off the
     * card; a carriage return from a progress bar leaves a line that reads as
     * gibberish. `\u{7f}` and the C1 block go for the same reason the wire's own
     * `DISPLAY_STRIP` takes them: they are invisible in every editor and render
     * as boxes on a phone.
     *
     * Empty after cleaning reads as absent, so a field the desktop sent as `""`
     * does not become a blank line with space reserved for it.
     */
    static func displayLine(_ value: Any?) -> String? {
        guard let raw = string(value) else { return nil }
        let cleaned = String(raw.unicodeScalars.filter { scalar in
            !(scalar.value <= 0x1f || (scalar.value >= 0x7f && scalar.value <= 0x9f))
        })
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return trimmed.count <= maxDisplayLine ? trimmed : String(trimmed.prefix(maxDisplayLine))
    }

    /// The desktop's own `MAX_NOTE_CHARS`. Repeated rather than trusted, for the
    /// reason every other bound in `Wire` is: a cap that is only enforced by the
    /// other end is not a cap.
    static let maxDisplayLine = 200

    /**
     * Base64, checked before Foundation is allowed to be lenient about it.
     *
     * `Data(base64Encoded:)` is stricter than most decoders — it refuses a
     * length that is not a multiple of four, and it refuses a newline — but it
     * is **not strict about padding**: measured on this toolchain,
     * `Data(base64Encoded: "AA=A")` returns *two bytes* rather than nil, because
     * it stops at the `=` and keeps what it had. Every byte of a tunnelled HTTP
     * response comes through here, so a frame corrupted in exactly that way
     * would reach the browser as a short response body from a dev server that
     * sent a whole one — a bug that looks like the framework's and is not.
     *
     * So the shape is checked here and only then decoded: standard alphabet,
     * length a multiple of four, and nothing after the padding has begun. It
     * mirrors the rule `parseClientMessage` applies to the same field coming the
     * other way, which is the point — one wire, one definition of valid.
     */
    static func strictBase64(_ text: String) -> Data? {
        guard text.utf8.count % 4 == 0 else { return nil }
        var padding = 0
        for unit in text.utf8 {
            if unit == UInt8(ascii: "=") {
                padding += 1
                continue
            }
            // A body character after the padding has started is what makes the
            // length lie about how many bytes this decodes to.
            if padding > 0 { return nil }
            let alphabet = (unit >= UInt8(ascii: "A") && unit <= UInt8(ascii: "Z"))
                || (unit >= UInt8(ascii: "a") && unit <= UInt8(ascii: "z"))
                || (unit >= UInt8(ascii: "0") && unit <= UInt8(ascii: "9"))
                || unit == UInt8(ascii: "+") || unit == UInt8(ascii: "/")
            if !alphabet { return nil }
        }
        guard padding <= 2 else { return nil }
        return Data(base64Encoded: text)
    }

    /// One session row, or nil. Exposed for the tests, which check the lenient
    /// row handling directly rather than through a whole frame.
    static func decodeSession(_ value: Any?) -> RemoteSession? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let title = string(row["title"]),
              let cwd = string(row["cwd"]),
              let provider = string(row["provider"]),
              let status = string(row["status"]) else { return nil }
        let exitCode: Int?
        if row["exitCode"] is NSNull || row["exitCode"] == nil {
            exitCode = nil
        } else if let code = whole(row["exitCode"]) {
            exitCode = code
        } else {
            return nil
        }
        return RemoteSession(id: id, title: title, cwd: cwd, provider: provider, status: status, exitCode: exitCode)
    }

    // MARK: - Outbound

    /// Mirrors `serialize`/`encode`: the single choke point that puts a shape on
    /// the wire, so no stray call site can invent one the desktop has never been
    /// told about.
    static func encode(_ message: ClientMessage) -> String {
        let object: [String: Any]
        switch message {
        case let .hello(version, token, device, capabilities):
            object = [
                "t": "hello",
                "protocol": version,
                "token": token,
                "device": ["name": device.name, "platform": device.platform],
                // Always written, even when empty. A desktop old enough not to
                // read the field ignores it, and one that reads it gets a
                // definite answer rather than having to treat "absent" and
                // "nothing" as the same thing on a frame it may act on
                // immediately.
                "capabilities": capabilities,
            ]
        case .list:
            object = ["t": "list"]
        case let .create(folder, size):
            // Built up rather than written as four literals: the fields are
            // independently optional on the wire, and the desktop's parser
            // reads "both sizes or neither, never one" — a `create` carrying
            // only `cols` is refused as `bad-message` and closes the socket.
            var request: [String: Any] = ["t": "create"]
            if let folder, !folder.isEmpty { request["cwd"] = folder }
            if let size {
                request["cols"] = size.cols
                request["rows"] = size.rows
            }
            object = request
        case let .browseFolders(path):
            // `path` omitted rather than sent empty when there is none: the host
            // reads absent as "somewhere sensible" and would read `""` as a
            // path, which resolves to the process's working directory — a folder
            // nobody asked for and which is not on the picker's way anywhere.
            if let path, !path.isEmpty {
                object = ["t": "folders.browse", "path": path]
            } else {
                object = ["t": "folders.browse"]
            }
        case .browserProfiles:
            object = ["t": "browser.profiles"]
        case let .browserProfileUse(id):
            object = ["t": "browser.profile.use", "id": id]
        case let .browserProfileClear(id):
            object = ["t": "browser.profile.clear", "id": id]
        case let .filesList(path):
            object = ["t": "files.list", "path": path]
        case let .filesRead(path, at, max):
            var ask: [String: Any] = ["t": "files.read", "path": path]
            if let at { ask["at"] = at }
            if let max { ask["max"] = max }
            object = ask
        case let .gitStatus(path):
            object = ["t": "git.status", "path": path]
        case let .gitDiff(path, file, staged):
            object = ["t": "git.diff", "path": path, "file": file, "staged": staged]
        case let .panelAct(panel, action, path, id, fields):
            var ask: [String: Any] = ["t": "panel.act", "panel": panel, "action": action]
            if let path { ask["path"] = path }
            if let id { ask["id"] = id }
            // An empty form is omitted rather than sent as `{}`: the host's
            // parser treats an absent `fields` and an empty one identically, and
            // the smaller frame is the one that describes what happened.
            if !fields.isEmpty { ask["fields"] = fields }
            object = ask
        case .machineWindows:
            object = ["t": "browser.windows"]
        case let .machineWindowOpen(url, profile, isolated, session):
            var ask: [String: Any] = ["t": "browser.window.open"]
            if let url { ask["url"] = url }
            if let profile { ask["profile"] = profile }
            if isolated { ask["isolated"] = true }
            // Omitted rather than sent empty, exactly as `bind` omits it: the
            // host reads an absent session as *do not attach this to anything*
            // and an empty string as a session it does not know, which is a
            // refusal with a window already open on somebody's screen.
            if let session { ask["session"] = session }
            object = ask
        case let .machineWindowGo(id, url):
            object = ["t": "browser.window.go", "id": id, "url": url]
        case let .machineWindowAct(id, action):
            object = ["t": "browser.window.act", "id": id, "action": action.rawValue]
        case let .machineWindowSize(id, width, height):
            /*
             * **Clamped here as well as on the host, and for a different reason
             * from the one `machineWindowPick` clamps for.**
             *
             * Wider clamps because an out-of-range `up` would *close the socket*:
             * that check lives in the host's parser and `server.ts` answers a
             * parse failure by dropping the connection. This one cannot do that —
             * the host clamps both numbers rather than refusing them, on purpose,
             * because they come from a viewer measuring its own pane and a
             * rotation must never cost somebody their terminals.
             *
             * It is here for honesty instead. A screen that asks for 12 and is
             * silently given 240 has a page laid out at a width it does not know
             * about, and the fit arithmetic it does with the frames that come
             * back is then wrong about the thing in front of it. Clamping on this
             * side means what was asked for is what was asked for.
             */
            let w = min(max(MachineBrowserWire.minPageWidth, width), MachineBrowserWire.maxPageWidth)
            let h = min(max(MachineBrowserWire.minPageHeight, height), MachineBrowserWire.maxPageHeight)
            object = ["t": "browser.window.size", "id": id, "width": w, "height": h]
        case let .machineWindowBind(id, session):
            var ask: [String: Any] = ["t": "browser.window.bind", "id": id]
            if let session { ask["session"] = session }
            object = ask
        case let .machineWindowShot(id, session, note):
            var ask: [String: Any] = ["t": "browser.window.shot", "id": id]
            if let session { ask["session"] = session }
            if let note, !note.isEmpty { ask["note"] = note }
            object = ask
        case let .machineWindowSteps(id):
            object = ["t": "browser.window.steps", "id": id]
        case let .machineWindowPick(id, x, y, up):
            var ask: [String: Any] = ["t": "browser.window.pick", "id": id, "x": x, "y": y]
            /*
             * **Clamped here, and this is the line that keeps the socket open.**
             *
             * The host validates `up` in its parser, and `server.ts` answers a
             * parse failure by closing the connection — not by refusing the
             * frame. So a Wider pressed past the top of a very deep document
             * would not draw a sentence, it would drop the terminals, the cast
             * and everything else riding this socket. The screen clamps too;
             * this is the second lock, on the last line before the wire.
             *
             * Zero is omitted because absent already means *the element that was
             * hit*, and the smaller frame is the one that describes what
             * happened.
             */
            let walk = min(max(0, up), MachineBrowserWire.maxPickUp)
            if walk > 0 { ask["up"] = walk }
            object = ask
        case let .panelRead(panel, path, scope, query):
            // `path` omitted rather than sent empty when there is none: the host
            // reads absent as "somewhere sensible" and would read `""` as a path.
            var ask: [String: Any] = ["t": "panel.read", "panel": panel]
            if let path, !path.isEmpty { ask["path"] = path }
            // The same rule for both filters, and it is load-bearing rather than
            // tidy: the host reads an absent scope as *the panel's default* and
            // an empty string as a scope it does not know, which is a refusal.
            if let scope, !scope.isEmpty { ask["scope"] = scope }
            if let query, !query.isEmpty { ask["query"] = query }
            object = ask
        case let .close(id):
            object = ["t": "close", "id": id]
        case let .rename(id, title):
            object = ["t": "rename", "id": id, "title": title]
        case let .attach(id, size):
            if let size {
                object = ["t": "attach", "id": id, "cols": size.cols, "rows": size.rows]
            } else {
                object = ["t": "attach", "id": id]
            }
        case let .detach(id):
            object = ["t": "detach", "id": id]
        case let .input(id, data):
            object = ["t": "input", "id": id, "data": data]
        case let .resize(id, cols, rows):
            object = ["t": "resize", "id": id, "cols": cols, "rows": rows]
        case .ping:
            object = ["t": "ping"]
        case .ports:
            object = ["t": "ports"]
        case let .tunnelOpen(id, port):
            object = ["t": "tunnel.open", "id": id, "port": port]
        case let .tunnelClose(id):
            object = ["t": "tunnel.close", "id": id]
        case let .webOpen(url):
            object = ["t": "web.open", "url": url]
        case let .netOpen(ch, tunnel):
            object = ["t": "net.open", "ch": ch, "tunnel": tunnel]
        case let .netData(ch, data):
            // The one place bytes become base64. Everything above this holds
            // `Data`, so no call site can send a string it has already encoded
            // — or forget to.
            object = ["t": "net.data", "ch": ch, "data": data.base64EncodedString()]
        case let .netAck(ch, bytes):
            object = ["t": "net.ack", "ch": ch, "bytes": bytes]
        case let .netClose(ch):
            object = ["t": "net.close", "ch": ch]
        case let .devStatus(folder):
            object = ["t": "dev.status", "folder": folder]
        case let .devStart(folder):
            object = ["t": "dev.start", "folder": folder]
        case let .uploadBegin(id, name, size):
            object = ["t": "upload.begin", "id": id, "name": name, "size": size]
        case let .uploadData(id, data):
            // The one place file bytes become base64, for the same reason
            // `netData` is: no call site above this can send a string it has
            // already encoded — or forget to.
            object = ["t": "upload.data", "id": id, "data": data.base64EncodedString()]
        case let .uploadEnd(id, digest):
            object = ["t": "upload.end", "id": id, "sha256": digest]
        case let .uploadCancel(id):
            object = ["t": "upload.cancel", "id": id]
        case let .credentialAck(id):
            object = ["t": "credential.ack", "id": id]
        case let .credentialAnswer(id, username, password, remember):
            var answer: [String: Any] = ["t": "credential.answer", "id": id,
                                         "username": username, "password": password]
            // Written only when true. `parseClientMessage` reads it as
            // `remember === true`, so a `false` on the wire would be a field
            // that says nothing while carrying somebody's consent as its name —
            // and this is the one frame worth being literal on.
            if remember { answer["remember"] = true }
            object = answer
        case let .credentialDeny(id, reason):
            object = ["t": "credential.deny", "id": id, "reason": reason.rawValue]

        /*
         * The copilot verbs. Note what is *not* in any of them: a tool id, an
         * argument object, a session to act on, a folder. The only field this
         * phone ever composes is `text` — prose — and `limit`/`before`, which
         * are a page size and a row id it was given. `CopilotWireTests` pins
         * that, because the first convenience feature anybody asks for here
         * ("tap that row to run it again") breaks the property the whole
         * enforcement model rests on.
         */
        case .copilotHello:
            // A verb and nothing else. What authorises it is the device identity
            // this socket already proved and the kind that device was approved
            // as — see `ClientMessage.copilotHello`, which carries the sentence
            // that deleted the credential it used to hold.
            object = ["t": "copilot.hello"]
        case .copilotBye:
            object = ["t": "copilot.bye"]
        case let .copilotAnswer(id, approved):
            // `approved` is written either way, unlike `remember` on a
            // credential answer. There it is a scope the desktop reads as
            // `=== true`, so a `false` would be a field saying nothing; here it
            // *is* the decision, and a refusal that travelled as an absence
            // would be a refusal one lenient parser away from being an approval.
            object = ["t": "copilot.answer", "id": id, "approved": approved]
        case .copilotAttach:
            object = ["t": "copilot.attach"]
        case .copilotDetach:
            object = ["t": "copilot.detach"]
        case .copilotState:
            object = ["t": "copilot.state"]
        case .copilotSessions:
            object = ["t": "copilot.sessions"]
        case let .copilotLog(limit, before):
            var request: [String: Any] = ["t": "copilot.log", "limit": limit]
            // Written only when there is one. A `before: null` would be a field
            // whose name says "page backwards from here" carrying nothing to
            // page from, and the desktop's parser reads absence as "the tail".
            if let before, !before.isEmpty { request["before"] = before }
            object = request
        case .copilotPending:
            object = ["t": "copilot.pending"]
        case .copilotStart:
            object = ["t": "copilot.start"]
        case let .copilotSay(text):
            object = ["t": "copilot.say", "text": text]
        case .copilotCancel:
            object = ["t": "copilot.cancel"]
        case .copilotStop:
            object = ["t": "copilot.stop"]

        /*
         * The copilot's files. Note what is *not* in any of them, once more: a
         * path. Every `id` is one of four words or `memory:` and a name, and the
         * desktop resolves it by looking it up rather than by joining it — see
         * `ClientMessage.copilotFiles` for the whole argument.
         *
         * Nothing here checks the id before sending. `CopilotLink` will not build
         * one of these except out of a row the desktop itself sent, and the
         * desktop refuses an id it does not know with a sentence; a check here
         * would be a third copy of a rule that already has two.
         */
        case .copilotFiles:
            object = ["t": "copilot.files"]
        case let .copilotReadFile(id):
            object = ["t": "copilot.file.read", "id": id]
        case let .copilotWriteFile(id, text):
            object = ["t": "copilot.file.write", "id": id, "text": text]
        case let .copilotResetFile(id):
            object = ["t": "copilot.file.reset", "id": id]
        case let .copilotForgetMemory(name):
            object = ["t": "copilot.memory.delete", "name": name]

        case let .usageRead(rid, id, want, force):
            object = ["t": "usage.read", "rid": rid, "id": id, "want": want.rawValue, "force": force]
        case let .accountRead(rid, id):
            object = ["t": "account.read", "rid": rid, "id": id]
        case let .accountSwitch(rid, id, accountId):
            object = ["t": "account.switch", "rid": rid, "id": id, "accountId": accountId]
        case let .enroll(version, device, username, secret, method, capabilities):
            object = [
                "t": "enroll",
                "protocol": version,
                "device": ["name": device.name, "platform": device.platform],
                "username": username,
                "secret": secret,
                "method": method.rawValue,
                // Always written, even when empty, for the reason `hello`'s is —
                // a definite answer beats "absent" on a frame the far end may act
                // on before the follow-up hello.
                "capabilities": capabilities,
            ]

        case let .controlsRead(rid, id):
            object = ["t": "controls.read", "rid": rid, "id": id]
        case let .controlsApply(rid, id, control, value):
            object = ["t": "controls.apply", "rid": rid, "id": id, "control": control.rawValue, "value": value]

        case let .settingsRead(rid):
            object = ["t": "settings.read", "rid": rid]
        case let .settingsApply(rid, key, value):
            object = ["t": "settings.apply", "rid": rid, "key": key.rawValue, "value": value]

        case let .devicesList(rid):
            object = ["t": "devices.list", "rid": rid]
        case let .devicesRevoke(rid, device):
            object = ["t": "devices.revoke", "rid": rid, "device": device]

        case let .browserWatch(window, maxWidth, quality):
            object = ["t": "browser.watch", "window": window, "maxWidth": maxWidth, "quality": quality]
        case let .browserUnwatch(window):
            object = ["t": "browser.unwatch", "window": window]
        case let .browserFrameAck(window, seq):
            object = ["t": "browser.frame.ack", "window": window, "seq": seq]
        case let .browserInput(window, seq, input):
            object = encodeBrowserInput(window: window, seq: seq, input: input)
        case let .browserSurfaces(rid):
            object = ["t": "browser.surfaces", "rid": rid]
        case let .browserHandoverTake(rid, window):
            object = ["t": "browser.handover.take", "rid": rid, "window": window]
        case let .browserHandoverDone(rid, window, carryOn):
            // `carryOn` is written always and never defaulted away, because the
            // host refuses a `done` that does not carry it — the two answers end
            // in different places and a frame that forgot to say which is one
            // whose meaning the far side would be inventing.
            object = ["t": "browser.handover.done", "rid": rid, "window": window, "carryOn": carryOn]

        /*
         * The routines verbs. Note what is not in any of them, for the same
         * reason the copilot's list says so: no file, no folder, no text to
         * write. The only field this phone ever composes is `reason` — prose,
         * for a person to read later — and `id`, which came off a row the machine
         * itself sent in the last `routines.rows`. That is what makes them safe
         * to send: the phone can only name a routine it was handed.
         */
        case .routines:
            object = ["t": "routines"]
        case let .routineText(id):
            object = ["t": "routine.text", "id": id]
        case let .routineRun(id):
            object = ["t": "routine.run", "id": id]
        case let .routinePause(id, reason):
            var ask: [String: Any] = ["t": "routine.pause", "id": id]
            // Omitted rather than sent empty. The machine writes its own sentence
            // for a hold with no reason, and an empty string would replace that
            // sentence with a blank on the card its owner reads later.
            if let reason, !reason.isEmpty { ask["reason"] = String(reason.prefix(RoutinesWire.maxPauseReason)) }
            object = ask
        case let .routineResume(id):
            object = ["t": "routine.resume", "id": id]
        case let .routineDelete(id):
            object = ["t": "routine.delete", "id": id]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            // Unreachable: every branch above builds strings, ints and one flat
            // dictionary. Falling back to a frame the desktop will refuse is
            // still better than a crash on the send path.
            return "{\"t\":\"ping\"}"
        }
        return text
    }

    static func hello(token: String, device: DeviceDescriptor,
                      capabilities: [String] = WireCapability.claimed) -> ClientMessage {
        .hello(protocolVersion: Wire.protocolVersion, token: token, device: device,
               capabilities: capabilities)
    }

    /**
     * Split a paste into frames the desktop will accept.
     *
     * `parseClientMessage` rejects an `input` frame over `MAX_INPUT_BYTES` and
     * the desktop answers a rejected frame by closing the socket. A paste is the
     * one realistic way a phone exceeds it — pasting a stack trace into a prompt
     * is a normal thing to do — and losing the connection over it would look
     * like the network dropping rather than like something this client did.
     *
     * Cut on Unicode scalar boundaries, which is what the JavaScript client's
     * `for (const point of data)` iterates. Cutting on UTF-16 units instead
     * would eventually split a surrogate pair and put two replacement characters
     * into somebody's prompt.
     */
    static func chunkInput(_ data: String, maxBytes: Int = Wire.maxInputBytes) -> [String] {
        if data.isEmpty { return [] }
        if data.utf8.count <= maxBytes { return [data] }

        var out: [String] = []
        var current = String.UnicodeScalarView()
        var bytes = 0
        for scalar in data.unicodeScalars {
            let size = utf8Cost(scalar)
            if bytes + size > maxBytes && !current.isEmpty {
                out.append(String(current))
                current = String.UnicodeScalarView()
                bytes = 0
            }
            current.append(scalar)
            bytes += size
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// UTF-8 cost of one scalar, matching `costOf` in `protocol.ts`.
    private static func utf8Cost(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0 ..< 0x80: return 1
        case 0x80 ..< 0x800: return 2
        case 0x800 ..< 0x1_0000: return 3
        default: return 4
        }
    }

    // MARK: - Narrowing helpers

    /*
     * `string` and `whole` are internal rather than private, and the two below
     * them are not.
     *
     * Swift's `private` is file-scoped, and the copilot frames are decoded by an
     * extension of this type in `CopilotWire.swift` — a second file, because
     * that half of the wire is a grant, five value types and seventeen frames
     * and would have doubled this one. Those decoders need the same answer to
     * "is this a string" and "is this a whole number" that every frame here
     * gets: two definitions of that is two definitions that will eventually
     * disagree, on a wire where one of them guards a countdown and the other
     * guards a port.
     *
     * `capabilities` and `folders` stay private because they are read off
     * exactly one frame and nothing outside this file has any business
     * inventing a second caller for them.
     */
    static func string(_ value: Any?) -> String? {
        // `as? String` alone would accept an NSNumber bridged through
        // JSONSerialization in some cases; the explicit NSNull check keeps a
        // null out of a field the UI will print.
        guard !(value is NSNull) else { return nil }
        return value as? String
    }

    /// Whole numbers only. JSONSerialization hands back an NSNumber for every
    /// JSON number, and `as? Int` on a 1.5 truncates rather than refusing — so a
    /// broken `cols` would arrive as a plausible one.
    static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !(value is NSNull) else { return nil }
        // Bools bridge to NSNumber too, and `true` must not read as 1.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(.towardZero),
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    /**
     * What the desktop says it can do, ignoring anything it says badly.
     *
     * Absent is the answer every shipping desktop gives, and it means "protocol
     * v1 only" rather than "unknown" — so it is an empty set, not a nil, and the
     * UI that reads it hides features rather than guessing at them. A malformed
     * entry is dropped rather than failing the whole `welcome`, for the same
     * reason one bad session row does not discard a session list.
     */
    private static func capabilities(_ value: Any?) -> Set<String> {
        guard let rows = value as? [Any] else { return [] }
        return Set(rows.compactMap { string($0) }.filter { !$0.isEmpty && $0.count <= 32 })
    }

    /**
     * The folders this device may start a session in, or nil when the desktop
     * did not say.
     *
     * **Nil and empty are different answers and the difference is the whole
     * feature.** A desktop that predates per-device folder grants sends no such
     * field, and the honest reading of that is "I have not told you", which
     * leaves the phone with the list it assembled from the sessions it can see.
     * A desktop that sends `[]` is saying a person granted this device nothing,
     * and drawing a picker over that would be offering taps that can only be
     * refused. `[] as? [Any]` decodes both to an empty array, which is exactly
     * why this is not `Codable`.
     *
     * Blank strings are dropped rather than failing the frame — the same
     * leniency one bad session row gets — and the list is capped, because it is
     * drawn into a menu and a host that sent ten thousand paths would be a
     * phone that stopped responding.
     */
    private static func folders(_ value: Any?) -> [String]? {
        guard let rows = value as? [Any] else { return nil }
        return rows.compactMap { string($0) }.filter { !$0.isEmpty }.prefix(100).map { $0 }
    }

    /**
     * What a machine calls itself, cleaned.
     *
     * Bounded at the same sixty-four the wire bounds it at, and stripped of
     * control characters for the reason every display string from another
     * machine is: this lands on a switcher chip beside terminal output, and an
     * escape sequence in it would repaint the screen around the name.
     *
     * Empty reads as **absent**, which is not the same as the empty string: a
     * machine that sent a name made only of control characters said nothing, and
     * a phone that stored the result would have written it over a good name.
     */
    private static func hostName(_ value: Any?) -> String? {
        guard let raw = string(value) else { return nil }
        let cleaned = raw.filter { !$0.unicodeScalars.contains { scalar in scalar.properties.generalCategory == .control } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        return String(cleaned.prefix(64))
    }

    private struct DecodedList {
        var sessions: [RemoteSession]
        var activity: [String: Double]
    }

    private static func sessionList(_ value: Any?) -> DecodedList? {
        guard let rows = value as? [Any] else { return nil }
        var sessions: [RemoteSession] = []
        var activity: [String: Double] = [:]
        for row in rows {
            guard let session = decodeSession(row) else { continue }
            sessions.append(session)
            if let at = lastActivity(row) { activity[session.id] = at }
        }
        return DecodedList(sessions: sessions, activity: activity)
    }

    /**
     * When the desktop last saw this session do anything, if it says.
     *
     * Read defensively rather than declared, because the desktop has this value
     * already — in `session-activity.ts` — and simply does not put it on the
     * wire yet. Reading it here means the list gets better the day it does,
     * with no change on this side; until then the row prints nothing rather
     * than inventing a time.
     */
    private static func lastActivity(_ value: Any?) -> Double? {
        guard let row = value as? [String: Any],
              let number = row["lastActivityAt"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let at = number.doubleValue
        return at.isFinite && at > 0 ? at : nil
    }
}
