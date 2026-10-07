import CoreGraphics
import Foundation

// Lane BR (browser parity): the rules behind the browser window's Session button,
// the Bn chips, Annotate's first click on the live page, the mode hint and the
// handover band — ported from the Electron app's TypeScript so the Swift window
// says and does the same.

// MARK: - The bindings view

/// One window held by a session, as `browser:bindings` lists it.
public struct BRBoundWindow: Equatable, Sendable {
    public let n: Int
    public let tabId: String
    public let title: String
    public let url: String
    /// Who serves the page when it is on another computer ("" when it is here).
    public let host: String

    public init(n: Int, tabId: String, title: String = "", url: String = "", host: String = "") {
        self.n = n; self.tabId = tabId; self.title = title; self.url = url; self.host = host
    }

    public var slot: String { BrowserWindowName.name(n) }
}

/// One session's row in `browser:bindings`.
public struct BRBoundSession: Equatable, Sendable {
    public let sessionId: String
    public let machineId: String
    public let colour: Int
    public let ended: Bool
    /// Ordered by n, as browser-binding.ts keeps them.
    public let windows: [BRBoundWindow]

    public init(sessionId: String, machineId: String = "", colour: Int = 0, ended: Bool = false, windows: [BRBoundWindow] = []) {
        self.sessionId = sessionId; self.machineId = machineId; self.colour = colour; self.ended = ended
        self.windows = windows.sorted { $0.n < $1.n }
    }

    public var key: String { BrowserBindings.key(BrowserDriverSession(sessionId: sessionId, machineId: machineId)) }
}

/// The engine's `browser:bindings` view, read with every field the chips and the
/// agent's sentences need (`BrowserBindings.read` keeps only n and the tab).
public struct BRBindingView: Equatable, Sendable {
    public let sessions: [BRBoundSession]

    public init(sessions: [BRBoundSession] = []) { self.sessions = sessions }

    /// `{sessions: [{sessionId, machineId, colour, ended, windows: [{n, browserTabId, title, url, hostMachineId, hostMachineName}]}]}`
    public static func read(_ value: Any?) -> BRBindingView {
        guard let view = value as? [String: Any], let rows = view["sessions"] as? [Any] else { return BRBindingView() }
        var sessions: [BRBoundSession] = []
        for row in rows {
            guard let fields = row as? [String: Any], let sessionId = fields["sessionId"] as? String, !sessionId.isEmpty else { continue }
            let windows = ((fields["windows"] as? [Any]) ?? []).compactMap { raw -> BRBoundWindow? in
                guard let window = raw as? [String: Any], let n = (window["n"] as? NSNumber)?.intValue,
                      let tab = window["browserTabId"] as? String, !tab.isEmpty else { return nil }
                let hostID = (window["hostMachineId"] as? String) ?? ""
                let hostName = (window["hostMachineName"] as? String) ?? ""
                return BRBoundWindow(n: n, tabId: tab, title: (window["title"] as? String) ?? "", url: (window["url"] as? String) ?? "",
                                     host: hostID.isEmpty ? "" : (hostName.isEmpty ? hostID : hostName))
            }
            sessions.append(BRBoundSession(sessionId: sessionId, machineId: (fields["machineId"] as? String) ?? "",
                                           colour: (fields["colour"] as? NSNumber)?.intValue ?? 0,
                                           ended: (fields["ended"] as? Bool) ?? false, windows: windows))
        }
        return BRBindingView(sessions: sessions)
    }

    /// The session holding this browser tab, and the window it holds it as.
    public func holder(of tabId: String) -> (session: BRBoundSession, window: BRBoundWindow)? {
        for session in sessions {
            if let window = session.windows.first(where: { $0.tabId == tabId }) { return (session, window) }
        }
        return nil
    }

    public func session(_ sessionId: String, machineId: String = "") -> BRBoundSession? {
        sessions.first { $0.sessionId == sessionId && $0.machineId == machineId }
    }
}

// MARK: - Chips (BindChip.tsx)

