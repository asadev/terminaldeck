import CoreGraphics
import Foundation
import Testing
@testable import TerminalDeckNativeCore

// PFRAME (9 Oct 2026): the session phone panel's frame, side buttons, snip/crop maths and
// clipboard decisions. The views are checked offscreen (round7/pframe-check); this is the logic.

private func device(_ name: String, _ platform: String = "ios", buttons: [String] = ["home", "lock", "volume-up", "volume-down", "action"]) -> DeviceDetails {
    DeviceDetails(id: platform == "ios" ? "ios:6F4E1C2A-1111-4222-8333-944455556666" : "android:emulator-5554",
                  name: name, platform: platform, kind: platform == "ios" ? "simulator" : "emulator",
                  pointWidth: 402, pointHeight: 874, buttons: buttons)
}

@Suite("PFRAME phone frame")
struct PFrameFrameTests {
    @Test func faceIDiPhoneHasActionAndVolumeLeftSideButtonRight() throws {
        let spec = try #require(NativePhoneFrame.spec(for: device("iPhone 18 Pro"), content: CGSize(width: 1206, height: 2622)))
        #expect(spec.buttons.filter { $0.edge == .left }.compactMap(\.kind) == ["action", "volume-up", "volume-down"])
        #expect(spec.buttons.filter { $0.edge == .right }.compactMap(\.kind) == ["lock"])
        #expect(!spec.homeButton && !spec.punchHole)
    }

    @Test func androidHasPowerAndVolumeOnTheRightAndAPunchHole() throws {
        let spec = try #require(NativePhoneFrame.spec(for: device("Pixel 9", "android"), content: CGSize(width: 1080, height: 2400)))
        #expect(spec.buttons.allSatisfy { $0.edge == .right })
        #expect(spec.buttons.compactMap(\.kind) == ["lock", "volume-up", "volume-down"])
        #expect(spec.punchHole)
    }

    @Test func homeButtonPhoneIPadAndNoFrameForWatchOrUnknownSize() {
        #expect(NativePhoneFrame.spec(for: device("iPhone SE (3rd generation)"), content: CGSize(width: 750, height: 1334))?.homeButton == true)
        #expect(NativePhoneFrame.spec(for: device("iPad Air 11-inch (M4)"), content: CGSize(width: 1640, height: 2360))?.buttons.first?.edge == .top)
        #expect(NativePhoneFrame.spec(for: device("Apple Watch Series 11"), content: CGSize(width: 416, height: 496)) == nil)
        #expect(NativePhoneFrame.spec(for: device("iPhone 18 Pro"), content: .zero) == nil)
        #expect(NativePhoneFrame.spec(for: nil, content: CGSize(width: 1, height: 2)) == nil)
    }

    /// Every side button presses something the device engine accepts (BackendDeckToolsMachinesDeviceRules.buttons),
    /// through the one input path: devices:button with the device id.
    @Test func everySideButtonIsAnEngineButtonOnTheSameChannel() {
        let engine: Set<String> = ["home", "back", "overview", "lock", "volume-up", "volume-down", "action"]
        for (name, platform, size) in [("iPhone 18 Pro", "ios", CGSize(width: 1206, height: 2622)), ("iPhone SE", "ios", CGSize(width: 750, height: 1334)),
                                       ("iPad Pro 11-inch (M5)", "ios", CGSize(width: 1668, height: 2420)), ("Pixel 9", "android", CGSize(width: 1080, height: 2400))] {
            let details = device(name, platform)
            let spec = NativePhoneFrame.spec(for: details, content: size)!
            for kind in spec.buttons.compactMap(\.kind) {
                #expect(engine.contains(kind), "\(name): \(kind)")
                let call = DeviceInput.button(kind).call(device: details.id)
                #expect(call.channel == "devices:button")
                #expect(call.args.first as? String == details.id && call.args.last as? String == kind)
            }
        }
    }

    /// The screen sits exactly in the frame's hole with the picture's own shape, so input measured
    /// against the screen view is the same as without a frame.
    @Test func screenHoleKeepsThePicturesShapeAndSitsInsideTheBody() throws {
        let content = CGSize(width: 1206, height: 2622)
        let spec = try #require(NativePhoneFrame.spec(for: device("iPhone 18 Pro"), content: content))
        for bounds in [CGSize(width: 396, height: 700), CGSize(width: 800, height: 600), CGSize(width: 280, height: 900)] {
            let layout = try #require(spec.layout(content: content, in: bounds))
            #expect(abs(layout.screen.width / layout.screen.height - content.width / content.height) < 0.01)
            #expect(layout.body.contains(layout.screen))
            #expect(CGRect(origin: .zero, size: bounds).insetBy(dx: -0.5, dy: -0.5).contains(layout.body))
            let fitted = DeviceGeometry.fitted(content: content, in: layout.screen.size)
            #expect(abs(fitted.width - layout.screen.width) <= 1 && abs(fitted.height - layout.screen.height) <= 1)
        }
    }

