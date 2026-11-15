import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Lean scope item 2 and proof P3: 0.22.0 switches the proven rows on (for a signed-in, allowed account only). The
/// debug-only plan for one scratch data folder against the TEST service can only ADD rows; reading one adopts nothing.
@Suite("Cloud memory rows — on as proven; the P3 plan is debug-only, scratch-only and only adds")
@MainActor
struct CloudScratchPlanUITests {
    @Test func exactlyTheProvenRowsAreOnAndTheLeanRowsAreI01ToI06() throws {
        #expect(NativeCloudBrainRegistration.provenRows == ["I01", "I02", "I03", "I04", "I05", "I06", "I09", "I10", "I11", "I12", "I21", "I23", "I24"])
        #expect(NativeCloudScratch.active == nil)
        // Without a plan the switched-on rows are exactly the proven ones: nothing more.
        #expect(NativeCloudBrainRegistration.enabledRows == NativeCloudBrainRegistration.provenRows)
        #expect(NativeCloudBrainRegistration.memoryRows == CloudBrainMemoryFormat.inventoryRows)
        let expected = Set(CloudBrainMemoryFormat.inventoryRows.map(CloudBrainMemoryFormat.domain))
            .union([CloudBrainFilesFormat.domain(CloudBootFilesFormat.inventoryRow)])
            .union(try BackendCloudLeanRecords.domains(BackendCloudLeanRecords.rows))
            .union(try BackendCloudKinds.domains(BackendCloudKinds.rows))
            .union([CloudFolderFormat.domain, CloudArtifactsFormat.domain])
        #expect(NativeCloudBrainRegistration.brainDomains == expected)
        #expect(NativeCloudBrainRegistration.leanMemoryRows == ["I01", "I02", "I03", "I04", "I05", "I06"])
        #expect(NativeCloudBrainRegistration.leanMemoryRows.isSubset(of: Set(CloudBrainMemoryFormat.inventoryRows)))
        #expect(NativeCloudScratch.variable == "TD_CLOUD_SCRATCH")
    }
    #if DEBUG
    private func folder() throws -> URL {
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112").resolvingSymlinksInPath()
        let made = approved.appendingPathComponent("a-scratch-plan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }
    private func write(_ folder: URL, _ fields: [String: String], memory: Bool = true, passwords: Bool? = nil, records: Bool? = nil, bootFiles: Bool? = nil) throws -> [String: String] {
        var parts = fields.map { "\"\($0.key)\":\"\($0.value)\"" }
        parts.append("\"memory\":\(memory)")
        if let passwords { parts.append("\"passwords\":\(passwords)") }
        if let records { parts.append("\"records\":\(records)") }
        if let bootFiles { parts.append("\"bootFiles\":\(bootFiles)") }
        parts.append("\"signIn\":true")
        let file = folder.appendingPathComponent("plan.json")
        try Data(("{" + parts.sorted().joined(separator: ",") + "}").utf8).write(to: file)
        return [NativeCloudScratch.variable: file.path]
    }
    private func good(_ folder: URL) -> [String: String] {
        ["dataRoot": folder.appendingPathComponent("data").path, "base": "https://td-cloud-test.terminaldeck.workers.dev/v1",
         "issuer": "https://issuer.example.invalid/auth/v1", "start": "https://site.example.invalid/start",
         "auth": "https://issuer.example.invalid/auth/v1", "key": "", "signInURLFile": folder.appendingPathComponent("sign-in-url.txt").path]
    }
    @Test func aPlanIsAcceptedOnlyForItsOwnScratchFolderAndTheTestService() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = folder.appendingPathComponent("data")
        let environment = try write(folder, good(folder))
        let plan = try #require(NativeCloudScratch.read(environment: environment, dataRoot: data))
        #expect(plan.memory)
        // Saved passwords are a switch of their own, off unless the plan says so.
        #expect(!plan.passwords)
        let withPasswordsEnvironment = try write(folder, good(folder), passwords: true)
        let withPasswords = try #require(NativeCloudScratch.read(environment: withPasswordsEnvironment, dataRoot: data))
        #expect(withPasswords.passwords)
        #expect(withPasswords.memory)
        // Reading a plan adopts nothing: saved passwords are on exactly as proven (0.22.0), not by the plan.
        #expect(NativeCloudScratch.active == nil)
        #expect(NativeCloudSecretsSwitch.on == NativeCloudSecretsSwitch.proven)
        // Projects and agents (lane A2's rows I11 and I10) are a third switch, off unless the plan says so.
        #expect(!plan.records)
        let withRecordsEnvironment = try write(folder, good(folder), records: true)
        let withRecords = try #require(NativeCloudScratch.read(environment: withRecordsEnvironment, dataRoot: data))
        #expect(withRecords.records)
        #expect(!withRecords.passwords)
        #expect(NativeCloudScratch.recordRows.isEmpty)
        #expect(NativeCloudBrainRegistration.recordRows == BackendCloudLeanRecords.rows)
        // Boot files (lane F's row I09) are a fourth switch, off unless the plan says so.
        #expect(!plan.bootFiles)
        let withBootEnvironment = try write(folder, good(folder), bootFiles: true)
        let withBoot = try #require(NativeCloudScratch.read(environment: withBootEnvironment, dataRoot: data))
        #expect(withBoot.bootFiles)
        #expect(!withBoot.records)
        #expect(NativeCloudScratch.bootRows.isEmpty)
        #expect(NativeCloudBrainRegistration.bootFilesOn)
        #expect(plan.signIn)
        #expect(plan.base.host == NativeCloudScratch.testHost)
        #expect(plan.signInURLFile?.lastPathComponent == "sign-in-url.txt")
        // Reading a plan switches nothing on by itself: still exactly the proven rows.
        #expect(NativeCloudBrainRegistration.enabledRows == NativeCloudBrainRegistration.provenRows)
        // Without the variable, or for another data folder, the app is the ordinary app.
        #expect(NativeCloudScratch.read(environment: [:], dataRoot: data) == nil)
        #expect(NativeCloudScratch.read(environment: environment, dataRoot: folder.appendingPathComponent("other")) == nil)
        #expect(NativeCloudScratch.read(environment: [NativeCloudScratch.variable: "plan.json"], dataRoot: data) == nil)
        // Never a data folder a person uses: anything under an Application Support folder is refused, whatever the
        // file says, also in another letter case and through a symbolic link (security review S10).
        let home = folder.appendingPathComponent("home")
        let lived = home.appendingPathComponent("Library/Application Support/Terminal Deck Dev")
        try FileManager.default.createDirectory(at: lived, withIntermediateDirectories: true)
        for spelled in [lived, home.appendingPathComponent("library/application support/Terminal Deck Dev"),
                        home.appendingPathComponent("Library/Application Support/terminaldeck")] {
            var fields = good(folder)
            fields["dataRoot"] = spelled.path
            let livedEnvironment = try write(folder, fields)
            #expect(NativeCloudScratch.read(environment: livedEnvironment, dataRoot: spelled) == nil)
        }
        let link = folder.appendingPathComponent("looks-like-scratch")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: lived)
        var linked = good(folder)
        linked["dataRoot"] = link.path
        let linkedEnvironment = try write(folder, linked)
        #expect(NativeCloudScratch.read(environment: linkedEnvironment, dataRoot: link) == nil)
        // A folder with the real app's own name is refused wherever it is.
        let namesake = folder.appendingPathComponent("terminaldeck")
        var named = good(folder)
        named["dataRoot"] = namesake.path
        let namedEnvironment = try write(folder, named)
        #expect(NativeCloudScratch.read(environment: namedEnvironment, dataRoot: namesake) == nil)
        // Never production, the production issuer, or the website.
        for (key, value) in [("base", CloudWire.productionBase), ("base", "https://td-cloud.terminaldeck.workers.dev/v1"), ("base", "http://td-cloud-test.terminaldeck.workers.dev/v1"),
                             // A look-alike of the TEST host: any worker may be called td-cloud-test in another account.
                             ("base", "https://td-cloud-test.fixture.workers.dev/v1"), ("base", "https://td-cloud-test.terminaldeck.workers.dev.example.invalid/v1"),
                             ("base", "https://td-cloud-test.terminaldeck.workers.dev:8443/v1"),
                             ("issuer", CloudWire.issuer), ("issuer", CloudWire.issuer + "/"), ("issuer", CloudWire.issuer.uppercased()),
                             ("start", "https://terminaldeck.dev/api/store/cloud/start"), ("start", "https://TERMINALDECK.DEV/api/store/cloud/start"),
                             ("start", "https://terminaldeck.dev./api/store/cloud/start"),
                             ("auth", "https://api.terminaldeck.dev/auth/v1"), ("auth", "https://API.TERMINALDECK.DEV/auth/v1"),
                             ("signInURLFile", "/private/tmp/elsewhere.txt")] {
            var changed = good(folder)
            changed[key] = value
            let changedEnvironment = try write(folder, changed)
            #expect(NativeCloudScratch.read(environment: changedEnvironment, dataRoot: data) == nil)
        }
        // The TEST host in another letter case is still the TEST host.
        var shouting = good(folder)
        shouting["base"] = "https://TD-CLOUD-TEST.terminaldeck.workers.dev/v1"
        let shoutingEnvironment = try write(folder, shouting)
        #expect(NativeCloudScratch.read(environment: shoutingEnvironment, dataRoot: data) != nil)
        // "memory": false leaves the rows off even under an accepted plan.
        let offEnvironment = try write(folder, good(folder), memory: false)
        let off = try #require(NativeCloudScratch.read(environment: offEnvironment, dataRoot: data))
        #expect(!off.memory)
    }
    /// 0.22.0 ships as the debug "shipped" flavour (ShippedHost trait, TD_HOST_INTEGRATED), like 0.21.4: there both
    /// debug-only Cloud doors are inert. A valid plan for this very folder is refused and no trace file is named.
    @Test func inTheShippedFlavourTheScratchPlanAndTheTraceAreInert() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = folder.appendingPathComponent("data")
        let environment = try write(folder, good(folder))
        #expect(NativeCloudScratch.read(environment: environment, dataRoot: data) != nil)
        #expect(NativeCloudScratch.plan(environment: environment, dataRoot: data, shipped: true) == nil)
        #expect(NativeCloudScratch.plan(environment: environment, dataRoot: data, shipped: false) != nil)
        let trace = [NativeLaunchSwitches.cloudTraceFile: folder.appendingPathComponent("trace.log").path]
        #expect(BackendCloudTrace.traceFile(trace, shipped: true) == nil)
        #expect(BackendCloudTrace.traceFile(trace, shipped: false) == trace[NativeLaunchSwitches.cloudTraceFile])
        #if TD_HOST_INTEGRATED
        #expect(NativeCloudScratch.shippedFlavour && BackendCloudTrace.shippedFlavour)
        #expect(NativeCloudScratch.plan(environment: environment, dataRoot: data) == nil)
        #expect(BackendCloudTrace.traceFile(trace) == nil)
        #else
        #expect(!NativeCloudScratch.shippedFlavour && !BackendCloudTrace.shippedFlavour)
        #endif
    }
    #endif
}