public enum BRBindChips {
    /// How many chips a session row shows before "+N" (BindChip.tsx CHIPS_SHOWN).
    public static let shown = 2

    /// The binding's colour as the web's `data-bind` (1…4).
    public static func colourSlot(_ colour: Int) -> Int { ((colour % 4) + 4) % 4 + 1 }

    static func windowName(_ window: BRBoundWindow) -> String {
        if !window.title.isEmpty { return window.title }
        if !window.url.isEmpty { return window.url }
        return "a browser window"
    }

    /// `B1 — Stripe` and, when the session's name is known, ` · attached to <name>`.
    public static func tooltip(_ window: BRBoundWindow, sessionName: String?) -> String {
        let head = "\(window.slot) — \(windowName(window))"
        guard let sessionName, !sessionName.isEmpty else { return head }
        return "\(head) · attached to \(sessionName)"
    }

    /// The browser row's chip: its own slot, or what it was looking at once the session exited.
    public static func windowTooltip(_ window: BRBoundWindow, session: BRBoundSession, sessionName: String?) -> String {
        if session.ended {
            let name = (sessionName?.isEmpty == false) ? sessionName! : "the session this page belongs to"
            return "\(window.slot) — \(name) has exited. This is what it was looking at."
        }
        return tooltip(window, sessionName: sessionName)
    }

    /// The session row's chips: up to `shown`, then one "+N" carrying the rest.
    public static func split(_ windows: [BRBoundWindow]) -> (shown: [BRBoundWindow], rest: [BRBoundWindow]) {
        (Array(windows.prefix(shown)), Array(windows.dropFirst(shown)))
    }

    /// The "+N" chip's spoken name.
    public static func moreLabel(_ rest: [BRBoundWindow]) -> String {
        "\(rest.count) more browser \(rest.count == 1 ? "window" : "windows") attached: \(rest.map(\.slot).joined(separator: ", "))"
    }

    /// The Session button's spoken name.
    public static func connectLabel(slot: String?) -> String {
        guard let slot, !slot.isEmpty else { return "Attach to a session" }
        return "Attached to \(slot)"
    }
}

// MARK: - The Session button's menu (browser-binding-ipc.ts connectMenuItems)

public struct BRConnectRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case item, checkbox, separator, header }
    public enum Act: Equatable, Sendable {
        case attach(sessionId: String, machineId: String)
        case detach
    }
    public let kind: Kind
    public let label: String
    public let enabled: Bool
    public let checked: Bool
    public let act: Act?

    public init(kind: Kind, label: String = "", enabled: Bool = true, checked: Bool = false, act: Act? = nil) {
        self.kind = kind; self.label = label; self.enabled = enabled; self.checked = checked; self.act = act
    }
}

public enum BRConnectMenu {
    public static let noSessions = "No sessions are open."

    /// The rows, in the engine's order: Disconnect first when this window is held,
    /// then one checkbox per open session (grouped by computer when there is more
    /// than one), ticked for the session holding it, prefixed with its slot.
    public static func rows(tabId: String, sessions: [BrowserSessionChoice], machineOf: (String) -> String = { _ in "" },
                            machineName: (String) -> String = { _ in "" }, thisMachine: String = "",
                            view: BRBindingView) -> [BRConnectRow] {
        var rows: [BRConnectRow] = []
        let held = view.holder(of: tabId)
        if let held {
            rows.append(BRConnectRow(kind: .item, label: "Disconnect \(held.window.slot)", act: .detach))
            rows.append(BRConnectRow(kind: .separator, enabled: false))
        }
        let open = sessions.filter { !$0.ended }
        if open.isEmpty {
            rows.append(BRConnectRow(kind: .item, label: noSessions, enabled: false))
            return rows
        }
        var order: [String] = []
        var groups: [String: [BrowserSessionChoice]] = [:]
        for session in open {
            let machine = machineOf(session.id)
            if groups[machine] == nil { order.append(machine) }
            groups[machine, default: []].append(session)
        }
        for machine in order {
            if order.count > 1 {
                let label = machine.isEmpty ? (thisMachine.isEmpty ? "This computer" : thisMachine)
                    : (machineName(machine).isEmpty ? machine : machineName(machine))
                rows.append(BRConnectRow(kind: .header, label: label, enabled: false))
            }
            for session in groups[machine] ?? [] {
                let holds = held.map { $0.session.sessionId == session.id && $0.session.machineId == machine } ?? false
                let label = holds ? "\(held!.window.slot)   \(session.label)" : session.label
                rows.append(BRConnectRow(kind: .checkbox, label: label, checked: holds,
                                         act: holds ? .detach : .attach(sessionId: session.id, machineId: machine)))
            }
        }
        return rows
    }

