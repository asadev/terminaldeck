import Foundation
import Testing
@testable import TerminalDeckNativeCore

// The task popup's rules: custom fields (shared/crm/task-fields.ts, with the cases
// main/tasks/task-detail-local.test.ts checks), the text, time and file helpers
// (LocalTaskPopup.test.tsx: a task link in either spelling), routines, the
// activity feed's words and the page's remembered view.

private extension Result {
    var failure: String? { if case .failure(let e) = self { return (e as? FieldFail)?.error } else { return nil } }
    var value: Success? { try? get() }
}

private let CTX = ValueCtx(userId: "me", now: "2026-10-06T08:00:00.000Z")

private func field(_ label: String, _ kind: FieldKind, _ value: CrmValue = .null, config: FieldConfig? = nil, order: Double? = nil,
                   created: String = "2026-10-01") -> TaskField {
    TaskField(id: "id-\(label)", taskId: "t", label: label, kind: kind, config: config ?? TaskFields.defaultConfig(kind), value: value,
              sortOrder: order, createdAt: created)
}

private func options(_ labels: String...) -> FieldConfig {
    var c = FieldConfig()
    c.options = labels.enumerated().map { FieldOption(id: $1.lowercased(), label: $1, color: TaskFields.colors[$0]) }
    return c
}

@Suite("Task fields — the catalogue, names and settings")
struct TaskFieldsCatalogueTests {
    @Test func hasAll23KindsInClickUpOrderWithTheirNames() {
        #expect(FieldKind.allCases.count == 23)
        #expect(TaskFields.types.map(\.kind) == FieldKind.allCases)
        #expect(TaskFields.info(.longText).name == "Text area (Long Text)")
        #expect(FieldGroup.allCases.map(\.label) == ["Basic", "Choice", "Numbers", "Contact", "Links", "Actions"])
        #expect(TaskFields.isComputed(.formula) && TaskFields.isComputed(.progressAuto) && !TaskFields.isComputed(.number))
        #expect(TaskFields.isActionOnly(.voting) && TaskFields.isActionOnly(.button))
        #expect(TaskFields.hasOptions(.dropdown) && !TaskFields.hasOptions(.text))
    }

    @Test func checksAFieldName() {
        #expect(TaskFields.normaliseLabel("  Price   tag ").value == "Price tag")
        #expect(TaskFields.normaliseLabel("   ").failure == "Field name is required")
        #expect(TaskFields.normaliseLabel(String(repeating: "a", count: 81)).failure == "Field name is too long (80 characters max)")
        #expect(TaskFields.normaliseLabel("Total {x}").failure == "Field names cannot contain { or }")
        #expect(TaskFields.sameLabel("Price", " price "))
    }

    @Test func cleansEachKindsSettings() {
        let money = TaskFields.defaultConfig(.money)
        #expect(money.currency == "AED" && money.decimals == 2)
        #expect(TaskFields.normaliseConfig(.money, .object(["currency": .string("usd")])).failure == "Unknown currency “usd”")
        #expect(TaskFields.normaliseConfig(.number, .object(["decimals": .number(9)])).value?.decimals == 6)
        #expect(TaskFields.normaliseConfig(.progressManual, .object(["start": .number(5), "end": .number(5)])).failure == "Start must be less than end")
        #expect(TaskFields.normaliseConfig(.progressAuto, .object(["subtasks": .bool(false), "checklists": .bool(false)])).failure
            == "Count subtasks, checklists, or both")
        #expect(TaskFields.normaliseConfig(.relationship, .object(["areas": .array([.string("deal")])])).failure == "Unknown area “deal”")
        #expect(TaskFields.normaliseConfig(.text, .string("x")).failure == "Settings are malformed")
        let button = TaskFields.defaultConfig(.button)
        #expect(button.label == "Button" && button.color == "#2F6BFF" && button.action == .status("Done"))
        let target = TaskFields.normaliseConfig(.button, .object(["action": .object(["type": .string("field"), "fieldId": .string("nope")])]), siblings: [])
        #expect(target.failure == "The field this button sets is not on this task")
        #expect(TaskFields.normaliseConfig(.formula, .object(["expression": .string("1 +")])).failure == "Formula: The formula ends too early")
    }

    @Test func refusesTwoOptionsWithOneNameAndColoursTheRestInTurn() {
        let twice = CrmValue.array([.object(["label": .string("A")]), .object(["label": .string("a")])])
        #expect(TaskFields.normaliseConfig(.dropdown, .object(["options": twice])).failure == "Two options are called “a”")
        let two = TaskFields.normaliseConfig(.labels, .object(["options": .array([.object(["id": .string("x"), "label": .string(" One ")]),
                                                                                  .object(["id": .string("y"), "label": .string("Two"), "color": .string("#abcdef")])])]))
        #expect(two.value?.options == [FieldOption(id: "x", label: "One", color: "#6B7280"), FieldOption(id: "y", label: "Two", color: "#ABCDEF")])
    }

    @Test func settingsSurviveTheWire() {
        var formula = TaskFields.defaultConfig(.formula)
        formula.expression = "{Price} * {Qty}"
        #expect(formula.crm(.formula)["currency"] == .null)
        #expect(TaskFields.normaliseConfig(.formula, formula.crm(.formula)).value == formula)
        var button = TaskFields.defaultConfig(.button)
        button.action = .comment("Shipped")
        #expect(TaskFields.normaliseConfig(.button, button.crm(.button)).value == button)
    }
}

