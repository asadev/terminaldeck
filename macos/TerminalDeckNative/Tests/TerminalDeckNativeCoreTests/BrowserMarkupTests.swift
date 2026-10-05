import CoreGraphics
import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Browser Record")
struct BrowserFlowTests {
    func payload(_ kind: String, selector: String = "#q", label: String = "Search", tag: String = "input",
                 type: String = "text", extra: [String: Any] = [:]) -> [String: Any] {
        var out: [String: Any] = ["v": 1, "kind": kind,
                                  "target": ["selector": selector, "label": label, "tag": tag, "type": type]]
        for (k, v) in extra { out[k] = v }
        return out
    }

    @Test func stepsFromThePage() {
        let typed = BrowserFlow.parse(payload("type", extra: ["value": "shoes\nred"]), url: "https://a.test/", at: 1)
        #expect(typed?.kind == .type)
        #expect(typed?.value == "shoes red", "one line, always")
        #expect(typed?.url == "https://a.test/")

        let secret = BrowserFlow.parse(payload("type", type: "password", extra: ["value": "hunter2"]), url: "", at: 1)
        #expect(secret?.redacted == true)
        #expect(secret?.value == "", "a password's value is never recorded")
        let flagged = BrowserFlow.parse(payload("type", extra: ["secret": true, "value": "123456"]), url: "", at: 1)
        #expect(flagged?.redacted == true && flagged?.value == "")

        #expect(BrowserFlow.parse(payload("press", extra: ["key": "Enter"]), url: "", at: 1)?.key == "Enter")
        #expect(BrowserFlow.parse(payload("press", extra: ["key": "a"]), url: "", at: 1) == nil, "only notable keys")
        #expect(BrowserFlow.parse(payload("check", extra: ["checked": true]), url: "", at: 1)?.checked == true)
        #expect(BrowserFlow.parse(payload("navigate"), url: "", at: 1) == nil, "the page cannot post a navigation")
        #expect(BrowserFlow.parse(["v": 2, "kind": "click", "target": [:]], url: "", at: 1) == nil)
        #expect(BrowserFlow.parse("junk", url: "", at: 1) == nil)
    }

    @Test func repeatsFold() {
        var steps: [BrowserRecordedStep] = []
        steps = BrowserFlow.append(steps, BrowserFlow.navigate("https://a.test/", at: 0))
        steps = BrowserFlow.append(steps, BrowserFlow.navigate("https://a.test/", at: 10))
        #expect(steps.count == 1, "the same address twice is one visit")

        let t1 = BrowserRecordedStep(kind: .type, selector: "#q", value: "sh", at: 20)
        let t2 = BrowserRecordedStep(kind: .type, selector: "#q", value: "shoes", at: 30)
        steps = BrowserFlow.append(BrowserFlow.append(steps, t1), t2)
        #expect(steps.count == 2 && steps.last?.value == "shoes", "typing keeps the last value")

        let c1 = BrowserRecordedStep(kind: .click, selector: "#go", at: 100)
        let c2 = BrowserRecordedStep(kind: .click, selector: "#go", at: 300)
        let c3 = BrowserRecordedStep(kind: .click, selector: "#go", at: 900)
        steps = BrowserFlow.append(BrowserFlow.append(BrowserFlow.append(steps, c1), c2), c3)
        #expect(steps.count == 4, "a double click is one click; a later one is another")

        var full = (0..<250).reduce([BrowserRecordedStep]()) { list, i in
            BrowserFlow.append(list, BrowserFlow.navigate("https://a.test/\(i)", at: Double(i)))
        }
        #expect(full.count == BrowserFlow.maxSteps)
        full = BrowserFlow.append(full, c1)
        #expect(full.count == BrowserFlow.maxSteps)
        #expect(BrowserFlow.text(full).hasSuffix("(stopped at 200 steps)"))
    }