    /// The send a press makes: `browser:bind {tabId, sessionId, machineId}` or `browser:unbind <tabId>`.
    public static func command(_ act: BRConnectRow.Act, tabId: String) -> (channel: String, argument: Any) {
        switch act {
        case .attach(let sessionId, let machineId):
            return ("browser:bind", ["tabId": tabId, "sessionId": sessionId, "machineId": machineId])
        case .detach:
            return ("browser:unbind", tabId)
        }
    }
}

// MARK: - Annotate's first click (BrowserAnnotate.tsx elementFromCapture / normalise)

/// What `browser:element` carries for a click on the live page while Annotate is on.
public struct BRInspectCapture: Equatable, Sendable {
    public let tabId: String
    public let element: BrowserAnnotatedElement?
    /// CSS pixels inside the view; nil when the page sent none.
    public let cssRect: CGRect?
    /// The photograph taken at the click: a data URL, "" when none could be taken.
    public let pageImage: String
    public let url: String

    public init(tabId: String, element: BrowserAnnotatedElement?, cssRect: CGRect?, pageImage: String, url: String) {
        self.tabId = tabId; self.element = element; self.cssRect = cssRect; self.pageImage = pageImage; self.url = url
    }

    public static func read(_ raw: Any?) -> BRInspectCapture? {
        guard let fields = raw as? [String: Any], let tabId = fields["id"] as? String, !tabId.isEmpty else { return nil }
        let tag = (fields["tag"] as? String) ?? ""
        let attributes = (fields["attributes"] as? [String: Any]) ?? [:]
        let element = BrowserAnnotatedElement(role: tag.isEmpty ? "" : "<\(tag)>", name: (fields["label"] as? String) ?? "",
                                              identifier: (attributes["id"] as? String) ?? "",
                                              selector: (fields["selector"] as? String) ?? "")
        var rect: CGRect?
        if let box = fields["rect"] as? [String: Any] {
            func number(_ key: String) -> Double { (box[key] as? NSNumber)?.doubleValue ?? 0 }
            rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        }
        return BRInspectCapture(tabId: tabId, element: element == BrowserAnnotatedElement() ? nil : element, cssRect: rect,
                                pageImage: (fields["pageImage"] as? String) ?? "", url: (fields["url"] as? String) ?? "")
    }

    /// The marker's box as fractions of the picture; nil without a box (the round then starts empty).
    public func markerRect(viewport: CGSize) -> CGRect? {
        guard let cssRect else { return nil }
        return BrowserAnnotate.normalise(cssRect, viewport: viewport)
    }

    /// The bytes of a `data:image/…;base64,` picture.
    public static func imageData(_ dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }
}

// MARK: - Modes (modes.ts)

public enum BRBrowserModes {
    /// The one instruction line under the toolbar (modeHint), or "".
    public static func hint(inspecting: Bool, drawing: Bool, hasCapture: Bool) -> String {
        if inspecting && !hasCapture { return "Click what you want to change. Escape stops." }
        if drawing { return "Drag on the page to mark it. Escape leaves without saving." }
        return ""
    }
}

// MARK: - The handover band (DriveBanner.tsx, state "human")

public enum BRHandoverWords {
    public static let carryOn = "Done, carry on"
    public static let stop = "Stop — I’ll take it from here"