@Suite("Task fields — the rule every value obeys")
struct TaskFieldsValueTests {
    @Test func readsANumberAsAPersonTypesIt() {
        #expect(TaskFields.toNumber(.string("AED 1,200")) == .value(1200))
        #expect(TaskFields.toNumber(.string("1,200.5")) == .value(1200.5))
        #expect(TaskFields.toNumber(.string("abc")) == .bad)
        #expect(TaskFields.toNumber(.string("  ")) == .empty)
        #expect(TaskFields.toNumber(.string("1e3")) == .value(1000))
        #expect(TaskFields.toNumber(.number(3)) == .value(3))
    }

    @Test func numbersRoundToTheFieldsDecimals() {
        // main/tasks/task-detail-local.test.ts: 12.345 on a Price field is 12.35.
        let price = TaskFields.normaliseValue(.number, TaskFields.defaultConfig(.number), .number(12.345), ctx: CTX)
        #expect(price.value == .number(12.35))
        #expect(TaskFields.normaliseValue(.money, TaskFields.defaultConfig(.money), .string("lots"), ctx: CTX).failure == "That is not a number")
        #expect(TaskFields.normaliseValue(.number, FieldConfig(), .number(2e15), ctx: CTX).failure == "That number is too large")
        #expect(TaskFields.normaliseValue(.number, FieldConfig(), .string(""), ctx: CTX).value == .null)
    }

    @Test func textIsTidiedAndCappedAndComputedKindsRefuseAValue() {
        #expect(TaskFields.normaliseValue(.text, FieldConfig(), .string("  a   b \n c "), ctx: CTX).value == .string("a b c"))
        #expect(TaskFields.normaliseValue(.longText, FieldConfig(), .string("a  \r\n b \n\n"), ctx: CTX).value == .string("a\n b"))
        #expect(TaskFields.normaliseValue(.text, FieldConfig(), .number(1), ctx: CTX).failure == "Text must be text")
        #expect(TaskFields.normaliseValue(.formula, FieldConfig(), .number(1), ctx: CTX).failure == "This field is calculated — it cannot be set by hand")
        #expect(TaskFields.normaliseValue(.voting, FieldConfig(), .null, ctx: CTX).failure == "Use the vote button to vote")
        #expect(TaskFields.normaliseValue(.button, FieldConfig(), .null, ctx: CTX).failure == "Press the button to run it")
    }