    @Test func landscapeTurnsTheDrawing() throws {
        let spec = try #require(NativePhoneFrame.spec(for: device("iPhone 18 Pro"), content: CGSize(width: 2622, height: 1206)))
        let layout = try #require(spec.layout(content: CGSize(width: 2622, height: 1206), in: CGSize(width: 900, height: 500)))
        #expect(layout.landscape && layout.screen.width > layout.screen.height)
    }
}

@Suite("PFRAME snip and crop maths")
struct PFrameCropTests {
    let picture = CGRect(x: 10, y: 20, width: 300, height: 600)

    @Test func snipIsTheDraggedBoxAsFractionsOfThePicture() throws {
        let box = try #require(ShotCropMath.snip(from: CGPoint(x: 40, y: 80), to: CGPoint(x: 190, y: 320), picture: picture))
        #expect(abs(box.minX - 0.1) < 1e-9 && abs(box.minY - 0.1) < 1e-9)
        #expect(abs(box.width - 0.5) < 1e-9 && abs(box.height - 0.4) < 1e-9)
    }

    @Test func snipDraggedBackwardsOrOffThePictureIsKeptOnIt() throws {
        let box = try #require(ShotCropMath.snip(from: CGPoint(x: 500, y: 900), to: CGPoint(x: 160, y: 320), picture: picture))
        #expect(box.maxX <= 1 && box.maxY <= 1 && box.minX >= 0 && box.minY >= 0)
        #expect(abs(box.minX - 0.5) < 1e-9 && abs(box.minY - 0.5) < 1e-9)
    }

    @Test func aClickOrATinyBoxIsNoSnip() {
        #expect(ShotCropMath.snip(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 52, y: 51), picture: picture) == nil)
        #expect(ShotCropMath.snip(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 54), picture: picture) == nil)
        #expect(ShotCropMath.snip(from: .zero, to: CGPoint(x: 100, y: 100), picture: .zero) == nil)
    }

    @Test func cropPixelsAreWholeInsideAndAtLeastOne() {
        #expect(ShotCropMath.pixels(CGRect(x: 0, y: 0, width: 1, height: 0.5), width: 1206, height: 2622) == CGRect(x: 0, y: 0, width: 1206, height: 1311))
        let tiny = ShotCropMath.pixels(CGRect(x: 0.9999, y: 0.9999, width: 0, height: 0), width: 100, height: 100)
        #expect(tiny.width >= 1 && tiny.height >= 1 && tiny.maxX <= 100 && tiny.maxY <= 100)
        #expect(ShotCropMath.sizeLabel(ShotCropMath.full, width: 1206, height: 2622) == "1,206 × 2,622")
        #expect(ShotCropMath.isFull(ShotCropMath.full) && !ShotCropMath.isFull(CGRect(x: 0, y: 0, width: 1, height: 0.9)))
    }
}

@Suite("PFRAME clipboard decisions")
struct PFrameClipboardTests {
    @Test func onlyIOSSimulatorsHaveAPasteboardThisWay() {
        #expect(SimPasteboardSync.simulatorUDID("ios:6F4E1C2A-1111-4222-8333-944455556666") == "6F4E1C2A-1111-4222-8333-944455556666")
        #expect(SimPasteboardSync.simulatorUDID("android:emulator-5554") == nil)
        #expect(SimPasteboardSync.simulatorUDID("ios:not-a-uuid") == nil)
        #expect(SimPasteboardSync.simulatorUDID(nil) == nil)
    }

    @Test func macToPhoneOnlyWhenTheMacClipboardChanged() {
        var sync = SimPasteboardSync()
        #expect(sync.toPhone(macChangeCount: 4, macText: "hello") == "hello")   // focus: new text goes
        #expect(sync.toPhone(macChangeCount: 4, macText: "hello") == nil)       // focus again, nothing changed
        #expect(sync.toPhone(macChangeCount: 4, macText: "hello", force: true) == "hello") // ⌘V always carries it
        #expect(sync.toPhone(macChangeCount: 5, macText: nil) == nil)           // an image or nothing: no text
        #expect(sync.toPhone(macChangeCount: 6, macText: "next") == "next")
    }

    @Test func phoneToMacOnlyNewTextAndNeverBackAndForth() {
        var sync = SimPasteboardSync()
        #expect(sync.toPhone(macChangeCount: 1, macText: "from mac") == "from mac")
        #expect(sync.toMac(phoneText: "from mac", macText: "from mac") == nil)  // what we just put there: not echoed
        #expect(sync.toMac(phoneText: "copied in phone", macText: "from mac") == "copied in phone")
        sync.macWritten(changeCount: 2)
        #expect(sync.toPhone(macChangeCount: 2, macText: "copied in phone") == nil) // our own write: not sent back
        #expect(sync.toMac(phoneText: "copied in phone", macText: "copied in phone") == nil)
        #expect(sync.toMac(phoneText: "", macText: "x") == nil)
    }
}
