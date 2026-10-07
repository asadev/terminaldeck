import Foundation
import TerminalDeckNativeCore

public struct BackendDeckToolsMachinesDeviceTreeAnswer: Sendable {
    public let tree: DeviceTree
    public let foreground: NativeRPCValue
    public let fallback: String
    public init(tree: DeviceTree, foreground: NativeRPCValue, fallback: String = "") { self.tree = tree; self.foreground = foreground; self.fallback = fallback }
}
/// The single DeviceManager owns its engine, open sessions, boot and idle handling.
/// Inventory/details/screenshots/rounds keep their existing JSON shapes.
public protocol BackendDeckToolsMachinesDeviceService: Sendable {
    func unavailable() async -> String?
    func list() async throws -> [NativeRPCValue]
    func boot(_ id: String) async throws -> NativeRPCValue
    func shutDown(_ id: String) async throws -> NativeRPCValue
    func open(_ id: String) async throws -> NativeRPCValue
    func screenshot(_ id: String) async throws -> NativeRPCValue
    func tap(_ id: String, x: Double, y: Double, holdMS: Int?) async throws
    func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMS: Int) async throws
    func type(_ id: String, text: String) async throws
    func key(_ id: String, key: String, modifiers: [String]) async throws
    func button(_ id: String, button: String) async throws
    func rotate(_ id: String, to: String) async throws -> String
    func tree(_ id: String, scope: String) async throws -> BackendDeckToolsMachinesDeviceTreeAnswer
    func rounds() async throws -> [NativeRPCValue]
}
/// Explicit absent service: list reports why, annotations fails because no store was supplied.
public struct BackendDeckToolsMachinesUnavailableDevices: BackendDeckToolsMachinesDeviceService {
    public init() {}
    public func unavailable() -> String? { "The native device engine has not been supplied." }
    private func missing(_ action: String) -> NativeRPCError { BackendDeckToolsSupport.unavailable("devices.\(action)") }
    public func list() throws -> [NativeRPCValue] { throw missing("list") }
    public func boot(_ id: String) throws -> NativeRPCValue { throw missing("open") }
    public func shutDown(_ id: String) throws -> NativeRPCValue { throw missing("shutdown") }
    public func open(_ id: String) throws -> NativeRPCValue { throw missing("open") }
    public func screenshot(_ id: String) throws -> NativeRPCValue { throw missing("screenshot") }
    public func tap(_ id: String, x: Double, y: Double, holdMS: Int?) throws { throw missing("tap") }
    public func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMS: Int) throws { throw missing("swipe") }
    public func type(_ id: String, text: String) throws { throw missing("type") }
    public func key(_ id: String, key: String, modifiers: [String]) throws { throw missing("type") }
    public func button(_ id: String, button: String) throws { throw missing("button") }
    public func rotate(_ id: String, to: String) throws -> String { throw missing("button") }
    public func tree(_ id: String, scope: String) throws -> BackendDeckToolsMachinesDeviceTreeAnswer { throw missing("tree") }
    public func rounds() throws -> [NativeRPCValue] { throw missing("annotations") }
}

