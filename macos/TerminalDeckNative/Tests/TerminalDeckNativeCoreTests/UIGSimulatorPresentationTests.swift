import Testing
@testable import TerminalDeckNativeCore

struct UIGSimulatorPresentationTests {
    @Test func selectingAnOffSimulatorNeverStartsIt() {
        let off = DeviceEntry(id: "ios:off", state: "shutdown", available: false, name: "iPhone", runtime: "iOS 27.0", canBoot: true)
        #expect(!UIGSimulatorPresentation.opensOnSelection(off))
        #expect(UIGSimulatorPresentation.action(off) == .start)
        #expect(UIGSimulatorPresentation.canPerformAction(off))
        #expect(UIGSimulatorPresentation.description(off) == "iOS 27.0 Simulator")
    }

    @Test func physicalPhonesRequireViewScreenEvenWhenTheyReportCanBoot() {
        let phone = DeviceEntry(id: "ios:phone", kind: "physical", name: "Asad's iPhone", runtime: "iOS 27.0", canBoot: true)
        #expect(UIGSimulatorPresentation.action(phone) == .viewScreen)
        #expect(!UIGSimulatorPresentation.opensOnSelection(phone))
        #expect(UIGSimulatorPresentation.kind(phone) == "iPhone")
        #expect(UIGSimulatorPresentation.description(phone) == "iOS 27.0")
        #expect(UIGSimulatorPresentation.version(phone) == "27.0")
    }

    @Test func unauthorizedPhonesKeepViewScreenDisabled() {
        let phone = DeviceEntry(id: "android:phone", platform: "android", kind: "physical", state: "unauthorized", available: false, name: "Phone", canBoot: true)
        #expect(UIGSimulatorPresentation.action(phone) == .viewScreen)
        #expect(!UIGSimulatorPresentation.canPerformAction(phone))
        #expect(!UIGSimulatorPresentation.opensOnSelection(phone))
    }

    @Test func onlyAnExplicitSelectionSurvivesAListRefresh() {
        let running = DeviceEntry(id: "ios:running", name: "Running")
        let off = DeviceEntry(id: "ios:off", state: "shutdown", available: false, name: "Off", canBoot: true)
        #expect(UIGSimulatorPresentation.selectedID(in: [running, off], selected: nil, open: running.id, remembered: off.id) == nil)
        #expect(UIGSimulatorPresentation.selectedID(in: [running, off], selected: off.id, open: running.id, remembered: nil) == off.id)
    }

    @Test func removingASelectedDeviceClearsSelectionWithoutOpeningAnother() {
        let off = DeviceEntry(id: "ios:off", state: "shutdown", available: false, name: "Off", canBoot: true)
        let running = DeviceEntry(id: "ios:running", name: "Running")
        #expect(UIGSimulatorPresentation.selectedID(in: [off, running], selected: "removed", open: nil, remembered: "removed") == nil)
        #expect(UIGSimulatorPresentation.selectedID(in: [], selected: "removed", open: nil, remembered: nil) == nil)
    }

    @Test func anIncompleteInventoryReadRetainsOnlyTheActualOpenDevice() {
        let live = DeviceDetails(id: "ios:live", name: "Live")
        let list = DeviceList(available: true, devices: [])
        let rows = UIGSimulatorPresentation.entries(list, open: live)
        #expect(rows.count == 1)
        #expect(rows.first?.id == live.id)
        #expect(UIGSimulatorPresentation.entries(nil, open: nil).isEmpty)
        #expect(UIGSimulatorPresentation.entries(DeviceList(available: true, devices: rows), open: live).count == 1)
    }

    @Test func newerSelectionRejectsAnOlderOpenOrStartReply() {
        var fence = UIGSimulatorRequestFence()
        let older = fence.begin("ios:old")
        let newer = fence.begin("ios:new")
        #expect(!fence.accepts(older))
        #expect(fence.accepts(newer))
        fence.invalidate()
        #expect(!fence.accepts(newer))
        #expect(fence.currentTicket == nil)
        let resumed = fence.begin("ios:new")
        #expect(fence.currentTicket == resumed)
        #expect(fence.accepts(resumed))
        #expect(!fence.accepts(newer))
    }

    @Test func retryingTheSameDeviceCannotAcceptItsFirstReply() {
        var fence = UIGSimulatorRequestFence()
        let first = fence.begin("ios:same")
        let retry = fence.begin("ios:same")
        #expect(!fence.accepts(first))
        #expect(fence.accepts(retry))
    }
}
