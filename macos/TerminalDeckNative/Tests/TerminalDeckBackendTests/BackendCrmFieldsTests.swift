import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private extension Result where Failure == FieldFail {
    var crmError: String? { if case .failure(let error) = self { error.error } else { nil } }
    var crmValue: Success? { try? get() }
}

@Suite("Backend CRM field rules and formula boundaries")
struct BackendCrmFieldsTests {
    private let context = ValueCtx(userId: "actual-caller", now: "2026-10-06T08:00:00.000Z")
    private func evaluate(_ text: String) -> FieldRes<Double> {
        BackendCrmFields.evaluateFormula(text) { _ in .failure(FieldFail("No field")) }
    }
    @Test func catalogueKeepsAll23StorageKeys() {
        #expect(BackendCrmFields.fieldKinds.count == 23)
        #expect(BackendCrmFields.fieldKinds.first == "dropdown")
        #expect(BackendCrmFields.fieldKinds.last == "button")
        #expect(BackendCrmFields.fieldTypeInfo(.longText).name == "Text area (Long Text)")
        #expect(BackendCrmFields.buttonTargetKinds.contains(.location))
        #expect(!BackendCrmFields.buttonTargetKinds.contains(.signature))
    }
    @Test func relationshipUsesBoundedShimAreasWhileTagSearchStaysLocal() {
        #expect(BackendCrmShim.isTagArea(.string("deal")))
        #expect(!BackendCrmTags.isTagArea("deal"))
        #expect(BackendCrmShim.isTagArea(.string(String(repeating: "x", count: 40))))
        #expect(!BackendCrmShim.isTagArea(.string(String(repeating: "x", count: 41))))
        let config = BackendCrmFields.normaliseConfig(.relationship, .object(["areas": .array([.string("deal"), .string("deal")])])).crmValue
        #expect(config?.areas == ["deal"])
        let row: CrmValue = .object(["area": .string("deal"), "id": .string("d1"), "label": .string("A sale"), "href": .string("/deals/d1")])
        #expect(BackendCrmFields.normaliseValue(.relationship, config!, .array([row, row]), ctx: context).crmValue == .array([row]))
    }
    @Test func relationshipRefusesAnExternalOrAmbiguousInternalAddress() {
        var config = FieldConfig(); config.areas = ["task"]
        for href in ["//outside/path", "javascript:alert(1)", "/tasks\\evil", "/tasks path"] {
            let row: CrmValue = .object(["area": .string("task"), "id": .string("1"), "label": .string("One"), "href": .string(href)])
            #expect(BackendCrmFields.normaliseValue(.relationship, config, .array([row]), ctx: context).crmError == "A link must point inside the CRM")
        }
    }
    @Test func untrustedSettingsClampBeforeConvertingToAnInteger() {
        #expect(BackendCrmFields.normaliseConfig(.number, .object(["decimals": .number(1e300)])).crmValue?.decimals == 6)
        #expect(BackendCrmFields.normaliseConfig(.number, .object(["decimals": .number(-1e300)])).crmValue?.decimals == 0)
        #expect(BackendCrmFields.normaliseConfig(.number, .object(["decimals": .string("0x4")])).crmValue?.decimals == 4)
        #expect(BackendCrmFields.normaliseConfig(.rating, .object(["max": .number(.infinity)])).crmValue?.max == 5)
        #expect(BackendCrmFields.normaliseConfig(.money, .object(["currency": .string("usd")])).crmError == "Unknown currency “usd”")
    }
    @Test func fieldNamesAndTextUseUTF16Limits() {
        #expect(BackendCrmFields.normaliseFieldLabel(.string(String(repeating: "😀", count: 40))).crmValue != nil)
        #expect(BackendCrmFields.normaliseFieldLabel(.string(String(repeating: "😀", count: 41))).crmError == "Field name is too long (80 characters max)")
        #expect(BackendCrmFields.normaliseValue(.text, FieldConfig(), .string(String(repeating: "😀", count: 251)), ctx: context).crmError == "Text is too long (500 characters max)")
        let longOption: CrmValue = .object(["options": .array([.object(["label": .string(String(repeating: "😀", count: 31))])])])
        #expect(BackendCrmFields.normaliseConfig(.dropdown, longOption).crmError == "Option “\(String(repeating: "😀", count: 10))…” is too long (60 max)")
    }
    @Test func websiteNormalizesSpecialSchemesAndDefaultPorts() {
        #expect(BackendCrmFields.normaliseWebsite(.string("https:Example.COM:443/a/../b")).crmValue == "https://example.com/b")
        #expect(BackendCrmFields.normaliseWebsite(.string("http://localhost:80")).crmValue == "http://localhost/")
        #expect(BackendCrmFields.normaliseWebsite(.string("127.1")).crmValue == "https://127.0.0.1/")
        #expect(BackendCrmFields.normaliseWebsite(.string("0x7f000001")).crmValue == "https://127.0.0.1/")
        #expect(BackendCrmFields.normaliseWebsite(.string("256.0.0.1")).crmError == "That is not a web address")
        #expect(BackendCrmFields.normaliseWebsite(.string("javascript:alert(1)")).crmError == "Only http and https links")
        #expect(BackendCrmFields.normaliseWebsite(.string("nowhere")).crmError == "That is not a web address")
    }
    @Test func authorityOwnedFieldsCannotBeWrittenDirectly() {
        #expect(BackendCrmFields.normaliseValue(.formula, FieldConfig(), .number(4), ctx: context).crmError == "This field is calculated — it cannot be set by hand")
        #expect(BackendCrmFields.normaliseValue(.progressAuto, FieldConfig(), .null, ctx: context).crmError == "This field is calculated — it cannot be set by hand")
        #expect(BackendCrmFields.normaliseValue(.voting, FieldConfig(), .null, ctx: context).crmError == "Use the vote button to vote")
        #expect(BackendCrmFields.normaliseValue(.button, FieldConfig(), .null, ctx: context).crmError == "Press the button to run it")
    }
    @Test func signatureIgnoresForgedAuthorAndTime() {
        let input: CrmValue = .object(["mode": .string("typed"), "text": .string(" Asad "), "by": .string("forged"), "at": .string("forged")])
        let value = BackendCrmFields.normaliseValue(.signature, FieldConfig(), input, ctx: context).crmValue
        #expect(value?["by"] == .string("actual-caller"))
        #expect(value?["at"] == .string(context.now))
        #expect(value?["text"] == .string("Asad"))
        let data = "data:image/png;base64," + String(repeating: "A", count: 200_000)
        #expect(BackendCrmFields.normaliseValue(.signature, FieldConfig(), .object(["mode": .string("drawn"), "dataUrl": .string(data)]), ctx: context).crmError == "The drawn signature is too large")
    }
    @Test func formulaAcceptsOnlyItsMathGrammar() {
        #expect(evaluate("2 × 3 ÷ 4 + abs(-2)").crmValue == 3.5)
        #expect(evaluate("round(1.235,2)").crmValue == 1.24)
        #expect(evaluate("7 % 4").crmValue == 3)
        #expect(evaluate("round(-1.5)").crmValue == -1)
        #expect(evaluate("eval(1)").crmError == "Unknown word “eval” — put field names in {braces}")
        #expect(evaluate("{x}.constructor").crmError == "Unexpected “.”")
        #expect(evaluate("1;2").crmError == "Unexpected “;”")
    }
    @Test func formulaDepthTokenLengthAndFunctionArityAreBounded() {
        #expect(evaluate(String(repeating: "(", count: 65) + "1" + String(repeating: ")", count: 65)).crmError == "Formula is nested too deeply")
        #expect(evaluate(String(repeating: "-", count: 65) + "1").crmError == "Formula is nested too deeply")
        #expect(evaluate(Array(repeating: "1", count: 151).joined(separator: "+")).crmError == "Formula is too long")
        #expect(evaluate(String(repeating: " ", count: 500) + "1").crmError == "Formula is too long")
        #expect(evaluate("min(" + Array(repeating: "1", count: 21).joined(separator: ",") + ")").crmError == "min takes 1 to 20 values")
        #expect(evaluate("abs()").crmError == "abs takes 1 value")
    }
    @Test func formulaRefusesZeroDivisionAndFormulaReferences() {
        #expect(evaluate("1 / 0").crmError == "Division by zero")
        #expect(evaluate("1 % 0").crmError == "Division by zero")
        #expect(evaluate("round(1,11)").crmError == "round() keeps 0 to 10 decimals")
        let nested = TaskField(id: "f", taskId: "t", label: "Total", kind: .formula, config: FieldConfig())
        #expect(BackendCrmFields.computeFormula("{Total}", fields: [nested]).crmError == "A formula cannot use another formula (“Total”)")
    }
    @Test func storedRowUsesDBKeysAndDropsUnknownKinds() {
        let row: CrmValue = .object(["id": .string("f"), "task_id": .string("t"), "label": .string("Link"), "kind": .string("relationship"),
            "config": .object(["areas": .array([.string("deal")])]), "sort_order": .number(1), "created_at": .string("2026-10-06")])
        let decoded = BackendCrmFields.rowToField(row)
        #expect(decoded?.taskId == "t" && decoded?.config.areas == ["deal"] && decoded?.value == .null)
        #expect(BackendCrmFields.rowToField(.object(["kind": .string("hologram")])) == nil)
    }
    @Test func optionsReconcileAndButtonTargetValidationUsesActualFieldRules() {
        var targetConfig = FieldConfig(); targetConfig.max = 3
        let target = TaskField(id: "r", taskId: "t", label: "Stars", kind: .rating, config: targetConfig)
        let button: CrmValue = .object(["action": .object(["type": .string("field"), "fieldId": .string("r"), "value": .number(4)])])
        #expect(BackendCrmFields.normaliseConfig(.button, button, siblings: [target]).crmError == "Button value for “Stars”: A rating is 1 to 3")
        #expect(BackendCrmFields.reconcileValue(.rating, targetConfig, .number(8)) == .number(3))
    }
    @Test func fieldSortKeepsUnpositionedRowsLastAndFeedTextIsBounded() {
        let rows = [TaskField(id: "late", taskId: "t", label: "Late", kind: .text, config: FieldConfig(), createdAt: "2026-10-06"),
            TaskField(id: "first", taskId: "t", label: "First", kind: .text, config: FieldConfig(), sortOrder: 0, createdAt: "2026-10-07"),
            TaskField(id: "old", taskId: "t", label: "Old", kind: .text, config: FieldConfig(), createdAt: "2026-10-01")]
        #expect(BackendCrmFields.sortFields(rows).map(\.id) == ["first", "old", "late"])
        #expect(BackendCrmFields.feedValue(String(repeating: "x", count: 121))?.utf16.count == 118)
        #expect(BackendCrmFields.fieldActivitySentence("You", payload: ["label": .string("Price"), "to": .null]) == "You cleared Price")
    }
}
