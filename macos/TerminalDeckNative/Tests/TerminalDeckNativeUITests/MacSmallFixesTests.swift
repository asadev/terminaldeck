import AppKit
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// The Mac batch's small leftovers (15 Nov, lane/mac-small-fixes): plain checks of the words each item changes.
@MainActor
final class MacSmallFixesTests: XCTestCase {
    // Item 1: the old words "Outside AI apps" are gone from what agents read too.
    func testNoCatalogueTextSaysOutsideAIApps() {
        let rows = BackendDeckCoreCatalogueCoverageLiterals.sourceRows
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            for text in [row.audience, row.skip].compactMap({ $0 }) {
                XCTAssertFalse(text.lowercased().contains("outside ai apps"), "\(row.area) \(row.action): \(text)")
            }
        }
        XCTAssertTrue(rows.contains { $0.audience?.hasPrefix("Hoot only. AI apps, sessions and phones cannot call this tool") == true })
    }

    // Item 2: no raw model id on the Coding AIs page, for any AI.
    func testCodingAIsDefaultModelIsAName() {
        XCTAssertEqual(NativeLandingModels.name("gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(NativeLandingModels.name("gpt-5.5-codex"), "GPT-5.5 Codex")
        XCTAssertEqual(NativeLandingModels.name("gemini-2.5-pro"), "Gemini 2.5 Pro")
        XCTAssertEqual(NativeLandingModels.name("claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(NativeLandingModels.name("o3"), "O3")
        for raw in ["gpt-5.5", "codex:gpt-5.5", "gemini-2.5-flash", "claude-opus-5-5", "opus[1m]"] {
            let shown = NativeCodingAIThisMachine.defaultModelWords(chosen: raw, cliDefault: nil)
            XCTAssertNotEqual(shown, raw.split(separator: ":").last.map(String.init), "raw id shown for \(raw)")
            XCTAssertFalse(shown.first?.isLowercase == true, "\(raw) → \(shown)")
        }
    }

    // Item 3: the Devices row line appears only with both fields.
    func testDevicesRowSaysWhoSignedItOutOnlyWithBothFields() throws {
        let at: Int64 = 1_794_000_000_000
        var device = DevicesPage.AccountDevice(name: "MacBook Air", kind: .mac, isThisMac: false, addedAtMs: nil, lastSeenAtMs: at, deviceId: "d1")
        let plain = NativeDevicesSettings.row(device)
        XCTAssertFalse(NativeDevicesSettings.secondLine(plain).hasPrefix("Signed out"))
        XCTAssertNil(NativeDevicesSettings.signedOutLine(plain))
        device.signedOutBy = "Mac mini"; device.signedOutAtMs = at
        let line = NativeDevicesSettings.secondLine(NativeDevicesSettings.row(device))
        XCTAssertEqual(line, "Signed out from Mac mini on " + NativeCloudTrustWords.day(at))
        device.signedOutAtMs = nil
        XCTAssertNil(NativeDevicesSettings.signedOutLine(NativeDevicesSettings.row(device)), "one field alone: as today")

        // The Cloud's device list: the two fields are read when present and absent as before.
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")
        let made = CloudDevice(deviceId: "d1", label: "MacBook Air", platform: .macos, appVersion: "fixture", status: .active,
                               secretsApproved: false, lastSeenAt: at, signPublicJwk: key, wrapPublicJwk: key)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(made)) as? [String: Any])
        XCTAssertNil(try JSONDecoder().decode(CloudDevice.self, from: JSONSerialization.data(withJSONObject: object)).removedByName)
        object["removedByName"] = "Mac mini"; object["removedAt"] = at
        let read = try JSONDecoder().decode(CloudDevice.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(read.removedByName, "Mac mini"); XCTAssertEqual(read.removedAt, at)
    }

    // Item 4: the saved-passwords sheet's words for a Mac that was signed out from another device.
    func testAllowSheetAsksIsThisYoursForASignedOutMac() {
        let plain = CloudSecretsApprovalDisplay(deviceName: "MacBook Air", platform: .macos, matchingCode: "")
        let today = NativeCloudRecoveryInteraction.allowDeviceAlert(plain)
        XCTAssertEqual(today.messageText, "Allow this device?")
        XCTAssertEqual(today.buttons.map(\.title), ["Don’t allow", "Allow this device"])
        XCTAssertEqual(today.informativeText, NativeCloudRecoveryInteraction.allowSignedText("MacBook Air"))

        var flagged = plain
        flagged.signedOutBefore = true; flagged.signedOutBy = "Mac mini"; flagged.signedOutAt = 1_794_000_000_000
        let alert = NativeCloudRecoveryInteraction.allowDeviceAlert(flagged)
        XCTAssertEqual(alert.messageText, "Is this your MacBook Air?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Don’t allow", "Yes, it’s mine"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Return still refuses")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        let line = "It was signed out from Mac mini on " + NativeCloudTrustWords.day(1_794_000_000_000) + "."
        XCTAssertEqual(alert.informativeText, line + "\n\n" + NativeCloudRecoveryInteraction.allowSignedText("MacBook Air"))
        flagged.signedOutBy = nil; flagged.signedOutAt = nil
        XCTAssertEqual(NativeCloudRecoveryInteraction.signedOutLine(flagged), "It was signed out from another of your devices.")
    }
}
