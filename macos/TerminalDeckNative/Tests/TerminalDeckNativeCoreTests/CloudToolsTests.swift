import Foundation
import XCTest
@testable import TerminalDeckNativeCore

private actor CloudToolsFixture {
  var observation: CloudToolsObservation
  var calls = 0
  var willBecomeAvailable = false
  var allowed = true
  init(device: String = "new", installed: Bool = false) {
    observation = .init(deviceId: device, toolId: "codex", name: "Codex", version: installed ? "1.2.0" : nil, platform: .macos, architecture: "arm64", installed: installed, available: installed, checkedAt: 1000)
  }
  func read() -> CloudToolsObservation { observation }
  func permit() throws { if !allowed { throw CloudFailure.gateClosed } }
  func configure(available: Bool, allowed: Bool = true) { willBecomeAvailable = available; self.allowed = allowed }
  func install() -> CloudToolsInstallerDisposition {
    calls += 1
    if willBecomeAvailable { observation = .init(deviceId: "new", toolId: "codex", name: "Codex", version: "1.2.0", platform: .macos, architecture: "arm64", installed: true, available: true, checkedAt: 1000) }
    return .completed
  }
}
final class CloudToolsTests: XCTestCase, @unchecked Sendable {
  private let requirement = CloudToolsRequirement(toolId: "codex", versionRange: "^1.0.0", neededFor: ["root"], reason: "Continue coding work.")
  private func catalog(_ fixture: CloudToolsFixture, installer: Bool = true) -> CloudToolsCatalog {
    CloudToolsCatalog(deviceId: "new", observe: { _, _ in await fixture.read() }, installers: installer ? ["codex": .init(id: "fixture-only", supportsVersion: { CloudToolsCatalog.matches("1.2.0", $0) }, perform: { _ in await fixture.install() })] : [:], authorizeInstall: { _, _ in try await fixture.permit() }, now: { 1000 })
  }
  func testAnotherMachinesInstalledToolsAreNotClaimedHere() async throws {
    let fixture = CloudToolsFixture(device: "old", installed: true)
    let rows = try await catalog(fixture).needs([requirement])
    XCTAssertEqual(rows.first?.state, .unobserved)
    XCTAssertNil(rows.first?.observation)
    XCTAssertEqual(rows.first?.canInstall, false)
  }
  func testInstallIsRealAuthorizedAndCheckedAfterward() async throws {
    let fixture = CloudToolsFixture()
    let tools = catalog(fixture)
    let before = try await tools.needs([requirement])
    XCTAssertEqual(before.first?.state, .missing)
    XCTAssertEqual(before.first?.canInstall, true)
    let context = NativeRPCContext(caller: .nativeApp, ownerID: "fixture")
    let notVerified = try await tools.install(toolId: "codex", requirements: [requirement], context: context)
    XCTAssertEqual(notVerified.state, .blocked)
    await fixture.configure(available: true)
    let verified = try await tools.install(toolId: "codex", requirements: [requirement], context: context)
    XCTAssertEqual(verified.state, .verified)
    XCTAssertEqual(verified.needs.first?.observation?.deviceId, "new")
    let calls = await fixture.calls
    XCTAssertEqual(calls, 2)
  }
  func testNoInstallerMeansNoInstallActionAndNoMutation() async throws {
    let fixture = CloudToolsFixture(), tools = catalog(fixture, installer: false)
    let rows = try await tools.needs([requirement])
    XCTAssertEqual(rows.first?.canInstall, false)
    do { _ = try await tools.install(toolId: "codex", requirements: [requirement], context: .init(caller: .nativeApp, ownerID: "fixture")); XCTFail("Unsupported install action was called") }
    catch { XCTAssertEqual(error as? CloudFailure, .unsupportedFormat) }
    let calls = await fixture.calls
    XCTAssertEqual(calls, 0)
  }
  func testRefusedPermissionNeverCallsInstaller() async throws {
    let fixture = CloudToolsFixture()
    await fixture.configure(available: true, allowed: false)
    do { _ = try await catalog(fixture).install(toolId: "codex", requirements: [requirement], context: .init(caller: .internalEngine, ownerID: "fixture")); XCTFail("Refused install ran") }
    catch { XCTAssertEqual(error as? CloudFailure, .gateClosed) }
    let calls = await fixture.calls
    XCTAssertEqual(calls, 0)
  }
  func testVersionRequirementsAreActuallyCompared() {
    XCTAssertTrue(CloudToolsCatalog.matches("1.4.0", "^1.2.0"))
    XCTAssertFalse(CloudToolsCatalog.matches("2.0.0", "^1.2.0"))
    XCTAssertFalse(CloudToolsCatalog.matches("0.3.0", "^0.2.0"))
    XCTAssertTrue(CloudToolsCatalog.matches("22.1.0", ">=20.0.0"))
    XCTAssertFalse(CloudToolsCatalog.matches("1.2.0-beta", "1.2.0"))
    XCTAssertFalse(CloudToolsCatalog.matches("1.2.0-beta", "^1.0.0"))
    XCTAssertFalse(CloudToolsCatalog.matches("1.2.0-dev", "1.2.0-de"))
  }
}