    public static func text(prompt: String) -> String {
        let said = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "Take over this page, then say you are done." : said
    }

    /// The site after the words (" · example.com"), "" when the address has no host.
    public static func site(_ url: URL?) -> String {
        guard let host = url?.host(), !host.isEmpty else { return "" }
        return " · " + host
    }
}

// MARK: - The page's right-click rows WebKit lacks (browser-context-menu.ts)

public enum BRPageMenu {
    /// A page worth naming: any address but the blank one.
    public static func hasPage(_ url: String) -> Bool { !url.isEmpty && url != "about:blank" }

    /// `mayOpenOutside`: only an ordinary web address leaves for the system browser —
    /// never `file:`, `javascript:` or a custom scheme a hostile page could hand over.
    public static func mayOpenOutside(_ url: String) -> Bool {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parsed.host(), !host.isEmpty else { return false }
        return true
    }
}

// MARK: - Size: a custom width × height (DeviceBar.tsx, devices.ts)

public enum BRDeviceSize {
    public static let customID = "custom"
    /// Narrower than this is not a phone, wider is not a screen anyone has.
    public static let minimum = 200
    public static let maximum = 4000
    /// The web browser's starting custom size.
    public static let defaultWidth = "390"
    public static let defaultHeight = "844"

    /// `parseDimension`: digits only, within the bounds; nil while unusable.
    public static func parse(_ raw: String) -> Int? {
        let digits = raw.trimmingCharacters(in: .whitespaces)
        guard (1...5).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits),
              (minimum...maximum).contains(value) else { return nil }
        return value
    }

    /// The frame to draw the page in: a preset, a usable custom size, or nil to fill.
    /// A custom size mid-edit fills, never a 3-pixel page (BrowserWorkspace deviceSize).
    public static func frame(deviceID: String?, customWidth: String, customHeight: String) -> (label: String, width: Int, height: Int)? {
        guard let deviceID else { return nil }
        if deviceID == customID {
            guard let width = parse(customWidth), let height = parse(customHeight) else { return nil }
            return ("Custom", width, height)
        }
        return BrowserDevicePreset.byID(deviceID).map { ($0.label, $0.width, $0.height) }
    }
}

// MARK: - History (HistoryPanel.tsx, history-view.ts)

public struct BRHistoryVisit: Equatable, Sendable, Identifiable {
    public let url: String
    public let title: String
    public let visitedAt: Double
    public var id: String { url }

    public init(url: String, title: String, visitedAt: Double) { self.url = url; self.title = title; self.visitedAt = visitedAt }

