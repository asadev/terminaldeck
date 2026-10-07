import CoreGraphics
import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// Lane BR: the browser window's Session menu, chips, Annotate's first click,
/// mode hint and handover words — each expectation is the TypeScript's.
@Suite struct BRBrowserParityTests {
    static var view: [String: Any] { ["sessions": [
        ["sessionId": "s1", "machineId": "", "colour": 1, "ended": false,
         "windows": [["n": 2, "browserTabId": "t2", "title": "", "url": "https://b.test/"],
                     ["n": 1, "browserTabId": "t1", "title": "Stripe", "url": "https://stripe.test/", "hostMachineId": "m9", "hostMachineName": "DESKTOP"]]],
        ["sessionId": "s2", "machineId": "", "colour": 6, "ended": true, "windows": [] as [Any]],
    ]] }

    @Test func readsTheBindingsViewWithTitlesAndHosts() {
        let view = BRBindingView.read(Self.view)
        #expect(view.sessions.count == 2)
        let held = view.holder(of: "t1")
        #expect(held?.session.sessionId == "s1")
        #expect(held?.window.slot == "B1")
        #expect(held?.window.host == "DESKTOP")
        #expect(view.session("s1")?.windows.map(\.n) == [1, 2]) // ordered by n
        #expect(view.holder(of: "nope") == nil)
        #expect(BRBindingView.read("junk").sessions.isEmpty)
    }

