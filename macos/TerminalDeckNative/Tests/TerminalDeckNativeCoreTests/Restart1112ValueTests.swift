import Testing
import TerminalDeckNativeCore

@Suite("Restart 1112: snapshot field lookup")
struct Restart1112ValueTests {
    @Test func duplicateFieldsStillUseTheLastValueIncludingMissing() {
        let nested = NativeRPCValue.array([.object([.init("nested", .string("kept"))])])
        let value = NativeRPCValue.object([.init("key", nested), .init("other", .bool(true)), .init("key", .missing)])
        #expect(value["key"] == .missing)
        #expect(value["other"] == .bool(true))
        #expect(value["absent"] == .missing)
        #expect(nested["key"] == .missing)
    }
    @Test func wideNestedSnapshotsKeepTheirFullValueAndOrder() {
        let value = NativeRPCValue.object((0..<1_000).map { .init("field-\($0)", .array([.number(Double($0))])) })
        #expect(value["field-0"] == .array([.number(0)]))
        #expect(value["field-999"] == .array([.number(999)]))
        #expect(value.fields?.count == 1_000)
        #expect(value.fields?.first?.key == "field-0")
    }
}