    @Test func datesAreCalendarDaysAndTheTimeOnlyWhenTheFieldKeepsOne() {
        let plain = TaskFields.defaultConfig(.date)
        var timed = plain
        timed.includeTime = true
        #expect(TaskFields.normaliseValue(.date, plain, .string("2026-02-30"), ctx: CTX).failure == "That is not a date")
        #expect(TaskFields.normaliseValue(.date, plain, .object(["date": .string("2026-10-05"), "time": .string("09:30")]), ctx: CTX).value
            == .object(["date": .string("2026-10-05"), "time": .null]))
        #expect(TaskFields.normaliseValue(.date, timed, .object(["date": .string("2026-10-05"), "time": .string("09:30")]), ctx: CTX).value
            == .object(["date": .string("2026-10-05"), "time": .string("09:30")]))
        #expect(TaskFields.normaliseValue(.date, timed, .object(["date": .string("2026-10-05"), "time": .string("25:00")]), ctx: CTX).failure
            == "That is not a time (HH:MM)")
        #expect(TaskFields.normaliseValue(.date, plain, .string(""), ctx: CTX).value == .null)
    }

    @Test func contactKindsAreChecked() {
        #expect(TaskFields.normaliseValue(.website, FieldConfig(), .string("example.com"), ctx: CTX).value == .string("https://example.com/"))
        #expect(TaskFields.normaliseValue(.website, FieldConfig(), .string("ftp://example.com"), ctx: CTX).failure == "Only http and https links")
        #expect(TaskFields.normaliseValue(.website, FieldConfig(), .string("nowhere"), ctx: CTX).failure == "That is not a web address")
        #expect(TaskFields.normaliseValue(.email, FieldConfig(), .string("a@b.co"), ctx: CTX).value == .string("a@b.co"))
        #expect(TaskFields.normaliseValue(.email, FieldConfig(), .string("a@b"), ctx: CTX).failure == "That is not an email address")
        #expect(TaskFields.normaliseValue(.phone, FieldConfig(), .string("+971 50 000 0000"), ctx: CTX).value == .string("+971 50 000 0000"))
        #expect(TaskFields.normaliseValue(.phone, FieldConfig(), .string("12345"), ctx: CTX).failure == "A phone number has 6 to 15 digits")
        #expect(TaskFields.normaliseValue(.phone, FieldConfig(), .string("call 123456"), ctx: CTX).failure
            == "A phone number has digits, spaces, + ( ) - only")
    }

    @Test func aLocationTakesCoordinatesFromWhatWasTypedAndLinksToTheMap() {
        let spot = TaskFields.normaliseValue(.location, FieldConfig(), .string("25.2, 55.3"), ctx: CTX).value
        #expect(spot == .object(["text": .string("25.2, 55.3"), "lat": .number(25.2), "lng": .number(55.3)]))
        #expect(TaskFields.mapHref(spot!) == "https://www.google.com/maps/search/?api=1&query=25.2%2C55.3")
        let place = TaskFields.normaliseValue(.location, FieldConfig(), .string("Dubai Mall"), ctx: CTX).value!
        #expect(TaskFields.mapHref(place) == "https://www.google.com/maps/search/?api=1&query=Dubai%20Mall")
        #expect(TaskFields.normaliseValue(.location, FieldConfig(), .string("95, 10"), ctx: CTX).failure == "Latitude is between -90 and 90")
    }

    @Test func choicesStayOnTheField() {
        let c = options("A", "B")
        #expect(TaskFields.normaliseValue(.dropdown, c, .string("z"), ctx: CTX).failure == "That option is not on this field")
        #expect(TaskFields.normaliseValue(.dropdown, c, .string("a"), ctx: CTX).value == .string("a"))
        #expect(TaskFields.normaliseValue(.labels, c, .array([.string("a"), .string("a"), .string("b")]), ctx: CTX).value
            == .array([.string("a"), .string("b")]))
        #expect(TaskFields.normaliseValue(.labels, c, .array([]), ctx: CTX).value == .null)
        let rating = TaskFields.defaultConfig(.rating)
        #expect(TaskFields.normaliseValue(.rating, rating, .number(6), ctx: CTX).failure == "A rating is 1 to 5")
        #expect(TaskFields.normaliseValue(.rating, rating, .number(2.5), ctx: CTX).failure == "A rating is a whole number")
        #expect(TaskFields.normaliseValue(.rating, rating, .number(0), ctx: CTX).value == .null)
        let progress = TaskFields.defaultConfig(.progressManual)
        #expect(TaskFields.normaliseValue(.progressManual, progress, .number(120), ctx: CTX).failure == "Progress is between 0 and 100")
    }

    @Test func idsAreTheCrmsUuidsSoLocalIdsAreLeftToTheEngine() {
        // The engine carries "me", "hoot" and agent slugs across this check; the popup
        // therefore sends People, Tasks and Files values to it unchecked.
        #expect(TaskFields.normaliseValue(.people, FieldConfig(), .array([.string("me")]), ctx: CTX).failure == "A person is malformed")
        let id = "0b9f3c4e-1a2b-4c3d-8e9f-0123456789ab"
        #expect(TaskFields.normaliseValue(.people, FieldConfig(), .array([.string(id), .string(id)]), ctx: CTX).value == .array([.string(id)]))
        #expect(TaskFields.normaliseValue(.tasks, FieldConfig(), .array([.object(["id": .string(id)])]), ctx: CTX).value
            == .array([.object(["id": .string(id), "label": .string("Task")])]))
    }

    @Test func aSignatureIsStampedWithWhoAndWhen() {
        let typed = TaskFields.normaliseValue(.signature, FieldConfig(), .object(["mode": .string("typed"), "text": .string(" Asad ")]), ctx: CTX)
        #expect(typed.value == .object(["mode": .string("typed"), "text": .string("Asad"), "by": .string("me"), "at": .string(CTX.now)]))
        #expect(TaskFields.normaliseValue(.signature, FieldConfig(), .object(["mode": .string("typed"), "text": .string(" ")]), ctx: CTX).failure
            == "Type your name to sign")
        #expect(TaskFields.normaliseValue(.signature, FieldConfig(), .object(["mode": .string("drawn"), "dataUrl": .string("data:text/html;base64,AA")]),
                                          ctx: CTX).failure == "The drawn signature is not an image")
        #expect(TaskFields.normaliseValue(.signature, FieldConfig(), .object(["mode": .string("drawn"), "dataUrl": .string("data:image/png;base64,iVBOR==")]),
                                          ctx: CTX).value?["by"] == .string("me"))
    }

    @Test func editingOptionsReconcilesTheStoredValue() {
        #expect(TaskFields.reconcileValue(.dropdown, options("B"), .string("a")) == .null)
        var three = TaskFields.defaultConfig(.rating)
        three.max = 3
        #expect(TaskFields.reconcileValue(.rating, three, .number(5)) == .number(3))
        #expect(TaskFields.reconcileValue(.date, TaskFields.defaultConfig(.date), .object(["date": .string("2026-10-05"), "time": .string("09:00")]))
            == .object(["date": .string("2026-10-05"), "time": .null]))
    }
}