    @Test func chipWordsAreBindChipTsx() {
        let view = BRBindingView.read(Self.view)
        let s1 = view.session("s1")!
        #expect(BRBindChips.tooltip(s1.windows[0], sessionName: "api · Session 1") == "B1 — Stripe · attached to api · Session 1")
        #expect(BRBindChips.tooltip(s1.windows[1], sessionName: nil) == "B2 — https://b.test/")
        #expect(BRBindChips.tooltip(BRBoundWindow(n: 3, tabId: "x"), sessionName: nil) == "B3 — a browser window")
        let ended = BRBoundSession(sessionId: "s2", ended: true, windows: [BRBoundWindow(n: 1, tabId: "t")])
        #expect(BRBindChips.windowTooltip(ended.windows[0], session: ended, sessionName: nil)
                == "B1 — the session this page belongs to has exited. This is what it was looking at.")
        let three = (1...3).map { BRBoundWindow(n: $0, tabId: "t\($0)") }
        #expect(BRBindChips.split(three).shown.count == 2)
        #expect(BRBindChips.moreLabel(BRBindChips.split(three).rest) == "1 more browser window attached: B3")
        #expect(BRBindChips.connectLabel(slot: nil) == "Attach to a session")
        #expect(BRBindChips.connectLabel(slot: "B1") == "Attached to B1")
        #expect(BRBindChips.colourSlot(6) == 3)
    }

    @Test func connectMenuIsConnectMenuItems() {
        let view = BRBindingView.read(Self.view)
        let sessions = [BrowserSessionChoice(id: "s1", label: "api · Session 1"), BrowserSessionChoice(id: "s3", label: "web · Session 1")]
        // A held window: Disconnect first, a separator, its session ticked with its slot.
        let held = BRConnectMenu.rows(tabId: "t2", sessions: sessions, view: view)
        #expect(held.map(\.label) == ["Disconnect B2", "", "B2   api · Session 1", "web · Session 1"])
        #expect(held[0].act == .detach)
        #expect(held[1].kind == .separator)
        #expect(held[2].checked && held[2].act == .detach)
        #expect(!held[3].checked && held[3].act == .attach(sessionId: "s3", machineId: ""))
        // A free window: just the sessions.
        let free = BRConnectMenu.rows(tabId: "t9", sessions: sessions, view: view)
        #expect(free.map(\.label) == ["api · Session 1", "web · Session 1"])
        // Nothing open.
        let none = BRConnectMenu.rows(tabId: "t9", sessions: [], view: view)
        #expect(none.count == 1 && none[0].label == "No sessions are open." && !none[0].enabled)
        // More than one computer: a header per group, this one first.
        let grouped = BRConnectMenu.rows(tabId: "t9", sessions: sessions, machineOf: { $0 == "s3" ? "m2" : "" },
                                         machineName: { _ in "Laptop" }, thisMachine: "Mini", view: view)
        #expect(grouped.map(\.label) == ["Mini", "api · Session 1", "Laptop", "web · Session 1"])
        #expect(grouped[0].kind == .header && !grouped[0].enabled)
    }

    @Test func connectCommandsAreTheEngineSends() {
        let bind = BRConnectMenu.command(.attach(sessionId: "s1", machineId: ""), tabId: "t1")
        #expect(bind.channel == "browser:bind")
        #expect((bind.argument as? [String: String]) == ["tabId": "t1", "sessionId": "s1", "machineId": ""])
        let unbind = BRConnectMenu.command(.detach, tabId: "t1")
        #expect(unbind.channel == "browser:unbind")
        #expect((unbind.argument as? String) == "t1")
    }

    @Test func inspectCaptureIsElementFromCapture() throws {
        let png = Data([137, 80, 78, 71])
        let raw: [String: Any] = ["id": "tab-1", "tag": "button", "label": "Buy now", "selector": "#buy",
                                  "attributes": ["id": "buy", "class": "x"], "url": "https://shop.test/",
                                  "rect": ["x": 100, "y": 50, "width": 200, "height": 25],
                                  "pageImage": "data:image/png;base64," + png.base64EncodedString()]
        let capture = try #require(BRInspectCapture.read(raw))
        #expect(capture.tabId == "tab-1")
        #expect(capture.element == BrowserAnnotatedElement(role: "<button>", name: "Buy now", identifier: "buy", selector: "#buy"))
        // The tab id is never mistaken for the element's id.
        #expect(capture.element?.identifier != "tab-1")
        let box = try #require(capture.markerRect(viewport: CGSize(width: 1000, height: 500)))
        #expect(box == CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))
        #expect(BRInspectCapture.imageData(capture.pageImage) == png)
        #expect(BRInspectCapture.imageData("https://x/") == nil)
        #expect(BRInspectCapture.read(["tag": "a"]) == nil) // no tab id
        let blank = try #require(BRInspectCapture.read(["id": "t", "pageImage": ""]))
        #expect(blank.element == nil && blank.cssRect == nil)
    }

    @Test func modeHintIsModesTs() {
        #expect(BRBrowserModes.hint(inspecting: true, drawing: false, hasCapture: false) == "Click what you want to change. Escape stops.")
        #expect(BRBrowserModes.hint(inspecting: true, drawing: false, hasCapture: true) == "")
        #expect(BRBrowserModes.hint(inspecting: false, drawing: true, hasCapture: false) == "Drag on the page to mark it. Escape leaves without saving.")
        #expect(BRBrowserModes.hint(inspecting: false, drawing: false, hasCapture: false) == "")
    }

    @Test func handoverWordsAreDriveBanner() {
        #expect(BRHandoverWords.text(prompt: "  ") == "Take over this page, then say you are done.")
        #expect(BRHandoverWords.text(prompt: "Sign in, please") == "Sign in, please")
        #expect(BRHandoverWords.site(URL(string: "https://bank.test/login")) == " · bank.test")
        #expect(BRHandoverWords.site(nil) == "")
        #expect(BRHandoverWords.carryOn == "Done, carry on")
        #expect(BRHandoverWords.stop == "Stop — I’ll take it from here")
    }

    @Test func pageMenuOpensOnlyWebAddressesOutside() {
        #expect(BRPageMenu.mayOpenOutside("https://example.com/a"))
        #expect(BRPageMenu.mayOpenOutside("http://localhost:3000/"))
        #expect(!BRPageMenu.mayOpenOutside("file:///Users/x/secret"))
        #expect(!BRPageMenu.mayOpenOutside("javascript:alert(1)"))
        #expect(!BRPageMenu.mayOpenOutside(""))
        #expect(!BRPageMenu.hasPage("about:blank"))
        #expect(BRPageMenu.hasPage("https://a.test/"))
    }

    @Test func customSizeIsParseDimension() {
        #expect(BRDeviceSize.parse(" 390 ") == 390)
        #expect(BRDeviceSize.parse("199") == nil && BRDeviceSize.parse("4001") == nil)
        #expect(BRDeviceSize.parse("39a") == nil && BRDeviceSize.parse("") == nil && BRDeviceSize.parse("-300") == nil)
        #expect(BRDeviceSize.frame(deviceID: nil, customWidth: "390", customHeight: "844") == nil)
        let custom = BRDeviceSize.frame(deviceID: "custom", customWidth: "390", customHeight: "844")
        #expect(custom?.label == "Custom" && custom?.width == 390 && custom?.height == 844)
        // Mid-edit fills the window rather than a 3-pixel page.
        #expect(BRDeviceSize.frame(deviceID: "custom", customWidth: "3", customHeight: "844") == nil)
        #expect(BRDeviceSize.frame(deviceID: "phone", customWidth: "", customHeight: "")?.width == 390)
    }

    @Test func historyIsHistoryPanel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03, UTC
        let ms = { (seconds: Double) in (now.timeIntervalSince1970 - seconds) * 1000 }
        let raw: [Any] = [["url": "https://www.example.com/a", "title": "", "visitedAt": ms(60)],
                          ["url": "https://b.test/", "title": " B ", "visitedAt": ms(30)],
                          ["url": "https://c.test/", "title": "C", "visitedAt": ms(86_400)],
                          ["title": "no address"]]
        let visits = BRHistoryVisit.list(raw)
        #expect(visits.count == 3)
        #expect(visits[0].label == "https://www.example.com/a" && visits[0].host == "example.com")
        #expect(visits[1].label == "B")
        let days = BRHistory.byDay(visits, now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(days.map(\.heading) == ["Today", "Yesterday"])
        #expect(days[0].visits.map(\.url) == ["https://b.test/", "https://www.example.com/a"]) // newest first
        #expect(BRHistory.title(profileName: "") == "History" && BRHistory.title(profileName: "Work") == "History — Work")
        #expect(BRHistory.empty(searching: true) == "Nothing matches." && BRHistory.empty(searching: false) == "Nothing yet.")
    }

    @Test func driveBandIsDriveChipText() {
        #expect(BRDriveChip.text(state: "agent", step: "") == "Hoot is driving")
        #expect(BRDriveChip.text(state: "agent", step: "working on the page") == "Hoot is working on the page")
        #expect(BRDriveChip.text(state: "human", step: "") == "Your turn")
        #expect(BRDriveChip.text(state: "idle", step: "x") == "")
        #expect(BRDriveChip.site("https://shop.test/cart") == " on shop.test")
        #expect(BRDriveChip.site("") == "")
    }

    @Test func machineChoicesAreMachinesBridge() {
        let view = MachinesView(json: ["machines": [["id": "m1", "name": "", "platform": "win32"], ["id": "m2", "name": "Studio", "platform": "darwin"],
                                                    ["id": "m3", "name": "Old", "platform": "darwin"]],
                                       "links": [["id": "m1", "state": "online", "capabilities": ["localhost"],
                                                  "ports": [["port": 5173, "guessed": true], ["port": 3000]]],
                                                 ["id": "m3", "state": "online", "capabilities": [] as [Any]]],
                                       "here": "Mini"])
        let choices = BRMachines.choices(view)
        #expect(choices.map(\.name) == ["That PC", "Studio", "Old"])
        #expect(choices[0].ports.map(\.port) == [3000, 5173]) // sure ones first
        #expect(choices[0].unreachable == nil)
        #expect(choices[1].unreachable == "Not connected")
        #expect(choices[2].unreachable == "Older build")
        #expect(BRMachines.label(choices, selected: "m2", here: "Mini") == "Studio")
        #expect(BRMachines.label(choices, selected: "", here: "Mini") == "Mini")
    }

    @Test func movingAPageIsMoveFor() {
        let held = BRReachedPort(machineId: "m1", machineName: "PC", port: 3000, localPort: 41000, sameNumber: false)
        #expect(BRMachines.loopbackPort("http://localhost:3000/x") == 3000)
        #expect(BRMachines.loopbackPort("https://127.0.0.1/") == 443)
        #expect(BRMachines.loopbackPort("http://[::1]:8080/") == 8080)
        #expect(BRMachines.loopbackPort("https://example.com:3000/") == nil)
        #expect(BRMachines.move(to: "m1", url: "http://localhost:3000/a?b=1", opened: []) == .there(machineId: "m1", port: 3000, url: "http://localhost:3000/a?b=1"))
        #expect(BRMachines.move(to: "", url: "http://localhost:3000/", opened: []) == .already)
        #expect(BRMachines.move(to: "m1", url: "", opened: []) == .choose)
        #expect(BRMachines.move(to: "m1", url: "https://example.com/", opened: []) == .refused(at: ""))
        // Back here from a page m1 serves on :41000: localhost:3000 here; nothing of m1's sits on :3000 (TS inTheWay).
        #expect(BRMachines.move(to: "", url: "http://localhost:41000/p#h", opened: [held])
                == .here(url: "http://localhost:3000/p#h", give: nil))
        // m1 kept its number, so its tunnel is in the way and is given back first.
        let same = BRReachedPort(machineId: "m1", machineName: "PC", port: 3000, localPort: 3000)
        #expect(BRMachines.move(to: "", url: "http://localhost:3000/", opened: [same]) == .here(url: "http://localhost:3000/", give: same))
        #expect(BRMachines.reachedAddress(typed: "http://localhost:3000/a/b?q=1#f", opened: "http://127.0.0.1:41000/")
                == "http://127.0.0.1:41000/a/b?q=1#f")
        #expect(BRMachines.servedBy("http://localhost:41000/", opened: [held]) == held)
    }

    @Test func reachAnswersAreReachLedger() {
        let opened = BRMachines.readHeld(["answer": ["ok": true, "url": "http://127.0.0.1:41000/", "port": 3000, "localPort": 41000, "sameNumber": false],
                                          "stranded": ["machineId": "m2", "machineName": "Studio", "port": 3000, "localPort": 41000]])
        #expect(opened.url == "http://127.0.0.1:41000/" && opened.opened?.localPort == 41000)
        #expect(opened.stranded.map(BRMachines.strandedNote) == "Studio is still serving port 41000 here.")
        #expect(BRMachines.readHeld(["answer": ["ok": false, "message": "PC refused."]]).message == "PC refused.")
        #expect(BRMachines.readHeld(["answer": ["ok": false]]).message == "That port could not be opened, and no reason came back.")
        #expect(BRMachines.readHeld(nil).message == "That machine was asked for the port and gave no answer.")
        #expect(BRMachines.readHeld(["answer": ["ok": true, "url": ""]]).message == "That machine answered about the port without saying where to open it.")
        #expect(BRMachines.differentPortNote(port: 3000, localPort: 41000, sameNumber: false, machineName: "PC") == "PC:3000 → :41000")
        #expect(BRMachines.differentPortNote(port: 3000, localPort: 3000, sameNumber: true, machineName: "PC") == "")
        let held = BRReachedPort(machineId: "m1", machineName: "PC", port: 3000, localPort: 3000)
        #expect(BRMachines.afterHandBack(["gone": true], held: held) == nil)
        #expect(BRMachines.afterHandBack(["gone": false, "message": "Another browser window is still reading PC:3000 here."], held: held)?.notice
                == "Another browser window is still reading PC:3000 here.")
        #expect(BRMachines.afterHandBack(nil, held: held)?.notice == "PC is still serving port 3000 here.")
    }

    @Test func servedMarkIsServedMarkTs() {
        let page = BRReachedPort(machineId: "m1", machineName: "PC", port: 3000, localPort: 41000, sameNumber: false)
        #expect(BRMachines.servedMark(page: page, picked: "m1", blank: false, here: "Mini") == (":3000", "PC:3000 → :41000"))
        #expect(BRMachines.servedMark(page: page, picked: "", blank: false, here: "Mini") == ("PC:3000", "PC:3000 → :41000"))
        let same = BRReachedPort(machineId: "m1", machineName: "PC", port: 3000, localPort: 3000)
        #expect(BRMachines.servedMark(page: same, picked: "m1", blank: false, here: "Mini") == ("", ""))
        #expect(BRMachines.servedMark(page: nil, picked: "m1", blank: false, here: "Mini") == ("Mini", "Mini"))
        #expect(BRMachines.servedMark(page: nil, picked: "m1", blank: true, here: "Mini") == ("", ""))
        #expect(BRMachines.servedMark(page: nil, picked: "", blank: false, here: "Mini") == ("", ""))
    }

    @Test func serversAreServerMachines() {
        #expect(BRServers.list([["id": "s1", "name": ""], ["name": "x"]]).map(\.name) == ["That server"])
        let ready = BRServers.ports(["ok": true, "ports": [["port": 8080, "process": "node"], ["port": "9000"], ["port": 0]]])
        #expect(ready.refused == nil && ready.ports.map(\.port) == [8080, 9000])
        #expect(BRServers.ports(["ok": false]).refused == "That server could not be asked what it is serving, and no reason came back.")
        #expect(BRServers.ports(nil).refused == "That server was asked what it is serving and gave no answer.")
        #expect(BRServers.choice(id: "s1", name: "Box", answer: nil).ports.isEmpty)
        #expect(BRServers.choice(id: "s1", name: "Box", answer: ([], "nope")).unreachable == "Refused")
        #expect(BRServers.choice(id: "s1", name: "Box", answer: ready).ports.count == 2)
    }

    /// Walk 4: `try await view.evaluateJavaScript(js, in: frame, in: world)` is the
    /// completion-handler method with the handler left out. It returns nothing at once,
    /// so every page read came back empty. The value-returning form is `contentWorld:`.
    @Test func noAwaitedEvaluateUsesTheFireAndForgetForm() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckNative", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 50)
        var found: [String] = []
        let pattern = try NSRegularExpression(pattern: #"await\b.*evaluateJavaScript\([^\n]*,\s*in:\s*[^,]+,\s*in:"#)
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.contains("completionHandler") { continue }
                if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "Awaited fire-and-forget evaluateJavaScript: " + found.joined(separator: ", ")))
    }
}
