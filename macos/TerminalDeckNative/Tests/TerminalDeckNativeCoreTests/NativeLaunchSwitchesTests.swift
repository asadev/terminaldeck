import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// #302: every launch switch the app reads is named once, in NativeLaunchSwitches.
/// #301: the old two-engine switches are gone for good.
@Suite("Launch switches")
struct NativeLaunchSwitchesTests {
    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func everySwitchIsReadThroughTheOneList() throws {
        let files = try sources()
        #expect(!files.isEmpty)
        for file in files where file.name != "NativeLaunchSwitches.swift" {
            #expect(!file.text.contains("environment[\"TD_"), "\(file.name) reads a launch switch by a loose name")
        }
    }

    @Test func theOldEngineSwitchesAreGone() throws {
        for file in try sources() {
            let oldOwners = ["Settings", "Session", "Core", "Hoot", "Server", "Task", "Voice", "Log"].map { "old\($0)OwnerDisabled" }
            for gone in ["TD_NATIVE_GRAPH", "TDNativeGraph", "TD_NATIVE_NODE", "TD_NATIVE_PRIMARY", "resetForTests"] + oldOwners {
                #expect(!file.text.contains(gone), "\(file.name) still has \(gone)")
            }
        }
        #expect(EngineConfiguration.dataEnvironmentKey == NativeLaunchSwitches.dataFolder)
    }
}