    /// `readVisitList`: rows without an address are dropped.
    public static func list(_ raw: Any?) -> [BRHistoryVisit] {
        ((raw as? [Any]) ?? []).compactMap { entry in
            guard let row = entry as? [String: Any], let url = row["url"] as? String, !url.isEmpty else { return nil }
            return BRHistoryVisit(url: url, title: (row["title"] as? String) ?? "", visitedAt: (row["visitedAt"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// `visitLabel`: the title, else the address.
    public var label: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url : trimmed
    }

    /// `visitHost`: the host without www.
    public var host: String {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return url }
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

public struct BRHistoryDay: Equatable, Sendable, Identifiable {
    public let heading: String
    public let day: Date
    public let visits: [BRHistoryVisit]
    public var id: Date { day }
}

public enum BRHistory {
    public static let title = "History"
    public static func title(profileName: String) -> String { profileName.isEmpty ? title : "History — \(profileName)" }
    public static func empty(searching: Bool) -> String { searching ? "Nothing matches." : "Nothing yet." }

    /// `dayHeading`: Today, Yesterday, else the date (the year only when it is not this one).
    public static func heading(_ at: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: at), today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "Yesterday" }
        let sameYear = calendar.component(.year, from: at) == calendar.component(.year, from: now)
        let format = DateFormatter()
        format.calendar = calendar; format.locale = locale; format.timeZone = calendar.timeZone
        format.setLocalizedDateFormatFromTemplate(sameYear ? "EEE d MMM" : "EEE d MMM y")
        return format.string(from: at)
    }

    /// `byDay`: newest first, one section per calendar day.
    public static func byDay(_ visits: [BRHistoryVisit], now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [BRHistoryDay] {
        var days: [BRHistoryDay] = []
        for visit in visits.sorted(by: { $0.visitedAt > $1.visitedAt }) {
            let at = Date(timeIntervalSince1970: visit.visitedAt / 1000)
            let day = calendar.startOfDay(for: at)
            if let last = days.last, last.day == day {
                days[days.count - 1] = BRHistoryDay(heading: last.heading, day: day, visits: last.visits + [visit])
            } else {
                days.append(BRHistoryDay(heading: heading(at, now: now, calendar: calendar, locale: locale), day: day, visits: [visit]))
            }
        }
        return days
    }
}

// MARK: - The drive band (DriveBanner.tsx, drive-bridge.ts driveChipText)

public enum BRDriveChip {
    /// `Hoot is driving`, or `Hoot is <step>`; "" when nobody is.
    public static func text(state: String, step: String, assistant: String = "Hoot") -> String {
        if state == "human" { return "Your turn" }
        guard state == "agent" else { return "" }
        return step.isEmpty ? "\(assistant) is driving" : "\(assistant) is \(step)"
    }

    /// " on example.com" after the words, "" without a host.
    public static func site(_ url: String) -> String {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return "" }
        return " on " + host
    }
}

// MARK: - Which computer serves the page (MachinePicker.tsx, machines-bridge.ts, reach-ledger.ts, served-mark.ts)

public struct BRMachineChoice: Equatable, Sendable, Identifiable {
    public let kind: String // "device" | "server"
    public let id: String
    public let name: String
    public let noun: String
    public let ports: [MachinePort]
    /// Why it cannot be reached now, in the Machines panel's words; nil when it can.
    public let unreachable: String?

    public init(kind: String = "device", id: String, name: String, noun: String, ports: [MachinePort] = [], unreachable: String? = nil) {
        self.kind = kind; self.id = id; self.name = name; self.noun = noun; self.ports = ports; self.unreachable = unreachable
    }
}

/// One port this desktop is serving from another machine (`ReachedPort` / `ReachHold`).
public struct BRReachedPort: Equatable, Sendable {
    public let machineId: String
    public let machineName: String
    public let port: Int
    public let localPort: Int
    public let sameNumber: Bool

    public init(machineId: String, machineName: String, port: Int, localPort: Int, sameNumber: Bool = true) {
        self.machineId = machineId; self.machineName = machineName; self.port = port; self.localPort = localPort; self.sameNumber = sameNumber
    }
}

public enum BRMachines {
    public static let thisMachine = ""

    /// `machineChoices`: every paired machine, with its ports and why it cannot be reached.
    public static func choices(_ view: MachinesView) -> [BRMachineChoice] {
        view.machines.map { machine in
            let link = view.links.first { $0.id == machine.id }
            let noun = MachinesRules.noun(link.map { $0.hostPlatform.isEmpty ? machine.platform : $0.hostPlatform } ?? machine.platform)
            let ports = (link?.ports ?? []).sorted { ($0.guessed ? 1 : 0, $0.port) < ($1.guessed ? 1 : 0, $1.port) }
            return BRMachineChoice(id: machine.id, name: machine.name.isEmpty ? "That \(noun)" : machine.name, noun: noun,
                                   ports: ports, unreachable: unreachable(link))
        }
    }

    static func unreachable(_ link: MachineLink?) -> String? {
        guard let link else { return MachineLinkPhase.offline.label }
        if link.phase != .online { return link.phase.label }
        if !link.capabilities.contains("localhost") { return "Older build" }
        return nil
    }

    /// The picker's button words (`Open localhost on <name>`, spoken `Addresses open on <name>. Choose a machine.`).
    public static func label(_ machines: [BRMachineChoice], selected: String, here: String) -> String {
        machines.first { $0.id == selected }?.name ?? here
    }

    /// `loopbackPort`: the port of a localhost address, nil for anything else.
    public static func loopbackPort(_ url: String) -> Int? {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = parts.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let loopback = host == "localhost" || host == "localhost." || host == "::1" || host == "0.0.0.0"
            || (host.hasPrefix("127.") && host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0).map { (0...999).contains($0) } ?? false })
        guard loopback else { return nil }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        return (1...65535).contains(port) ? port : nil
    }

    /// `reachedAddress`: the typed address's path, query and fragment on the opened one.
    public static func reachedAddress(typed: String, opened: String) -> String {
        guard let from = URLComponents(string: typed), from.scheme != nil, var to = URLComponents(string: opened), to.scheme != nil else { return opened }
        to.percentEncodedPath = from.percentEncodedPath.isEmpty ? "/" : from.percentEncodedPath
        to.percentEncodedQuery = from.percentEncodedQuery
        to.percentEncodedFragment = from.percentEncodedFragment
        return to.string ?? opened
    }

    /// `servedBy`: which machine's port this loopback page is, from the tunnels held here.
    public static func servedBy(_ url: String, opened: [BRReachedPort]) -> BRReachedPort? {
        guard let port = loopbackPort(url) else { return nil }
        return opened.first { $0.localPort == port }
    }

    public enum Move: Equatable, Sendable {
        case already
        case choose
        case here(url: String, give: BRReachedPort?)
        case there(machineId: String, port: Int, url: String)
        case refused(at: String)
    }

    /// `moveFor`: what choosing `next` in the picker does to the page on show.
    public static func move(to next: String, url: String, opened: [BRReachedPort]) -> Move {
        let here = servedBy(url, opened: opened)
        let at = here?.machineId ?? thisMachine
        if next == at { return .already }
        if url.trimmingCharacters(in: .whitespaces).isEmpty { return .choose }
        guard let port = here?.port ?? loopbackPort(url) else { return .refused(at: at) }
        if next == thisMachine {
            let give = opened.first { $0.localPort == port && $0.machineId != next }
            return .here(url: reachedAddress(typed: url, opened: "http://localhost:\(port)/"), give: give)
        }
        return .there(machineId: next, port: port, url: url)
    }

    /// `readReach` inside `readHeld`: the opened port, or the refusal in a sentence.
    public static func readHeld(_ raw: Any?) -> (opened: BRReachedPort?, url: String, message: String, stranded: BRReachedPort?) {
        let row = raw as? [String: Any]
        let answer = row?["answer"] as? [String: Any]
        let stranded = readHold(row?["stranded"])
        guard let answer else { return (nil, "", "That machine was asked for the port and gave no answer.", stranded) }
        guard answer["ok"] as? Bool == true else {
            let said = (answer["message"] as? String) ?? ""
            return (nil, "", said.isEmpty ? "That port could not be opened, and no reason came back." : said, stranded)
        }
        let url = (answer["url"] as? String) ?? ""
        let port = (answer["port"] as? NSNumber)?.intValue ?? 0, local = (answer["localPort"] as? NSNumber)?.intValue ?? 0
        guard !url.isEmpty, port > 0, local > 0 else {
            return (nil, "", "That machine answered about the port without saying where to open it.", stranded)
        }
        return (BRReachedPort(machineId: "", machineName: "", port: port, localPort: local, sameNumber: answer["sameNumber"] as? Bool == true),
                url, "", stranded)
    }

    static func readHold(_ raw: Any?) -> BRReachedPort? {
        guard let row = raw as? [String: Any], let id = row["machineId"] as? String, !id.isEmpty,
              let port = (row["port"] as? NSNumber)?.intValue, let local = (row["localPort"] as? NSNumber)?.intValue else { return nil }
        return BRReachedPort(machineId: id, machineName: (row["machineName"] as? String) ?? "", port: port, localPort: local,
                             sameNumber: row["sameNumber"] as? Bool != false)
    }

    /// `readHolds`: every tunnel this desktop is serving (`browser:reach:list` / `browser:reach:state`).
    public static func readHolds(_ raw: Any?) -> [BRReachedPort] { ((raw as? [Any]) ?? []).compactMap(readHold) }

    /// `strandedNote`.
    public static func strandedNote(_ hold: BRReachedPort) -> String { "\(hold.machineName) is still serving port \(hold.localPort) here." }

    /// `differentPortNote`: said when the port could not keep its number here.
    public static func differentPortNote(port: Int, localPort: Int, sameNumber: Bool, machineName: String) -> String {
        sameNumber ? "" : "\(machineName):\(port) → :\(localPort)"
    }

    /// `readReleased` + `afterHandBack`: nil to go on, else the machine to stay on and why.
    public static func afterHandBack(_ raw: Any?, held: BRReachedPort) -> (machineId: String, notice: String)? {
        let row = raw as? [String: Any]
        if row?["gone"] as? Bool == true { return nil }
        let said = (row?["message"] as? String) ?? ""
        return (held.machineId, said.isEmpty ? "\(held.machineName) is still serving port \(held.localPort) here." : said)
    }

    /// `barServed` + `servedMark`: the word beside the address saying which machine serves the page; "" for none.
    public static func servedMark(page: BRReachedPort?, picked: String, blank: Bool, here: String) -> (mark: String, title: String) {
        let served: (name: String, port: Int?, local: Int, same: Bool, agrees: Bool)
        if let page {
            served = (page.machineName, page.port, page.localPort, page.sameNumber, page.machineId == picked)
        } else {
            if picked.isEmpty || blank { return ("", "") }
            served = (here, nil, 0, true, false)
        }
        let mark: String
        if !served.agrees { mark = served.port.map { "\(served.name):\($0)" } ?? served.name }
        else if let port = served.port, !served.same { mark = ":\(port)" }
        else { mark = "" }
        guard !mark.isEmpty else { return ("", "") }
        guard let port = served.port else { return (mark, served.name) }
        return (mark, served.same ? "\(served.name):\(port)" : "\(served.name):\(port) → :\(served.local)")
    }
}

// MARK: - Servers in the picker (server-machines.ts)

public enum BRServers {
    /// `readServers`: id and name ("That server" when unnamed).
    public static func list(_ raw: Any?) -> [(id: String, name: String)] {
        ((raw as? [Any]) ?? []).compactMap { entry in
            guard let row = entry as? [String: Any], let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "That server"
            return (id, name)
        }
    }