@Suite("Task fields — the formula engine")
struct TaskFieldsFormulaTests {
    private func run(_ src: String) -> FieldRes<Double> { TaskFields.evaluateFormula(src) { _ in .failure(FieldFail("no fields")) } }

    @Test func computesOverTheTasksNumbers() {
        // main/tasks/task-detail-local.test.ts: Total = {Price} * {Qty}.
        let fields = [field("Price", .number, .number(12.35)), field("Qty", .number, .number(3)), field("Done", .checkbox, .bool(true))]
        let total = TaskFields.computeFormula("{Price} * {Qty}", fields).value ?? 0
        #expect(abs(total - 37.05) < 1e-9)
        #expect(TaskFields.computeFormula("{price} + {Done}", fields).value == 13.35)
        #expect(TaskFields.computeFormula("{Nope}", fields).failure == "Unknown field “Nope”")
        #expect(TaskFields.computeFormula(nil, fields).failure == "No formula yet — Edit options to write one")
        #expect(TaskFields.computeFormula("{Price}", [field("Price", .number)]).failure == "“Price” is empty")
        #expect(TaskFields.computeFormula("{T}", [field("T", .formula)]).failure == "A formula cannot use another formula (“T”)")
        #expect(TaskFields.computeFormula("{N}", [field("N", .text, .string("x"))]).failure == "“N” is not a number field")
        #expect(TaskFields.computeFormula("{P}", [field("P", .number, .number(1)), field("p", .money, .number(2))]).failure == "Two fields are called “P”")
    }

