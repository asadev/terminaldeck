import XCTest
@testable import TerminalDeckBackend

final class BackendOSPowerRulesTests: XCTestCase {
    func testMissingSleepKeyRemainsUnknownAndRecognisesOnlyReportedLine() {
        XCTAssertNil(BackendOSPowerRules.sleepDisabled("sleep 0 (sleep prevented by App)"))
        XCTAssertEqual(BackendOSPowerRules.sleepDisabled("System-wide power settings:\n SleepDisabled 1\n"), true)
        XCTAssertEqual(BackendOSPowerRules.sleepDisabled("SleepDisabled 0"), false)
        XCTAssertEqual(BackendOSPowerRules.registrySleepDisabled("\"SleepDisabled\" = Yes"), true)
        XCTAssertNil(BackendOSPowerRules.registrySleepDisabled("\"OtherSleepSetting\" = Yes"))
    }
    func testDesktopAndDischargingBatteryAreDifferentFacts() {
        XCTAssertEqual(BackendOSPowerRules.battery("Now drawing from 'AC Power'"), .init(present: false, discharging: false, percent: nil))
        XCTAssertEqual(BackendOSPowerRules.battery("Now drawing from 'Battery Power'\n -InternalBattery-0 19%; discharging; present: true"), .init(present: true, discharging: true, percent: 19))
        XCTAssertNil(BackendOSPowerRules.warning(.init(present: true, discharging: false, percent: 10), hasLid: true))
        XCTAssertTrue(BackendOSPowerRules.warning(.init(present: true, discharging: true, percent: 20), hasLid: true)?.contains("Plug it in") == true)
        XCTAssertTrue(BackendOSPowerRules.warning(.init(present: true, discharging: true, percent: nil), hasLid: false)?.contains("awake") == true)
    }
    func testOnlyExactPrivilegedPmsetCommandAndCancellation() {
        XCTAssertEqual(BackendOSPowerRules.changeScript(on: true), "do shell script \"/usr/bin/pmset -a disablesleep 1\" with administrator privileges")
        XCTAssertEqual(BackendOSPowerRules.changeScript(on: false), "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges")
        XCTAssertEqual(BackendOSPowerRules.appleScriptLiteral("a\"\\b"), "\"a\\\"\\\\b\"")
        XCTAssertTrue(BackendOSPowerRules.cancelled("execution error: User canceled. (-128)"))
        XCTAssertFalse(BackendOSPowerRules.cancelled("permission denied (-1743)"))
    }
}
