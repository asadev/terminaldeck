import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortSessionsRemoteServersTests: XCTestCase {
    typealias V = NativeRPCValue
    typealias S = BackendDeckCoreTestPortSessionsDeviceFixtureSupport
    typealias M = BackendDeckCoreTestPortSessionsMachineFixtureSupport
    func testRemoteStatusJoinsDeviceReachConnectionAndConfinement() async throws {
        let channels = BackendDeckCoreTestPortSessionsChannels(M.remoteAnswers), remote = BackendDeckToolsMachinesRemote(channels: channels)
        let output = try await remote.run("remote.status", .object([]), S.context())
        XCTAssertEqual(output.value["remoteAccess"]["on"], .bool(true))
        let rows = try XCTUnwrap(output.value["devices"].elements)
        XCTAssertEqual(rows[0]["id"], .string("d-phone")); XCTAssertEqual(rows[0]["kind"], .string("mine")); XCTAssertEqual(rows[0]["connected"], .bool(true)); XCTAssertEqual(rows[0]["drivesWindows"], .bool(true))
        XCTAssertEqual(rows[1]["id"], .string("d-guest")); XCTAssertEqual(rows[1]["status"], .string("pending")); XCTAssertEqual(rows[1]["connected"], .bool(false))
        XCTAssertEqual(output.value["confinement"]["platform"], .string("darwin")); XCTAssertEqual(output.value["confinement"]["confining"], .bool(true))
        XCTAssertEqual(output.value["confinement"].fields?.count, 2)
    }
    func testTailscaleIsNeverConsultedUnlessExplicitAndStaysOptional() async throws {
        let channels = BackendDeckCoreTestPortSessionsChannels(M.remoteAnswers), remote = BackendDeckToolsMachinesRemote(channels: channels)
        let plain = try await remote.run("remote.status", .object([]), S.context()), calls = await channels.calls
        XCTAssertFalse(plain.value.has("tailscale")); XCTAssertFalse(plain.value.compact.contains("Tailscale is not signed in")); XCTAssertFalse(calls.contains{$0.channel=="tailnet:status"})
        let asked = try await remote.run("remote.status", .object([.init("tailscale", .bool(true))]), S.context())
        XCTAssertEqual(asked.value["tailscale"]["optional"], .bool(true))
    }
    func testRemoteStatusAndManageRefusePairedDeviceBeforeAnyDialog() async throws {
        let channels = BackendDeckCoreTestPortSessionsChannels(M.remoteAnswers), remote = BackendDeckToolsMachinesRemote(channels: channels)
        for (id,args) in [("remote.status",V.object([])),("remote.manage",.object([.init("do",.string("stop"))]))] {
            let out = try await M.call(id:id,arguments:args,context:S.context(.remote),prepare:{try await remote.policy($0,$1,$2)},run:{try await remote.run($0,$1,$2)})
            XCTAssertFalse(out.result.ok); XCTAssertEqual(out.result.refusal?.rawValue,"not-granted"); XCTAssertTrue(out.asked.isEmpty)
        }
        let calls = await channels.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try S.spec("remote.manage").tier,.alter)
    }
    func testGuestApprovalSentenceNamesDeviceFoldersAndLoginsAndStoppingCostsConnections() async throws {
        let remote=BackendDeckToolsMachinesRemote(channels:BackendDeckCoreTestPortSessionsChannels(M.remoteAnswers))
        _ = try await remote.run("remote.status",.object([]),S.context())
        let sentence=await remote.sentence("remote.manage",S.o([("do",.string("approve")),("deviceId",.string("d-guest")),("kind",.string("guest")),("folders",.array([.string("/work/site")])),("loginShare",.string("selected")),("logins",.array([.string("acct-1")]))]))
        for expected in ["“Saba’s laptop”","/work/site","acct-1"] {XCTAssertTrue(sentence.contains(expected))}
        let stop=await remote.sentence("remote.manage",.object([.init("do",.string("stop"))]));XCTAssertTrue(stop.contains("cut off"))
    }
    func testGuestApprovalForwardsExactPanelArgumentsAndRequiresFolders() async throws {
        let channels=BackendDeckCoreTestPortSessionsChannels(M.remoteAnswers),remote=BackendDeckToolsMachinesRemote(channels:channels)
        let approved = V.array((M.remoteDevices.elements ?? []).map{$0["id"] == .string("d-guest") ? $0.setting("approved",.bool(true)).setting("status",.string("approved")) : $0})
        await channels.set("remote:device:approve",approved)
        let args=S.o([("do",.string("approve")),("deviceId",.string("d-guest")),("kind",.string("guest")),("folders",.array([.string("/work/site")])),("loginShare",.string("all"))])
        _ = try await remote.run("remote.manage",args,S.context())
        let calls=await channels.calls
        XCTAssertTrue(calls.contains{$0.channel=="remote:device:approve" && $0.args == [.string("d-guest"),.string("guest"),.array([.string("/work/site")]),.string("all"),.array([])]})
        do {_ = try await remote.policy(S.spec("remote.manage"),args.removing("folders"),S.context());XCTFail("A guest needs folders")}catch{XCTAssertTrue(error.localizedDescription.contains("folders"))}
    }
    func testRemotePairCodeReturnsOnlyToCallerAndNeverSummary() async throws {
        let remote=BackendDeckToolsMachinesRemote(channels:BackendDeckCoreTestPortSessionsChannels(M.remoteAnswers))
        let output=try await remote.run("remote.manage",.object([.init("do",.string("show-code"))]),S.context())
        XCTAssertEqual(output.value["code"],.string("135790"));XCTAssertFalse(output.summary.compact.contains("135790"))
    }
    func testServerShellTierCannotLowerAndNeverReadsGrantAndDescriptionExplainsPower() async throws {
        let servers=M.servers(BackendDeckCoreTestPortSessionsChannels(M.serverAnswers)),tool=try S.spec("servers.shell")
        let policy=try await servers.policy(tool,S.o([("do",.string("type")),("shellId",.string("s1 abc")),("text",.string("ls"))]),S.context())
        XCTAssertEqual(tool.tier,.alter);XCTAssertEqual(policy.tier,.alter)
        for text in ["full power","cannot be undone","asks the person first"]{XCTAssertTrue(tool.description.contains(text))}
        var root=URL(fileURLWithPath:#filePath);for _ in 0..<5{root.deleteLastPathComponent()}
        let source=try String(contentsOf:root.appendingPathComponent("macos/TerminalDeckNative/Sources/TerminalDeckBackend/BackendDeckToolsMachinesServers.swift"),encoding:.utf8)
        let withoutComments=source.replacingOccurrences(of:#"/\*[\s\S]*?\*/|(?m)^\s*//.*$"#,with:"",options:.regularExpression)
        XCTAssertNil(withoutComments.range(of:#"ServerGrants|grants\.granted|\.granted\("#,options:.regularExpression))
    }
    func testServerShellSentenceShowsWholeLineAndRejectsLongMultilineRemoteOrMissingTerminal() async throws {
        let servers=M.servers(BackendDeckCoreTestPortSessionsChannels(M.serverAnswers)),tool=try S.spec("servers.shell")
        let line="sudo systemctl restart nginx && journalctl -u nginx -n 50",args=S.o([("do",.string("type")),("shellId",.string("s1 abc")),("text",.string(line))])
        let policy=try await servers.policy(tool,args,S.context());XCTAssertTrue(policy.sentence.contains(line))
        for (arguments,text) in [(args.setting("text",.string(String(repeating:"x",count:1001))),"person can read all of it"),(args.setting("text",.string("ls\nrm -rf /")),"printable"),(args.setting("shellId",.string("nope")),"No terminal nope")] {
            do{_ = try await servers.policy(tool,arguments,S.context());XCTFail("Invalid terminal call accepted")}catch{XCTAssertTrue(error.localizedDescription.contains(text))}
        }
        do{_ = try await servers.policy(tool,args,S.context(.remote));XCTFail("Paired device accepted")}catch{XCTAssertTrue(error is BackendDeckCoreSecurityRefusal)}
    }
    func testOnlyServerShellTakesFreeTextThatRunsOnServer() throws {
        let banned=#"(?i)^(command|cmd|argv|args|script|shell|exec|run|sudo|code|eval|sql|query|text)$"#
        for id in BackendDeckToolsMachinesServers.ids where id != "servers.shell" {
            for key in try S.spec(id).inputSchema["properties"].fields?.map(\.key) ?? [] {XCTAssertNil(key.range(of:banned,options:.regularExpression),id+"."+key)}
        }
    }
    func testServerKeysExposeNamesAndScreenReadsExistingShadow() async throws {
        let channels=BackendDeckCoreTestPortSessionsChannels(M.serverAnswers),servers=M.servers(channels)
        let keys=try await servers.run("servers.details",.object([.init("about",.string("keys"))]),S.context())
        XCTAssertFalse(keys.value.compact.contains("KEY-MATERIAL"));XCTAssertFalse(keys.summary.compact.contains("KEY-MATERIAL"))
        let rows=try XCTUnwrap(keys.value["keys"].elements);XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows[0]["path"],.string("/home/me/.ssh/id_ed25519"));XCTAssertEqual(rows[0]["name"],.string("id_ed25519"));XCTAssertEqual(rows[0]["what"],.string("A key made by OpenSSH"));XCTAssertEqual(rows[0]["needsPassphrase"],.bool(false));XCTAssertEqual(rows[0].fields?.count,4)
        await channels.set("servers:controls:read",.null);await channels.set("servers:shell:account",S.o([("known",.string("yes")),("agents",.number(0)),("logins",.array([]))]))
        let screen=try await servers.run("servers.details",S.o([("about",.string("shell")),("shellId",.string("s1 abc"))]),S.context());XCTAssertEqual(screen.value["screen"],.string("me@web-1:~$ "))
    }
    func testServerAddReadsOfferedKeyInPlaceAndNeverReturnsMaterial() async throws {
        let channels=BackendDeckCoreTestPortSessionsChannels(M.serverAnswers),servers=M.servers(channels)
        let output=try await servers.run("servers.manage",S.o([("do",.string("add")),("address",.string("10.0.0.6")),("username",.string("deploy")),("keyPath",.string("/home/me/.ssh/id_ed25519"))]),S.context())
        XCTAssertFalse(output.value.compact.contains("KEY-MATERIAL"));XCTAssertFalse(output.summary.compact.contains("KEY-MATERIAL"))
        let calls=await channels.calls,added=try XCTUnwrap(calls.first{$0.channel=="servers:add"}?.args.first)
        XCTAssertEqual(added["method"],.string("key"));XCTAssertEqual(added["key"],.string(M.privateKey))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex{$0.channel=="servers:keys"}),try XCTUnwrap(calls.firstIndex{$0.channel=="servers:key-read"}))
    }
    func testServerAddRequiresExactlyOneSigninMethodAndLogsNoSecretsThroughRealGate() async throws {
        let channels=BackendDeckCoreTestPortSessionsChannels(M.serverAnswers),servers=M.servers(channels),tool=try S.spec("servers.manage")
        let base=S.o([("do",.string("add")),("address",.string("a")),("username",.string("u"))])
        for input in [base,base.setting("keyPath",.string("k")).setting("password",.string("p"))] {
            do{_ = try await servers.policy(tool,input,S.context());XCTFail("Add requires exactly one method")}catch{XCTAssertTrue(error.localizedDescription.contains("exactly one"))}
        }
        for input in [S.o([("do",.string("add")),("address",.string("10.0.0.6")),("username",.string("deploy")),("keyPath",.string("/home/me/.ssh/id_ed25519")),("passphrase",.string("open-sesame-77"))]),
            S.o([("do",.string("add")),("address",.string("10.0.0.7")),("username",.string("root")),("password",.string("hunter2-hunter2"))])] {
            let out=try await M.call(id:"servers.manage",arguments:input,prepare:{try await servers.policy($0,$1,$2)},run:{try await servers.run($0,$1,$2)})
            XCTAssertTrue(out.result.ok);XCTAssertFalse(out.logText.contains("open-sesame-77"));XCTAssertFalse(out.logText.contains("hunter2-hunter2"));XCTAssertFalse(out.logText.contains("KEY-MATERIAL"))
        }
    }
    func testCompletedOwnedFlowClosesShellButRunningFlowAndNamedPersonShellStayOpen() async throws {
        for (step,shouldClose) in [("done",true),("signing-in",false)] {
            let channels=BackendDeckCoreTestPortSessionsChannels(M.serverAnswers),servers=M.servers(channels)
            await channels.set("servers:setup:install",S.o([("ok",.bool(true)),("state",.object([.init("step",.string(step))]))]))
            let out=try await servers.run("servers.manage",S.o([("do",.string("install-agent")),("serverId",.string("s1")),("agent",.string("claude"))]),S.context()),calls=await channels.calls
            XCTAssertTrue(calls.contains{$0.channel=="servers:shell:open" && $0.args == [.string("s1"),.number(120),.number(30),.string("")]})
            XCTAssertEqual(calls.contains{$0.channel=="servers:shell:close" && $0.args == [.string("s1 fresh")]},shouldClose)
            if !shouldClose {XCTAssertEqual(out.value["shellId"],.string("s1 fresh"))}
        }
        let channels=BackendDeckCoreTestPortSessionsChannels(M.serverAnswers),servers=M.servers(channels)
        await channels.set("servers:host:install",S.o([("ok",.bool(true)),("state",.object([.init("step",.string("done"))]))]))
        _ = try await servers.run("servers.manage",S.o([("do",.string("install-host")),("serverId",.string("s1")),("shellId",.string("s1 abc"))]),S.context())
        let calls=await channels.calls
        XCTAssertTrue(calls.contains{$0.channel=="servers:host:install" && $0.args == [.string("s1"),.string("s1 abc")]})
        XCTAssertFalse(calls.contains{["servers:shell:open","servers:shell:close"].contains($0.channel)})
    }
    func testServerUploadNeverSendsCredentialFolder() async throws {
        let servers=M.servers(BackendDeckCoreTestPortSessionsChannels(M.serverAnswers))
        do{_ = try await servers.policy(S.spec("servers.manage"),S.o([("do",.string("upload")),("serverId",.string("s1")),("path",.string("/home/me/.aws/credentials"))]),S.context());XCTFail("Credential upload accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("credentials are kept"))}
    }
}