    @Test func knowsItsGrammarAndNothingElse() {
        #expect(run("2 × 3 ÷ 4").value == 1.5)
        #expect(run("-3 + 5").value == 2)
        #expect(run("7 % 4").value == 3)
        #expect(run("round(1.234, 2)").value == 1.23)
        #expect(run("max(1, 5, 3) - min(4, 2)").value == 3)
        #expect(run("abs(-2) + floor(1.7) + ceil(1.2)").value == 5)
        #expect(run(".5 + 1").value == 1.5)
        #expect(run("").failure == "The formula is empty")
        #expect(run("1 +").failure == "The formula ends too early")
        #expect(run("(1").failure == "A ( has no closing )")
        #expect(run(")").failure == "Unexpected )")
        #expect(run("1 2").failure == "Something is missing between two values")
        #expect(run("1/0").failure == "Division by zero")
        #expect(run("abs()").failure == "abs takes 1 value")
        #expect(run("round(1, 2, 3)").failure == "round takes 1 to 2 values")
        #expect(run("eval(1)").failure == "Unknown word “eval” — put field names in {braces}")
        #expect(run("{}").failure == "Empty {} — put a field name inside")
        #expect(run("{a").failure == "A { has no closing }")
        #expect(run("1 $ 2").failure == "Unexpected “$”")
        #expect(run("abs 1").failure == "abs needs ( )")
        #expect(run("round(1, 11)").failure == "round() keeps 0 to 10 decimals")
    }

    @Test func findsAndRenamesItsReferences() {
        #expect(TaskFields.formulaRefs("{A} + {a} * { B  c }") == ["A", "B c"])
        // A rename points the formulas at the new name (renameTaskField → formulas).
        #expect(TaskFields.renameFormulaRefs("{Qty} * {Price} + {qty}", from: "QTY", to: "Count") == "{Count} * {Price} + {Count}")
    }
}

@Suite("Task fields — progress, words and order")
struct TaskFieldsReadTests {
    @Test func progressComesFromSubtasksAndChecklistsOrTheSlider() {
        let auto = AutoProgress(subtasksDone: 1, subtasksTotal: 2, checklistsDone: 1, checklistsTotal: 2)
        let both = TaskFields.autoProgress(TaskFields.defaultConfig(.progressAuto), auto)
        #expect(both.done == 2 && both.total == 4 && both.percent == 50)
        var onlyChecklists = TaskFields.defaultConfig(.progressAuto)
        onlyChecklists.subtasks = false
        #expect(TaskFields.autoProgress(onlyChecklists, auto).total == 2)
        #expect(TaskFields.autoProgress(onlyChecklists, nil).percent == 0)
        var range = FieldConfig()
        range.start = 0
        range.end = 200
        #expect(TaskFields.manualPercent(range, 50) == 25)
        #expect(TaskFields.manualPercent(range, nil) == 0)
    }

    @Test func readsAValueAsWords() {
        var money = TaskFields.defaultConfig(.money)
        money.decimals = 2
        #expect(TaskFields.formatValue(.money, money, .number(1200)) == "AED 1,200.00")
        #expect(TaskFields.formatValue(.number, TaskFields.defaultConfig(.number), .number(1234.5)) == "1,234.5")
        #expect(TaskFields.formatValue(.checkbox, FieldConfig(), .bool(true)) == "Checked")
        #expect(TaskFields.formatValue(.date, FieldConfig(), .object(["date": .string("2026-10-05"), "time": .string("09:30")])) == "5 Oct 2026 09:30")
        #expect(TaskFields.formatValue(.rating, TaskFields.defaultConfig(.rating), .number(3)) == "3/5")
        #expect(TaskFields.formatValue(.labels, options("A", "B"), .array([.string("a"), .string("b")])) == "A, B")
        #expect(TaskFields.formatValue(.people, FieldConfig(), .array([.string("me"), .string("x")]), names: { $0 == "me" ? "You" : nil }) == "You, someone")
        #expect(TaskFields.formatValue(.voting, FieldConfig(), .object(["votes": .object(["me": .bool(true)])])) == "1 votes")
        #expect(TaskFields.formatValue(.button, FieldConfig(), .object(["count": .number(2)])) == "Pressed 2×")
        #expect(TaskFields.formatValue(.signature, FieldConfig(), .object(["mode": .string("typed"), "text": .string("Asad")])) == "Signed “Asad”")
        #expect(TaskFields.formatValue(.text, FieldConfig(), .null) == nil)
    }