public enum BackendDeckToolsMachinesDeviceRules {
    public typealias V = NativeRPCValue
    typealias S = BackendDeckToolsMachinesShared
    public struct Selector: Sendable { public let name: String?; public let identifier: String?; public let role: String?; public let partial: Bool }
    public static let buttons = ["home", "back", "overview", "lock", "volume-up", "volume-down", "action"]
    public static let keys = ["delete", "return", "enter", "tab", "escape", "arrow-up", "arrow-down", "arrow-left", "arrow-right", "select-all"]
    public static let orientations = ["portrait", "landscape-left", "landscape-right", "portrait-upside-down"]
    static let scaffold: Set<String> = ["", "application", "window", "group", "unknown", "other", "scroll area", "layout area", "frame layout", "linear layout", "relative layout", "constraint layout", "view", "view group"]
    public static func id(_ args: V) throws -> String {
        let raw = args["deviceId"]
        guard let id = raw.string, id.range(of: #"^(ios|android|avd):[A-Za-z0-9._:-]{1,120}$"#, options: .regularExpression) != nil else {
            let text: String
            if let value = raw.string { text = V.string(value.utf16.count > 60 ? BackendDeckToolsSupport.slice(value, 0, 60) + "…" : value).compact }
            else { text = raw == .missing ? "undefined" : raw.compact }
            throw S.refused("deviceId \(text) is not a device this app listed. Call devices.list first and pass one of its ids (they look like ios:…, android:… or avd:…).")
        }; return id
    }
    public static func fraction(_ where_: String, _ raw: V) throws -> Double {
        guard let number = raw.number, number.isFinite else { throw S.refused("\(where_) must be a number from 0 to 1") }
        guard number >= 0 && number <= 1 else { throw S.refused("\(where_) is \(raw.compact), and positions are fractions of the screen from 0 to 1 — 0.5 is the middle." + (number > 1 ? " That looks like pixels: divide by the screen’s width or height, or take a centre from devices.tree." : "")) }; return number
    }
    public static func point(_ name: String, _ raw: V) throws -> V {
        guard let fields = raw.fields else { throw S.refused("\(name) must be an object like {\"x\": 0.5, \"y\": 0.5}") }
        let extra = fields.map(\.key).filter { $0 != "x" && $0 != "y" }
        if !extra.isEmpty { throw S.refused("\(name) takes only x and y, not \(extra.joined(separator: ", "))") }
        return S.object(["x": .number(try fraction(name + ".x", raw["x"])), "y": .number(try fraction(name + ".y", raw["y"]))])
    }
    static func optText(_ args: V, _ key: String) throws -> String? {
        if args[key].isNullish || args[key].string == "" { return nil }; guard let text = args[key].string else { throw S.refused("\(key) must be a string") }; return text
    }
    public static func selector(_ args: V) throws -> Selector? {
        let name = try optText(args, "name"), identifier = try optText(args, "identifier"), role = try optText(args, "role")
        if name == nil && identifier == nil && role == nil { if args["partial"] != .missing { throw S.refused("partial goes with a name") }; return nil }
        return Selector(name: name, identifier: identifier, role: role, partial: args["partial"].bool == true)
    }
    static func clip(_ value: String, max: Int = 200) -> String {
        let one = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return one.utf16.count > max ? BackendDeckToolsSupport.slice(one, 0, max - 1) + "…" : one
    }
    static func words(_ query: Selector) -> String {
        var parts = [query.role.map { BackendDeckToolsSupport.slice(clip($0), 0, 40) } ?? "element"]
        if let name = query.name { parts.append((query.partial ? "containing " : "") + "\"" + BackendDeckToolsSupport.slice(clip(name), 0, 60) + "\"") }
        if let id = query.identifier { parts.append("with identifier " + BackendDeckToolsSupport.slice(clip(id), 0, 60)) }; return parts.joined(separator: " ")
    }
    public static func onScreen(_ node: DeviceNode) -> Bool {
        guard node.hidden != true, let rect = node.usableFrame else { return false }
        let x = rect.x + rect.width / 2, y = rect.y + rect.height / 2; return x >= 0 && x <= 1 && y >= 0 && y <= 1
    }
    public static func element(_ node: DeviceNode) -> V {
        var fields: [String: V] = [:]
        let role = DeviceTreeQuery.plainRole(node.role), identifier = [node.identifier, node.testID].compactMap { $0 }.first { !$0.isEmpty } ?? "", name = clip(DeviceTreeQuery.nodeName(node))
        if !role.isEmpty { fields["role"] = .string(role) }; if !name.isEmpty && name != identifier { fields["name"] = .string(name) }; if !identifier.isEmpty { fields["identifier"] = .string(clip(identifier)) }
        if node.valueRedacted { fields["secret"] = .bool(true) } else if let value = node.value, !value.isEmpty, clip(value) != name { fields["value"] = .string(clip(value)) }
        if node.enabled == false { fields["enabled"] = .bool(false) }; if node.focused == true { fields["focused"] = .bool(true) }
        if let rect = node.usableFrame {
            fields["frame"] = S.object(["x": .number(round3(rect.x)), "y": .number(round3(rect.y)), "width": .number(round3(rect.width)), "height": .number(round3(rect.height))])
            if onScreen(node), let point = DeviceTreeQuery.centre(of: node) { fields["centre"] = S.object(["x": .number(round3(point.x)), "y": .number(round3(point.y))]) } else { fields["offScreen"] = .bool(true) }
        }
        if let component = node.component, !component.isEmpty { fields["component"] = .string(component) }
        if let source = node.sourceLocation { var text = source.file; if let line = source.line, line != 0 { text += ":\(line)"; if let col = source.column, col != 0 { text += ":\(col)" } }; fields["source"] = .string(text) }
        return S.object(fields)
    }
    static func round3(_ value: Double) -> Double { floor(value * 1_000 + 0.5) / 1_000 }
    private static func shown(_ node: DeviceNode, _ level: Int = 0) -> DeviceNode? {
        guard level <= 200, node.hidden != true else { return nil }; var result = node; result.children = node.children.compactMap { shown($0, level + 1) }; return result
    }
    public static func find(_ root: DeviceNode, _ query: Selector, shownOnly: Bool = true) -> [DeviceNode] {
        let search: DeviceNode
        if shownOnly { guard let visible = shown(root) else { return [] }; search = visible } else { search = root }
        func fold(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let name = fold(query.name), identifier = fold(query.identifier), role = fold(query.role)
        return DeviceTreeQuery.flatten(search).filter { node in
            if !identifier.isEmpty && fold(node.identifier) != identifier && fold(node.testID) != identifier { return false }
            if !role.isEmpty && fold(node.role) != role && DeviceTreeQuery.plainRole(node.role) != role { return false }
            if !name.isEmpty { let words = [node.label, node.title, node.text, node.valueRedacted ? nil : node.value, node.placeholder].map(fold); if !words.contains(where: { query.partial ? $0.contains(name) : $0 == name }) { return false } }
            return !name.isEmpty || !identifier.isEmpty || !role.isEmpty
        }
    }
    public static func distinct(_ nodes: [DeviceNode]) -> [DeviceNode] {
        var kept: [DeviceNode] = []
        for node in nodes { guard let centre = DeviceTreeQuery.centre(of: node) else { continue }; if !kept.contains(where: { other in guard let p = DeviceTreeQuery.centre(of: other) else { return false }; return abs(p.x - centre.x) <= 0.005 && abs(p.y - centre.y) <= 0.005 }) { kept.append(node) } }; return kept
    }
    static func candidate(_ node: DeviceNode) -> String {
        let value = element(node), name = value["name"].string.map { " \"" + BackendDeckToolsSupport.slice($0, 0, 60) + "\"" } ?? "", identifier = value["identifier"].string.map { " (identifier " + BackendDeckToolsSupport.slice($0, 0, 60) + ")" } ?? ""
        let position = value["centre"].isNullish ? " with no position on the screen" : " at x \(value["centre"]["x"].compact), y \(value["centre"]["y"].compact)"
        return (value["role"].string ?? "element") + name + identifier + position
    }
    public static func resolveOne(_ root: DeviceNode, _ query: Selector) throws -> DeviceNode {
        let all = find(root, query, shownOnly: false), places = distinct(find(root, query).filter(onScreen)), wanted = words(query)
        if places.count == 1 { return places[0] }
        if places.count > 1 { throw S.refused("\(places.count) different elements on the screen match the \(wanted): \(places.prefix(5).map(candidate).joined(separator: "; ")). Nothing was tapped. Add an identifier or a role to pick one, or tap its centre with x and y.") }
        if !all.isEmpty { throw S.refused("The \(wanted) is in the screen’s tree but not somewhere a finger can reach — it is hidden or scrolled away. Nothing was tapped. Scroll with devices.swipe and try again.") }
        let near = query.name != nil && !query.partial ? distinct(find(root, Selector(name: query.name, identifier: query.identifier, role: query.role, partial: true)).filter(onScreen)) : []
        throw S.refused("Nothing on the screen matches the \(wanted). Nothing was tapped. " + (near.isEmpty ? "Names are matched whole and ignoring case; call devices.tree to see what is there." : "Close: \(near.prefix(5).map(candidate).joined(separator: "; "))."))
    }
    public static func listElements(_ root: DeviceNode, limit: Int) -> (rows: [V], total: Int) {
        var rows: [V] = [], total = 0
        func visit(_ node: DeviceNode, _ depth: Int, _ level: Int) {
            guard level <= 200, node.hidden != true else { return }
            let named = [node.label, node.title, node.text, node.identifier, node.testID, node.placeholder, node.valueRedacted ? nil : node.value].contains { !($0 ?? "").isEmpty }
            let listed = named || !scaffold.contains(DeviceTreeQuery.plainRole(node.role))
            if listed { total += 1; if rows.count < limit { rows.append(element(node).setting("depth", .number(Double(depth)))) } }
            for child in node.children { visit(child, listed ? depth + 1 : depth, level + 1) }
        }; visit(root, 0, 0); return (rows, total)
    }
    public static func hold(_ args: V) throws -> Int? { if args["holdMs"].isNullish { return nil }; guard let n = args["holdMs"].number, n.isFinite, n >= 0 else { throw S.refused("holdMs must be a number of milliseconds") }; return Int(min(n.rounded(.towardZero), 5_000)) }
    public static func tapTarget(_ args: V) throws -> (point: V?, selector: Selector?) {
        let x = !args["x"].isNullish, y = !args["y"].isNullish, query = try selector(args)
        if (x || y) && query != nil { throw S.refused("Give x and y, or a name/identifier/role — not both.") }
        if x != y { throw S.refused("A position needs both x and y.") }
        if x { return (S.object(["x": .number(try fraction("x", args["x"])), "y": .number(try fraction("y", args["y"]))]), nil) }
        guard let query else { throw S.refused("Say where to tap: x and y as fractions of the screen, or the name, identifier or role of the element.") }; return (nil, query)
    }
    public static func directionPath(_ direction: String) -> (from: V, to: V) {
        let pairs: [String: [Double]] = ["up": [0.5, 0.75, 0.5, 0.25], "down": [0.5, 0.25, 0.5, 0.75], "left": [0.75, 0.5, 0.25, 0.5], "right": [0.25, 0.5, 0.75, 0.5]]
        let pair = pairs[direction] ?? pairs["up"]!
        return (S.object(["x": .number(pair[0]), "y": .number(pair[1])]), S.object(["x": .number(pair[2]), "y": .number(pair[3])]))
    }
    public static func swipe(_ args: V) throws -> (from: V, to: V, duration: Int, direction: String?) {
        var duration = 300
        if !args["durationMs"].isNullish { guard let n = args["durationMs"].number, n.isFinite else { throw S.refused("durationMs must be a number of milliseconds") }; duration = Int(min(max(n.rounded(.towardZero), 50), 5_000)) }
        let direction = args["direction"].string, points = args["from"] != .missing || args["to"] != .missing
        if direction != nil && points { throw S.refused("Give a direction, or from and to — not both.") }
        if let direction { guard ["up", "down", "left", "right"].contains(direction) else { throw BackendDeckToolsArgs.bad("direction must be one of: up, down, left, right") }; let path = directionPath(direction); return (path.from, path.to, duration, direction) }
        if args["from"] == .missing || args["to"] == .missing { throw S.refused("Say how to swipe: from and to as {x, y} fractions of the screen, or a direction (up, down, left, right).") }
        return (try point("from", args["from"]), try point("to", args["to"]), duration, nil)
    }
    public static func typing(_ args: V) throws -> (text: String?, key: String?, modifiers: [String]) {
        let text = try optText(args, "text"), key = try optText(args, "key"), modifiers = args["modifiers"].elements?.compactMap(\.string) ?? []
        if text == nil && key == nil { throw S.refused("Give text to type, a key to press, or both.") }
        if let text, text.utf16.count > 2_000 { throw S.refused("text is \(text.utf16.count) characters and at most 2000 are typed at once. Send it in parts.") }
        if !modifiers.isEmpty && key == nil { throw S.refused("modifiers are held while a key is pressed, so they need a key.") }
        return (text, key, modifiers)
    }
    public static func button(_ args: V) throws -> (button: String?, rotate: String?) {
        let button = try optText(args, "button"), rotate = try optText(args, "rotate")
        if button != nil && rotate != nil { throw S.refused("Give button or rotate, not both.") }
        if button == nil && rotate == nil { throw S.refused("Give a button (\(buttons.joined(separator: ", "))) or rotate (\(orientations.joined(separator: ", "))).") }; return (button, rotate)
    }
    static func limit(_ raw: V, fallback: Int, max: Int) -> Int { guard let n = raw.number, n.isFinite else { return fallback }; return Int(min(Swift.max(n.rounded(.towardZero), 1), Double(max))) }
    static func scope(_ args: V) -> String { ["interactive", "visible", "full"].contains(args["scope"].string ?? "") ? args["scope"].string! : "visible" }
    static func stateWords(_ state: String) -> String { ["ready": "running", "shutdown": "off", "booting": "starting", "unauthorized": "waiting for you to allow this computer on the phone", "offline": "not answering" ][state] ?? "unknown" }
    static func deviceRow(_ entry: V) -> V {
        var result = S.object(["id": entry["id"], "name": entry["name"], "platform": entry["platform"], "kind": entry["kind"], "state": .string(stateWords(entry["state"].string ?? "")), "usable": entry["available"], "runtime": entry["runtime"], "canStart": entry["canBoot"], "canShutDown": entry["canShutDown"], "buttons": entry["buttons"], "keys": entry["keys"], "text": entry["text"], "canRotate": entry["canRotate"]])
        if let note = entry["note"].string, !note.isEmpty { result = result.setting("note", .string(note)) }
        if entry["checking"].bool == true { result = result.setting("checking", .bool(true)).setting("checkingNote", .string("The device engine was slow to answer, so this row comes from the simulator’s own record and is being checked again. It can still be opened.")) }; return result
    }
}

public struct BackendDeckToolsMachinesDevices: Sendable {
    public typealias V = NativeRPCValue
    typealias R = BackendDeckToolsMachinesDeviceRules
    typealias S = BackendDeckToolsMachinesShared
    public let service: any BackendDeckToolsMachinesDeviceService
    public init(service: any BackendDeckToolsMachinesDeviceService) { self.service = service }
    public static let ids = ["devices.list", "devices.open", "devices.shutdown", "devices.screenshot", "devices.tap", "devices.swipe", "devices.type", "devices.button", "devices.tree", "devices.find", "devices.annotations"]
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsMachinesFactory.definitions(ids: Self.ids, environment: environment, prepare: { [self] in try await self.policy($0, $1, $2) }, run: { [self] in try await self.run($0, $1, $2) })
    }
    public func policy(_ spec: BackendMCPTool, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesPolicy {
        if spec.id != "devices.list" && spec.id != "devices.annotations" {
            if let reason = await service.unavailable() { throw S.refused("\(reason) \(spec.id) cannot work on this computer, and nothing else here drives a phone or a simulator — do not retry. Say what you would have done instead.") }; _ = try R.id(args)
        }
        switch spec.id {
        case "devices.shutdown": let id = try R.id(args); if id.hasPrefix("android:") && !id.hasPrefix("android:emulator-") { throw S.refused("\(id) is a phone on a cable. A phone is turned off on the phone itself; this app never powers a person’s phone down.") }
        case "devices.screenshot": if context.kind == .session && !context.machineID.isEmpty { throw S.refused("devices.screenshot writes the picture on the computer the device is attached to, so the path it answers with is not a file you can open. Use devices.tree: the element list is what tells you what to tap, and a picture is not.") }
        case "devices.tap": _ = try R.tapTarget(args); _ = try R.hold(args)
        case "devices.swipe": _ = try R.swipe(args)
        case "devices.type": _ = try R.typing(args)
        case "devices.button": _ = try R.button(args)
        case "devices.find": if try R.selector(args) == nil { throw S.refused("Give a name, an identifier or a role to look for.") }
        default: break
        }
        var logged = args
        if spec.id == "devices.type", let text = args["text"].string { logged = logged.setting("text", .string("[\(text.utf16.count) characters]")) }
        return .init(tool: spec, arguments: args, loggedArguments: logged, tier: spec.tier,
                     spends: ["devices.tap", "devices.swipe", "devices.type", "devices.button"].contains(spec.id) ? "device-input" : "changes", sentence: try sentence(spec.id, args))
    }
    public func sentence(_ tool: String, _ args: V) throws -> String {
        let id = args["deviceId"].string ?? "a device"
        func percent(_ raw: V) -> String { "\(Int(floor((raw.number ?? 0) * 100 + 0.5)))%" }
        switch tool {
        case "devices.list": return "List the phones and simulators on this computer"
        case "devices.open": return "Start and open device \(id)"
        case "devices.shutdown": return "Shut down \(id)"
        case "devices.screenshot": return "Photograph the screen of \(id)"
        case "devices.tap": let hold = try R.hold(args), target = try R.tapTarget(args), verb = (hold ?? 0) >= 400 ? "Long-press" : "Tap"; if let point = target.point { return "\(verb) \(id) at \(percent(point["x"])) across, \(percent(point["y"])) down" }; return "\(verb) the \(R.words(target.selector!)) on \(id)"
        case "devices.swipe": let path = try R.swipe(args); if let direction = path.direction { return "Swipe \(direction) on \(id)" }; return "Swipe on \(id) from \(percent(path.from["x"])), \(percent(path.from["y"])) to \(percent(path.to["x"])), \(percent(path.to["y"]))"
        case "devices.type": let typing = try R.typing(args); var parts: [String] = []; if let text = typing.text { parts.append("type \(text.utf16.count) characters") }; if let key = typing.key { parts.append("press \((typing.modifiers + [key]).joined(separator: "+"))") }; let words = parts.joined(separator: " and "); return words.prefix(1).uppercased() + String(words.dropFirst()) + " on " + id
        case "devices.button": let what = try R.button(args); return what.button.map { "Press \($0) on \(id)" } ?? "Turn \(id) to \(what.rotate!)"
        case "devices.tree": return "Read the screen of \(id)"
        case "devices.find": return "Find \(try R.selector(args).map(R.words) ?? "elements") on \(id)"
        default: let count = R.limit(args["count"], fallback: 1, max: 10), kind = args["kind"].string.map { " " + $0 } ?? ""; return count == 1 ? "Read the newest\(kind) annotation round" : "Read the newest \(count)\(kind) annotation rounds"
        }
    }
    public func run(_ tool: String, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesOutput {
        if tool == "devices.list" {
            let reason = await service.unavailable(), entries: [V]
            if reason == nil { entries = try await service.list() } else { entries = [] }
            let usable = entries.filter { $0["available"].bool == true }.count, rows = entries.map(R.deviceRow)
            return .init(S.empty(S.object(["available": .bool(reason == nil), "devices": .array(rows), "usable": .number(Double(usable))]), count: rows.count, reason: reason.map { $0 + " No phone or simulator can be listed or driven from this computer." } ?? "this computer has no iOS Simulator, no Android emulator and no Android phone plugged in. Simulators come with Xcode and emulators with Android Studio; a phone needs USB debugging turned on and this computer allowed on it."), S.emptySummary(rows.count).setting("devices", .number(Double(rows.count))).setting("usable", .number(Double(usable))))
        }
        if tool == "devices.annotations" {
            let count = R.limit(args["count"], fallback: 1, max: 10), kind = args["kind"].string, all = try await service.rounds(), matching = kind.map { k in all.filter { $0["where"]["kind"].string == k } } ?? all, other = all.count - matching.count
            let rows = matching.prefix(count).map(BackendDeckToolsMachinesAnnotationRules.round)
            let reason = all.isEmpty ? "nobody has annotated anything since the app started. A person makes a round with Annotate, on the Simulators page or in the browser, and it appears here as soon as it is saved." : "nobody has annotated a \(kind == "device" ? "device screen" : "browser page") since the app started; there \(other == 1 ? "is 1 round" : "are \(other) rounds") on \(kind == "device" ? "browser pages" : "device screens") — leave kind out to read them."
            return .init(S.empty(S.object(["rounds": .array(rows), "total": .number(Double(matching.count))]), count: rows.count, reason: reason), S.emptySummary(rows.count).setting("rounds", .number(Double(rows.count))).setting("total", .number(Double(matching.count))))
        }
        let id = try R.id(args), base = S.object(["deviceId": .string(id)])
        if tool == "devices.open" {
            let all = try await service.list()
            guard let entry = all.first(where: { $0["id"].string == id }) else { throw S.refused("There is no device \(id) on this computer right now — it may have been deleted, unplugged, or started under a new id. Call devices.list for the current ids.") }
            let name = entry["name"].string ?? "", state = entry["state"].string ?? ""
            if ["unauthorized", "offline"].contains(state) { throw S.refused("\(name) is \(R.stateWords(state)). \((entry["note"].string ?? "").isEmpty ? "It cannot be opened until that changes." : entry["note"].string!)") }
            var useID = id, started = false
            if state == "shutdown" { guard entry["canBoot"].bool == true else { throw S.refused("\(name) is off and cannot be started from here.") }; let boot = try await service.boot(id); guard boot["ok"].bool == true else { throw NativeRPCError(code: "device-fault", message: boot["message"].string ?? "The device did not start.") }; useID = try boot["id"].requireString("started device id"); started = true }
            let details = try await service.open(useID)
            var value = S.object(["id": .string(useID), "started": .bool(started), "device": details]), summary = S.emptySummary(1).setting("id", .string(useID)).setting("started", .bool(started))
            if useID != id { value = value.setting("note", .string("\(name) is running now as \(useID). Use that id for every call from here on; \(id) named it only while it was off.")); summary = summary.setting("was", .string(id)) }
            return .init(S.empty(value, count: 1, reason: ""), summary)
        }
        if tool == "devices.shutdown" {
            if id.hasPrefix("avd:") { return .init(S.empty(S.object(["id": .string(id), "shutDown": .bool(false), "alreadyOff": .bool(true), "note": .string("\(id) names an emulator that was off when it was listed. If it has been started since, it has an android:emulator-… id now — call devices.list.")]), count: 0, reason: "it was already off, so there was nothing to shut down."), S.emptySummary(0).setting("id", .string(id)).setting("alreadyOff", .bool(true))) }
            let answer = try await service.shutDown(id); guard answer["ok"].bool == true else { throw NativeRPCError(code: "device-fault", message: answer["message"].string ?? "The device would not shut down.") }; return .init(S.empty(S.object(["id": .string(id), "shutDown": .bool(true)]), count: 1, reason: ""), S.emptySummary(1).setting("id", .string(id)))
        }
        if tool == "devices.screenshot" {
            let shot = try await service.screenshot(id); var value = shot.setting("deviceId", .string(id))
            if context.kind == .remote { value = value.setting("note", .string("The picture is saved on the computer the device is attached to, where the person can find it in Pictures. The path is not a file you can open from where you are; devices.tree is how to read the screen.")) }
            return .init(value, base.setting("width", shot["width"]).setting("height", shot["height"]))
        }
        if tool == "devices.tap" {
            let target = try R.tapTarget(args), hold = try R.hold(args); var point = target.point, element: V = .null
            if let selector = target.selector { let answer = try await service.tree(id, scope: "visible"), node = try R.resolveOne(answer.tree.root, selector); guard let centre = DeviceTreeQuery.centre(of: node) else { throw S.refused("Nothing was tapped: the element has no position.") }; point = S.object(["x": .number(centre.x), "y": .number(centre.y)]); element = R.element(node) }
            let x = point!["x"].number!, y = point!["y"].number!, long = (hold ?? 0) >= 400
            try await service.tap(id, x: x, y: y, holdMS: hold)
            var value = base.setting("tapped", S.object(["x": .number(R.round3(x)), "y": .number(R.round3(y))])).setting("longPress", .bool(long)).setting("element", element), summary = S.emptySummary(1).setting("deviceId", .string(id)).setting("x", .number(R.round3(x))).setting("y", .number(R.round3(y)))
            if let hold { value = value.setting("holdMs", .number(Double(hold))) }; if let name = element["name"].string, !name.isEmpty { summary = summary.setting("element", .string(name)) }; if long { summary = summary.setting("longPress", .bool(true)) }; return .init(S.empty(value, count: 1, reason: ""), summary)
        }
        if tool == "devices.swipe" {
            let path = try R.swipe(args); try await service.swipe(id, from: path.from, to: path.to, durationMS: path.duration)
            var value = base.setting("from", path.from).setting("to", path.to).setting("durationMs", .number(Double(path.duration))), summary = S.emptySummary(1).setting("deviceId", .string(id)); if let direction = path.direction { value = value.setting("direction", .string(direction)); summary = summary.setting("direction", .string(direction)) }; return .init(S.empty(value, count: 1, reason: ""), summary)
        }
        if tool == "devices.type" {
            let typing = try R.typing(args), device = try await service.open(id), name = device["name"].string ?? ""
            if let text = typing.text {
                if device["text"].string == "none" { throw S.refused("\(name) does not accept typed text. Nothing was typed. Tap its on-screen keyboard instead.") }
                if device["text"].string == "ascii", text.unicodeScalars.contains(where: { $0.value > 0x7f }) { throw S.refused("\(name) accepts plain ASCII text only, and this text has other characters in it. Nothing was typed.") }
            }
            let keys = device["keys"].elements?.compactMap(\.string) ?? []
            if let key = typing.key, !keys.isEmpty && !keys.contains(key) { throw S.refused("\(name) cannot be sent \(key). It takes: \(keys.joined(separator: ", ")). Nothing was typed.") }
            if let text = typing.text { try await service.type(id, text: text) }; if let key = typing.key { try await service.key(id, key: key, modifiers: typing.modifiers) }
            let count = typing.text?.utf16.count ?? 0; var value = base.setting("typedCharacters", .number(Double(count))), summary = S.emptySummary(1).setting("deviceId", .string(id)).setting("chars", .number(Double(count)))
            if let key = typing.key { value = value.setting("pressed", .string(key)); summary = summary.setting("key", .string(key)) }; if !typing.modifiers.isEmpty { value = value.setting("modifiers", .array(typing.modifiers.map(V.string))) }; return .init(S.empty(value, count: 1, reason: ""), summary)
        }
        if tool == "devices.button" {
            let what = try R.button(args), device = try await service.open(id), name = device["name"].string ?? ""
            if let button = what.button { let buttons = device["buttons"].elements?.compactMap(\.string) ?? []; if !buttons.isEmpty && !buttons.contains(button) { throw S.refused("\(name) has no \(button) button. It has: \(buttons.joined(separator: ", ")). Nothing was pressed.") }; try await service.button(id, button: button); return .init(S.empty(base.setting("pressed", .string(button)), count: 1, reason: ""), S.emptySummary(1).setting("deviceId", .string(id)).setting("button", .string(button))) }
            guard device["canRotate"].bool == true else { throw S.refused("\(name) does not turn from here. It was left as it is.") }; let orientation = try await service.rotate(id, to: what.rotate!); return .init(S.empty(base.setting("orientation", .string(orientation)), count: 1, reason: ""), S.emptySummary(1).setting("deviceId", .string(id)).setting("orientation", .string(orientation)))
        }
        let answer = try await service.tree(id, scope: R.scope(args)), source = answer.tree.source == "react-native-fiber" ? "react-native-fiber" : "accessibility"
        if tool == "devices.find" {
            guard let selector = try R.selector(args) else { throw S.refused("Give a name, an identifier or a role to look for.") }
            let found = R.find(answer.tree.root, selector), rows = found.prefix(20).map(R.element)
            return .init(S.empty(base.setting("source", .string(source)).setting("foreground", answer.foreground).setting("matches", .array(rows)).setting("count", .number(Double(found.count))).setting("truncated", .bool(found.count > rows.count)), count: rows.count, reason: "nothing on the screen matches the \(R.words(selector)). Names are matched whole and ignoring case — try partial: true, or devices.tree to see what is there. It may also be scrolled away: scope full includes that."), S.emptySummary(rows.count).setting("deviceId", .string(id)).setting("count", .number(Double(found.count))))
        }
        let list = R.listElements(answer.tree.root, limit: R.limit(args["limit"], fallback: 150, max: 400)), cut = list.total > list.rows.count, truncated = cut || answer.tree.truncated
        var notes: [String] = []
        if cut { notes.append("Showing \(list.rows.count) of \(list.total) elements; pass a larger limit (at most 400) or use devices.find.") }; if answer.tree.truncated { notes.append("The device itself stopped reading the screen early; it has more than it described.") }; if !answer.fallback.isEmpty { notes.append("The React Native tree was not used: " + answer.fallback) }
        var value = base.setting("source", .string(source)).setting("foreground", answer.foreground).setting("capturedAt", .string(answer.tree.capturedAt)).setting("elements", .array(list.rows)).setting("shown", .number(Double(list.rows.count))).setting("total", .number(Double(list.total))).setting("truncated", .bool(truncated)); if !notes.isEmpty { value = value.setting("note", .string(notes.joined(separator: " "))) }
        return .init(S.empty(value, count: list.rows.count, reason: "the screen described itself with no element worth listing — it may still be loading, or the app draws everything itself, as a game or a map does. devices.screenshot shows it, and devices.tap can still tap a position."), S.emptySummary(list.rows.count).setting("deviceId", .string(id)).setting("shown", .number(Double(list.rows.count))).setting("total", .number(Double(list.total))).setting("truncated", .bool(truncated)))
    }
}

/// Core's AnnotationRound does not yet retain browser selector/picture/sentTo, so preserve the store's raw fields here.
enum BackendDeckToolsMachinesAnnotationRules {
    public typealias V = NativeRPCValue
    typealias S = BackendDeckToolsMachinesShared
    static func iso(_ value: V) -> V { guard let ms = value.number else { return .null }; let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return .string(formatter.string(from: Date(timeIntervalSince1970: ms / 1_000))) }
    static func clip(_ text: String, _ max: Int = 120) -> String { let flat = Handoff.flat(text); return flat.utf16.count > max ? BackendDeckToolsSupport.slice(flat, 0, max - 1) + "…" : flat }
    static func described(_ element: V) -> String {
        if element.isNullish { return "blank space" }
        let head = [element["role"].string.map { clip($0, 40) } ?? "", element["name"].string.map { "\"\(clip($0))\"" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        var handles: [String] = []
        for (key, label, max) in [("identifier", "id", 120), ("selector", "selector", 200), ("component", "component", 80)] { if let text = element[key].string, !text.isEmpty { handles.append(label + " " + clip(text, max)) } }
        let source = element["source"]
        if let file = source["file"].string { var location = "source " + clip(file, 200); if let line = source["line"].number, line != 0 { location += ":\(Int(line))"; if let col = source["column"].number, col != 0 { location += ":\(Int(col))" } }; handles.append(location) }
        let named = head.isEmpty ? "element" : head; return handles.isEmpty ? named : named + " (" + handles.joined(separator: ", ") + ")"
    }
    static func round(_ raw: V) -> V {
        let sent = raw["sentTo"].isNullish ? V.null : S.object(["session": raw["sentTo"]["label"], "at": iso(raw["sentTo"]["at"])])
        let markers = (raw["annotations"].elements ?? []).map { S.object(["n": $0["n"], "element": $0["element"], "described": .string(described($0["element"])), "rect": $0["rect"]]) }
        return S.object(["id": raw["id"], "createdAt": iso(raw["createdAt"]), "where": raw["where"], "note": .string(Handoff.flat(raw["note"].string ?? "")), "picture": raw["picture"].isNullish ? .null : raw["picture"], "sentTo": sent, "markers": .array(markers)])
    }
}