    @Test func theFlowAsWords() {
        let steps = [
            BrowserFlow.navigate("https://a.test/login", at: 0),
            BrowserRecordedStep(kind: .type, selector: "#email", label: "Email", value: "a@b.c", at: 1),
            BrowserRecordedStep(kind: .type, selector: "#pw", label: "Password", redacted: true, at: 2),
            BrowserRecordedStep(kind: .check, selector: "#keep", label: "Keep me in", checked: false, at: 3),
            BrowserRecordedStep(kind: .press, selector: "#pw", key: "Enter", at: 4),
            BrowserRecordedStep(kind: .click, tag: "div", at: 5),
        ]
        #expect(BrowserFlow.text(steps) == """
        1. Go to https://a.test/login
        2. Type "a@b.c" into "Email" (`#email`)
        3. Type the password into "Password" (`#pw`)
        4. Uncheck "Keep me in" (`#keep`)
        5. Press Enter in `#pw`
        6. Click <div>
        """)
        #expect(BrowserFlow.line(steps).hasPrefix("[browser flow: 1) Go to https://a.test/login; 2) Type \"a@b.c\""))
        #expect(BrowserFlow.compose(instruction: "do this\nagain", steps: [steps[0]])
                == "do this again [browser flow: 1) Go to https://a.test/login]")
        #expect(BrowserFlow.detail(steps[2]) == "the password")
        #expect(BrowserFlow.kindLabel(.navigate) == "Go")
        #expect(BrowserFlow.line([]) == "")
        let long = (0..<100).map { BrowserFlow.navigate("https://example.com/\($0)", at: Double($0)) }
        #expect(BrowserFlow.line(long).count == 1201, "capped, with an ellipsis")
    }
}

@Suite("Browser Draw and Annotate")
struct BrowserMarkupRuleTests {
    @Test func marks() {
        var free = BrowserMarks.begin(.free, at: BrowserPoint(x: 0.1, y: 0.1))
        free = BrowserMarks.extend(free, to: BrowserPoint(x: 0.1005, y: 0.1))
        #expect(free.points.count == 2, "tiny moves are not sampled")
        free = BrowserMarks.extend(free, to: BrowserPoint(x: 0.2, y: 0.2))
        #expect(free.points.count == 3)
        #expect(BrowserMarks.isDrawn(free))
        #expect(!BrowserMarks.isDrawn(BrowserMarks.begin(.rect, at: BrowserPoint(x: 0.5, y: 0.5))), "a click is not a mark")

        let box = BrowserMarks.extend(BrowserMarks.begin(.rect, at: BrowserPoint(x: 0.1, y: 0.2)), to: BrowserPoint(x: 1.5, y: -1))
        #expect(box.points == [BrowserPoint(x: 0.1, y: 0.2), BrowserPoint(x: 1, y: 0)], "kept on the picture")
        let paths = BrowserMarks.paths(box, width: 100, height: 50)
        #expect(paths.count == 1 && paths[0].count == 5, "a closed rectangle")

        let arrow = BrowserMarks.extend(BrowserMarks.begin(.arrow, at: BrowserPoint(x: 0, y: 0.5)), to: BrowserPoint(x: 1, y: 0.5))
        let arrowPaths = BrowserMarks.paths(arrow, width: 1000, height: 500)
        #expect(arrowPaths.count == 2, "shaft and head")
        #expect(arrowPaths[1][1] == BrowserPoint(x: 1000, y: 250), "the head meets the tip")
        #expect(arrowPaths[1][0].x < 1000 && arrowPaths[1][2].x < 1000)

        let text = BrowserMarks.begin(.text, at: BrowserPoint(x: 0.3, y: 0.4), text: "  Too big ")
        #expect(BrowserMarks.isDrawn(text))
        #expect(!BrowserMarks.isDrawn(BrowserMarks.begin(.text, at: BrowserPoint(x: 0, y: 0), text: " ")))
        #expect(BrowserMarks.paths(text, width: 10, height: 10).isEmpty)
        #expect(BrowserMarks.strokeWidth(2560) == 5)
        #expect(BrowserMarks.strokeWidth(300) == 2)
    }

    @Test func annotationsNumberAndRenumber() {
        var list: [BrowserAnnotation] = []
        let a = BrowserAnnotation(id: "a", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                                  element: BrowserAnnotatedElement(role: "<button>", name: "Save", selector: "#save"))
        let b = BrowserAnnotation(id: "b", rect: BrowserAnnotate.boxAround(x: 0.99, y: 0.5), element: nil)
        let c = BrowserAnnotation(id: "c", rect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), element: nil)
        list = BrowserAnnotate.add(BrowserAnnotate.add(BrowserAnnotate.add(list, a), b), c)
        #expect(list.map(\.n) == [1, 2, 3])
        #expect(list[1].rect.maxX <= 1.0000001, "a box near the edge stays on the picture")
        list = BrowserAnnotate.remove(list, id: "b")
        #expect(list.map(\.id) == ["a", "c"] && list.map(\.n) == [1, 2], "numbers follow the list")

        #expect(BrowserAnnotate.describe(nil) == "blank space")
        #expect(BrowserAnnotate.describe(list[0].element) == "<button> \"Save\" (selector #save)")
        #expect(BrowserAnnotate.describeMarker(list[0]) == "#1 <button> \"Save\" (selector #save) at 10% across, 10% down, 20% x 10%")

        let line = BrowserAnnotate.compose(list, url: "http://localhost:3000/", title: "App", note: "Make it\nbigger",
                                           picturePath: "/p/app-annotated.png", width: 1280, height: 800)
        #expect(line == "[Annotate: 2 marked elements on the page http://localhost:3000/ titled \"App\"; picture with the numbered markers: /p/app-annotated.png (1280 x 800)] #1 <button> \"Save\" (selector #save) at 10% across, 10% down, 20% x 10%; #2 blank space at 50% across, 50% down, 10% x 10%. What should change: Make it bigger")
    }

    @Test func theRoundTheEngineKeeps() throws {
        let list = BrowserAnnotate.add([], BrowserAnnotation(id: "a", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                                             element: BrowserAnnotatedElement(role: "<a>", name: "Docs")))
        let round = BrowserAnnotate.round(id: "round-1", createdAt: 5, list: list, url: "https://a.test/", title: "A",
                                          note: "n", width: 100, height: 50)
        #expect(JSONSerialization.isValidJSONObject(round))
        let whereValue = round["where"] as? [String: Any]
        #expect(whereValue?["kind"] as? String == "browser")
        #expect(whereValue?["place"] as? String == "browser page")
        #expect(whereValue?["url"] as? String == "https://a.test/")
        let first = (round["annotations"] as? [[String: Any]])?.first
        #expect(first?["n"] as? Int == 1)
        #expect((first?["element"] as? [String: Any])?["name"] as? String == "Docs")
        #expect((first?["rect"] as? [String: Any])?["width"] as? Double == 0.3)
    }

    @Test func picksAndGeometry() {
        let element = BrowserAnnotatedElement.read(["tag": "button", "label": "Go", "id": "go", "selector": "#go"])
        #expect(element == BrowserAnnotatedElement(role: "<button>", name: "Go", identifier: "go", selector: "#go"))
        #expect(BrowserAnnotatedElement.read(["tag": ""]) == nil)
        #expect(BrowserAnnotatedElement.read(nil) == nil)

        let rect = BrowserAnnotate.normalise(CGRect(x: 100, y: 50, width: 200, height: 600), viewport: CGSize(width: 1000, height: 500))
        #expect(rect == CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.9), "clamped to the picture")
        #expect(BrowserAnnotate.normalise(.zero, viewport: CGSize(width: 10, height: 10)) == nil)

        let g = BrowserAnnotate.markerGeometry(CGRect(x: 0, y: 0, width: 0.1, height: 0.1), width: 1000, height: 680)
        #expect(g.radius == 20 && g.stroke == 3)
        #expect(g.badge.x == 23 && g.badge.y == 23, "the badge stays inside the picture")
    }

    @Test func aDrawnShotSaysSo() {
        let line = BrowserShot.compose(instruction: "", path: "/p.png", url: URL(string: "https://a.test/"), title: "",
                                       width: 10, height: 20, marks: 3)
        #expect(line == "[browser screenshot with 3 marks on it of https://a.test/: /p.png (10 x 20)]")
        let zone = TimeZone(identifier: "UTC")!
        #expect(BrowserShot.fileName(url: nil, now: Date(timeIntervalSince1970: 0), timeZone: zone, suffix: "-marked")
                == "page-19700101-000000-marked.png")
    }

    @Test func pageScriptsAreNamed() {
        #expect(BrowserDriverScripts.name(of: BrowserDriverScripts.pickAt) == "pickAt")
        #expect(BrowserDriverScripts.name(of: BrowserDriverScripts.recorder) == "recorder")
        #expect(BrowserDriverScripts.recorder.contains("messageHandlers.tdRecord"))
        #expect(BrowserDriverScripts.recorder.contains("secret: true"), "password fields are posted as secret")
        #expect(BrowserDriverScripts.recorder.contains("__tdRecording !== true"), "nothing is posted unless recording")
    }
}

@Suite("Browser history suggestions")
struct BrowserHistoryTests {
    @Test func visitsFoldPerProfile() {
        var list: [BrowserVisit] = []
        list = BrowserHistory.note(list, profileID: "default", url: "https://www.example.com/", title: "Example", at: 1)
        list = BrowserHistory.note(list, profileID: "default", url: "https://www.example.com/", title: "", at: 2)
        list = BrowserHistory.note(list, profileID: "work", url: "https://www.example.com/", title: "Work view", at: 3)
        list = BrowserHistory.note(list, profileID: "default", url: "javascript:alert(1)", title: "x", at: 4)
        list = BrowserHistory.note(list, profileID: "", url: "https://a.test/", title: "x", at: 5)
        #expect(list.count == 2, "one row per address per profile; never a non-web address")
        let row = list.first { $0.profileID == "default" }
        #expect(row?.visits == 2 && row?.title == "Example" && row?.visitedAt == 2, "an empty title keeps the old one")
        list = BrowserHistory.retitle(list, profileID: "default", url: "https://www.example.com/", title: "New\ttitle")
        #expect(list.first { $0.profileID == "default" }?.title == "New title")
        #expect(BrowserHistory.profileKey("") == "default")

        let capped = (0..<10).reduce([BrowserVisit]()) {
            BrowserHistory.note($0, profileID: "p", url: "https://a.test/\($1)", title: "", at: Double($1), limit: 5)
        }
        #expect(capped.count == 5 && capped.first?.url == "https://a.test/9")
    }

    @Test func suggestionsRankByHowTheyStart() {
        let list = [
            BrowserVisit(profileID: "default", url: "https://www.github.com/", title: "GitHub", visitedAt: 1, visits: 1),
            BrowserVisit(profileID: "default", url: "https://docs.github.com/", title: "Docs", visitedAt: 5, visits: 9),
            BrowserVisit(profileID: "default", url: "https://example.com/gizmo", title: "Gizmos", visitedAt: 9, visits: 1),
            BrowserVisit(profileID: "work", url: "https://github.com/work", title: "Work", visitedAt: 9, visits: 50),
        ]
        let got = BrowserHistory.suggest(list, profileID: "default", typed: "gi")
        #expect(got.map(\.url) == ["https://www.github.com/", "https://example.com/gizmo", "https://docs.github.com/"],
                "address starts with it, then title starts with it, then anywhere; another profile's rows never")
        #expect(BrowserHistory.suggest(list, profileID: "default", typed: "github").map(\.url)
                == ["https://www.github.com/", "https://docs.github.com/"])
        #expect(BrowserHistory.suggest(list, profileID: "default", typed: " ").isEmpty)
        #expect(list[0].host == "github.com" && list[0].label == "GitHub")
        #expect(BrowserVisit(profileID: "p", url: "http://localhost:3000/x", title: " ", visitedAt: 0).host == "localhost:3000")
    }

    @Test func historyFileRoundTrip() {
        let list = [BrowserVisit(profileID: "default", url: "https://a.test/", title: "A", visitedAt: 7, visits: 3)]
        #expect(BrowserHistory.decode(BrowserHistory.encode(list)) == list)
        let json = #"{"version":1,"entries":[{"profileID":"p","url":"ftp://x"},{"url":"https://no-profile.test/"},{"profileID":"p","url":"https://ok.test/","visits":0}]}"#
        let read = BrowserHistory.decode(Data(json.utf8))
        #expect(read.map(\.url) == ["https://ok.test/"])
        #expect(read.first?.visits == 1)
        #expect(BrowserHistory.decode(nil).isEmpty)
        #expect(BrowserHistory.forget(list, profileID: "default", url: "https://a.test/").isEmpty)
        #expect(BrowserHistory.clear(list, profileID: "other") == list)
    }
}