    @Test func listsFieldsAsStoredAndDropsAnUnknownKind() {
        let rows = [field("C", .text, order: nil, created: "2026-10-01"), field("B", .text, order: 2), field("A", .text, order: 1),
                    field("D", .text, order: nil, created: "2026-09-01")]
        #expect(TaskFields.sorted(rows).map(\.label) == ["A", "B", "D", "C"])
        #expect(TaskFields.decode(["id": "f", "kind": "hologram", "label": "X"]) == nil)
        let decoded = TaskFields.decode(["id": "f", "taskId": "t", "kind": "number", "label": "Price", "config": [String: Any](), "value": 12.35,
                                         "sortOrder": 0, "createdAt": "2026-10-06"])
        #expect(decoded?.config.decimals == 2 && decoded?.value == .number(12.35) && decoded?.sortOrder == 0)
        #expect(TaskFields.decodeAuto(["subtasks": ["done": 1, "total": 3], "checklists": ["done": 0, "total": 0]])
            == AutoProgress(subtasksDone: 1, subtasksTotal: 3, checklistsDone: 0, checklistsTotal: 0))
    }
}

@Suite("Task popup — text, time and files")
struct TaskPopupHelperTests {
    @Test func readsATaskLinkInEitherSpellingAndNothingElse() {
        // LocalTaskPopup.test.tsx
        #expect(CrmText.linkedTaskId("task:local%3Ab") == "local:b")
        #expect(CrmText.linkedTaskId("/tasks?task=local%3Ab") == "local:b")
        #expect(CrmText.linkedTaskId("https://example.com/?task=x") == nil)
    }

    @Test func splitsATitleIntoItsHeadingAndBody() {
        #expect(CrmText.split("Call the bank\nAsk about the card").heading == "Call the bank")
        #expect(CrmText.split("Call the bank\nAsk about the card").body == "Ask about the card")
        let sentence = CrmText.split("Fix the login. Then ship it")
        #expect(sentence.heading == "Fix the login." && sentence.body == "Then ship it" && !sentence.cut)
        #expect(CrmText.split("  Short  ").heading == "Short")
        #expect(CrmText.split("  Short  ").body.isEmpty)
    }

    @Test func fileTokensSurviveTheTripThroughTheEditor() {
        let text = "See [[file:a1]] then [[file:b2]]"
        #expect(CrmText.fileTokenIds(text) == ["a1", "b2"])
        #expect(CrmText.fromFlat(CrmText.toFlat(text), ids: CrmText.fileTokenIds(text)) == text)
    }

    @Test func readsAndWritesDurations() {
        #expect(CrmTime.parseDuration("1:30") == 5400)
        #expect(CrmTime.parseDuration("90") == 5400)
        #expect(CrmTime.parseDuration("1.5h") == 5400)
        #expect(CrmTime.parseDuration("2h 15m") == 8100)
        #expect(CrmTime.parseDuration("45m") == 2700)
        #expect(CrmTime.parseDuration("soon") == nil)
        #expect(CrmTime.parseDuration("25:00") == nil)
        #expect(CrmTime.duration(5400) == "1h 30m")
        #expect(CrmTime.duration(0) == "0h")
        #expect(CrmTime.clockDuration(3909) == "1:05:09")
    }

    @Test func checksAnUploadAndAddressesAFile() {
        #expect(CrmFiles.checkUpload(name: " ", size: 3) == "The file has no name.")
        #expect(CrmFiles.checkUpload(name: "a.pdf", size: 0) == "The file is empty.")
        #expect(CrmFiles.checkUpload(name: "notes", size: 3) == "“notes” has no file extension, so its type cannot be checked.")
        #expect(CrmFiles.checkUpload(name: "a.pdf", size: 3) == nil)
        #expect(CrmFiles.isImage(mime: nil, fileName: "shot.PNG"))
        let href = CrmFiles.href(taskId: "local:a", attachmentId: "x y")
        #expect(CrmFiles.parseHref(href)?.taskId == "local:a")
        #expect(CrmFiles.parseHref(href)?.attachmentId == "x y")
        #expect(CrmFiles.parseHref("https://x") == nil)
        #expect(CrmFiles.sizeLabel(1536) == "2 KB")
        #expect(CrmFiles.sizeLabel(1_572_864) == "1.5 MB")
        #expect(CrmFiles.sizeLabel(nil).isEmpty)
    }
}