    /// `readServerPorts`: the ports it is serving, or why it would not say.
    public static func ports(_ raw: Any?) -> (ports: [MachinePort], refused: String?) {
        guard let row = raw as? [String: Any] else { return ([], "That server was asked what it is serving and gave no answer.") }
        guard row["ok"] as? Bool == true else {
            let said = (row["message"] as? String) ?? ""
            return ([], said.isEmpty ? "That server could not be asked what it is serving, and no reason came back." : said)
        }
        let ports = ((row["ports"] as? [Any]) ?? []).compactMap { entry -> MachinePort? in
            guard let one = entry as? [String: Any] else { return nil }
            let port = (one["port"] as? NSNumber)?.intValue ?? Int((one["port"] as? String) ?? "") ?? 0
            guard port > 0 else { return nil }
            return MachinePort(port: port, process: (one["process"] as? String) ?? "", guessed: one["guessed"] as? Bool == true)
        }
        return (ports, nil)
    }

    /// `serverChoices`: ports only once it answered; "Refused" when it would not.
    public static func choice(id: String, name: String, answer: (ports: [MachinePort], refused: String?)?) -> BRMachineChoice {
        BRMachineChoice(kind: "server", id: id, name: name, noun: "server", ports: answer?.refused == nil ? (answer?.ports ?? []) : [],
                        unreachable: answer?.refused == nil ? nil : "Refused")
    }
}
