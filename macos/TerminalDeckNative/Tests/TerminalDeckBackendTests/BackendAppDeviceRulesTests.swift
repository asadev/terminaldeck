import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Device protocol and untrusted wire adapters")
struct BackendAppDeviceRulesTests {
    private func parse(_ raw: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(raw.utf8)) }
    @Test func frameDecoderSurvivesEveryByteBoundaryAndKeepsPayloadCopies() throws {
        let wire = try BackendAppDeviceFrames.encode(kind: 0x12, payload: Data(repeating: 7, count: 300))
        var reader = BackendAppDeviceFrameReader(), found: [BackendAppDeviceFrame] = []
        for byte in wire { found += try reader.push(Data([byte])) }
        #expect(found.count == 1)
        #expect(found.first?.payload == Data(repeating: 7, count: 300))
        _ = try reader.push(BackendAppDeviceFrames.encode(kind: 0x12, payload: Data("second".utf8)))
        #expect(found.first?.payload == Data(repeating: 7, count: 300))
    }
    @Test func decoderReturnsEveryCoalescedFrameAndRefusesOversizedHeader() throws {
        var wire = try BackendAppDeviceFrames.encode(kind: 2, payload: Data("a".utf8))
        wire.append(try BackendAppDeviceFrames.encode(kind: 0x12, payload: Data("bb".utf8)))
        wire.append(try BackendAppDeviceFrames.encode(kind: 0x20, payload: Data("ccc".utf8)))
        var reader = BackendAppDeviceFrameReader()
        #expect(try reader.push(wire).map(\.kind) == [2, 0x12, 0x20])
        #expect(throws: BackendAppSessionError.self) { try reader.push(Data([0x12, 4, 0, 0, 1])) }
    }
    @Test func unknownEnginePlatformHasNoFalseSuccess() {
        let answer = BackendAppDeviceEngineLocator.locate(resourcesPath: nil, appPath: "/fixture", cwd: "/fixture", environment: [:], platform: "linux")
        #expect(answer == .unavailable("Simulators open on a Mac. This computer is not one."))
        let intel = BackendAppDeviceEngineLocator.locate(resourcesPath: nil, appPath: "/fixture", cwd: "/fixture", environment: [:], arch: "x64")
        #expect(intel == .unavailable("Simulators need a Mac with Apple silicon."))
    }
    @Test func packagedEngineCandidatesComeBeforeDevelopment() {
        let candidates = BackendAppDeviceEngineLocator.candidates(resourcesPath: "/app/Resources", appPath: "/app/Resources/app.asar", cwd: "/fixture")
        #expect(candidates.first == "/app/Resources/app.asar.unpacked/node_modules/@toolingtools/simview/bin")
        #expect(candidates.last == "/fixture/node_modules/@toolingtools/simview/bin")
        #expect(Set(candidates).count == candidates.count)
    }
    @Test func nodeRedactionAndSourceLocationDoNotCarryUnneededEngineFields() throws {
        let node = BackendAppDeviceParsing.readNode(try parse(#"{"ref":"ax:1","role":"AXSecureTextField","value":"secret","valueRedacted":true,"actions":["AXPress"],"sourceLocation":{"file":"src/Pay.tsx","line":12},"frame":{"normalized":{"x":0.1,"y":0.2,"width":0.3,"height":0.4},"points":{"x":10}}}"#))
        #expect(node?["valueRedacted"].bool == true)
        #expect(node?.has("value") == false)
        #expect(node?.has("actions") == false)
        #expect(node?["sourceLocation"]["line"].number == 12)
        #expect(node?["frame"].has("points") == false)
    }
    @Test func roundClampsCutsRenumbersAndDropsMarkerNotes() throws {
        let round = BackendAppDeviceParsing.round(try parse(#"{"where":{"kind":"device","place":"iOS Simulator","name":"Phone","evil":"drop"},"frame":{"width":1206.4,"height":-3},"note":"Make 1 bold","annotations":[{"id":"a","n":9,"rect":{"x":-1,"y":2,"width":0.5,"height":0.5},"note":"drop","element":{"role":"button","script":"drop"}},{"id":"b","element":"bad"}]}"#), now: 5)
        #expect(round["id"].string == "round-5")
        #expect(round["frame"]["width"].number == 1206)
        #expect(round["frame"]["height"].number == 0)
        #expect(round["where"].has("evil") == false)
        let entries = try #require(round["annotations"].elements)
        #expect(entries.map { $0["n"].number } == [1, 2])
        #expect(entries[0]["rect"]["x"].number == 0)
        #expect(entries[0]["rect"]["y"].number == 1)
        #expect(entries[0].has("note") == false)
        #expect(entries[0]["element"].has("script") == false)
        #expect(entries[1]["element"] == .null)
    }
    @Test func deviceInputBoundaryRejectsCommandTextAndClampsCoordinates() throws {
        #expect(throws: BackendAppSessionError.self) { try BackendAppDeviceChannels.deviceID(.string("ios:abc;rm")) }
        #expect(throws: BackendAppSessionError.self) { try BackendAppDeviceChannels.deviceID(.string("ios:abc\n")) }
        #expect(throws: BackendAppSessionError.self) { try BackendAppDeviceChannels.unit(.string("0.5")) }
        #expect(try BackendAppDeviceChannels.unit(.number(-1)) == 0)
        #expect(try BackendAppDeviceChannels.unit(.number(2)) == 1)
        #expect(try BackendAppDeviceChannels.deviceID(.string("android:emulator-5554")) == "android:emulator-5554")
    }
    @Test func inventoryReadsSimulatorPlistAndRejectsDeletedBinaryOrInvalidID() {
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let xml = "<plist><dict><key>UDID</key><string>\(uuid)</string><key>name</key><string>Tom &amp; Jerry</string><key>runtime</key><string>com.apple.CoreSimulator.SimRuntime.iOS-27-0</string><key>state</key><integer>3</integer></dict></plist>"
        let sim = BackendAppDeviceInventoryParsing.plist(xml)
        #expect(sim?.name == "Tom & Jerry")
        #expect(sim?.state == "ready")
        #expect(BackendAppDeviceInventoryParsing.plainRuntime(sim?.runtime ?? "") == "iOS 27.0")
        #expect(BackendAppDeviceInventoryParsing.plist(xml.replacingOccurrences(of: "</dict>", with: "<key>isDeleted</key><true/></dict>")) == nil)
        #expect(BackendAppDeviceInventoryParsing.plist("bplist00") == nil)
        #expect(BackendAppDeviceInventoryParsing.plist(xml.replacingOccurrences(of: uuid, with: "wrong")) == nil)
    }
    @Test func physicalPhoneIsNeverOfferedPowerControls() throws {
        let row = BackendAppDeviceInventoryParsing.engineDevice(try parse(#"{"id":"android:serial","platform":"android","kind":"physical","state":"unauthorized"}"#))
        #expect(row?["canBoot"].bool == false)
        #expect(row?["canShutDown"].bool == false)
        #expect(row?["note"].string?.contains("allow this computer") == true)
    }
    @Test func filenamesStayInsidePicturesAndUseTheDeviceName() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 1, minute: 2, second: 3))!
        #expect(BackendAppDeviceManager.pictureName("../../etc/passwd", now: now, calendar: calendar) == "etc-passwd-20261003-010203")
        #expect(BackendAppDeviceManager.place(platform: "android", kind: "physical") == "Android phone")
    }
}