@Suite("Task popup — routines, the feed and the page's memory")
struct TaskPopupRulesTests {
    private func weekly(_ days: [Int]) -> RoutineRule {
        var r = RoutineRule()
        r.frequency = "weekly"
        r.weekdays = days
        return r
    }

    @Test func aRoutineFindsItsNextDayAndSaysItsRule() {
        // 2026-10-05 is a Monday; weekdays count from Sunday = 0.
        #expect(Routine.nextAfter("2026-10-05", weekly([1, 3]), "2026-10-05") == "2026-10-07")
        #expect(Routine.nextAfter("2026-10-05", weekly([1, 3]), "2026-10-07") == "2026-10-12")
        var daily = RoutineRule()
        daily.frequency = "daily"
        #expect(Routine.nextAfter("2026-10-05", daily, "2026-10-05") == "2026-10-06")
        #expect(Routine.summary(weekly([1, 3])) == "Every Mon, Wed, when done")
        daily.skipWeekends = true
        #expect(Routine.summary(daily) == "Every working day, when done")
        #expect(Routine.nextWorkingDay("2026-10-10") == "2026-10-12")
        #expect(Routine.isActive(weekly([1])))
    }

    @Test func aRoutineSurvivesTheWire() {
        let rule = weekly([2, 4])
        #expect(Routine.normalize(Routine.serialize(rule))?.weekdays == [2, 4])
        #expect(Routine.normalize(Routine.serialize(rule))?.frequency == "weekly")
    }

    @Test func theFeedSaysWhenAndWhatChanged() {
        #expect(ActivityFeedRules.relativeDay("2026-10-06", today: "2026-10-06") == "Today")
        #expect(ActivityFeedRules.relativeDay("2026-10-07", today: "2026-10-06") == "Tomorrow")
        #expect(ActivityFeedRules.relativeDay("2026-10-05", today: "2026-10-06") == "Yesterday")
        #expect(ActivityFeedRules.relativeDay("2026-12-25", today: "2026-10-06") == "25 Dec")
        #expect(ActivityFeedRules.relativeDay("2025-12-25", today: "2026-10-06") == "25 Dec 2025")
        // task-fields.ts fieldActivitySentence, line for line.
        #expect(ActivityFeedRules.fieldSentence("You", ["action": .string("added"), "label": .string("Price")]) == "You added field: Price")
        #expect(ActivityFeedRules.fieldSentence("You", ["action": .string("renamed"), "from": .string("Qty"), "to": .string("Count")])
            == "You renamed field: Qty → Count")
        #expect(ActivityFeedRules.fieldSentence("You", ["action": .string("voted"), "label": .string("Votes"), "to": .string("voted")]) == "You voted on Votes")
        #expect(ActivityFeedRules.fieldSentence("You", ["action": .string("changed"), "label": .string("Price"), "to": .null]) == "You cleared Price")
        #expect(ActivityFeedRules.fieldSentence("You", ["action": .string("changed"), "label": .string("Price"), "to": .string("12")])
            == "You set Price: 12")
        #expect(ActivityFeedRules.fieldSentence("You", ["action": .string("changed"), "label": .string("Price"), "from": .string("1"), "to": .string("2")])
            == "You changed Price: 1 → 2")
    }

    @Test func thePageRemembersFavouritesWithinReason() {
        #expect(TaskFavorites.toggled([], "a") == ["a"])
        #expect(TaskFavorites.toggled(["a", "b"], "a") == ["b"])
        #expect(TaskFavorites.read((0..<600).map { "t\($0)" }).count == 500)
        #expect(TaskFavorites.read("nonsense").isEmpty)
        #expect(TasksViewState.read(nil) == TasksViewState())
    }
}
