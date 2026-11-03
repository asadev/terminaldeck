import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortSessionsWorkersLiftTests: XCTestCase {
    typealias V = NativeRPCValue
    typealias S = BackendDeckCoreTestPortSessionsDeviceFixtureSupport
    typealias M = BackendDeckCoreTestPortSessionsMachineFixtureSupport
    func context(_ sid: String = "s1", kind: BackendDeckToolsMachinesContext.Kind = .session, attended: Bool = true) -> BackendDeckToolsMachinesContext {
        .init(kind:kind,attended:attended,sessionID:kind == .session ? sid : nil,deviceID:kind == .remote ? "d1" : nil,rpc:.init(caller:.nativeApp,ownerID:"fixture"),startedByCopilot:{_ in false},noteStarted:{_ in})
    }
    func worker(_ id: String, _ args: V, f: BackendDeckCoreTestPortSessionsWorkerFixture, caller: BackendDeckToolsMachinesContext? = nil) async throws -> M.Gated {
        let tools=BackendDeckToolsMachinesWorkers(pool:f,metadata:f)
        return try await M.call(id:id,arguments:args,context:caller ?? context(),prepare:{try tools.policy($0,$1,$2)},run:{try await tools.run($0,$1,$2)})
    }
    func testWorkerCatalogueHasOnlyThreeVerbsBothSpellingsAndNoLoginTransferPrimitive() throws {
        let f=BackendDeckCoreTestPortSessionsFixture(),unused=BackendDeckCoreTestPortSessionsUnusedLift(),lift=try BackendDeckToolsSessionsArea.liftDefinitions(runtime:f,requests:unused)
        let rows=try BackendDeckToolsMachinesCatalogue.rows().filter{["browser.workers","browser.worker"].contains($0["id"].string ?? "")}
        XCTAssertEqual(rows.map{$0["id"].string}+[lift.first?.spec.id],["browser.workers","browser.worker","browser.lift_request"])
        for id in ["browser.lift","browser_lift","browser.inject","browser_inject"]{XCTAssertFalse(BackendDeckToolsSessionsGrants.ordinary.contains(id))}
        for id in ["browser.workers","browser.worker","browser.lift_request"]{XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(id));XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(id.replacingOccurrences(of:".",with:"_")))}
        var root=URL(fileURLWithPath:#filePath);for _ in 0..<5{root.deleteLastPathComponent()}
        for file in ["BackendDeckToolsMachinesWorkers.swift","BackendDeckToolsSessionsWindowsLift.swift"]{
            let source=try String(contentsOf:root.appendingPathComponent("macos/TerminalDeckNative/Sources/TerminalDeckBackend/"+file),encoding:.utf8)
            for name in ["liftFromPage","injectLift","sessionForPartition"]{XCTAssertFalse(source.contains(name),file)}
        }
    }
    func testBothWorkerToolsRefusePairedAndUnattendedCallersWithSourceReasons() async throws {
        for (id,args) in [("browser.workers",V.object([])),("browser.worker",.object([.init("action",.string("take"))]))] {
            let paired=try await worker(id,args,f:.init(),caller:context(kind:.remote))
            XCTAssertFalse(paired.result.ok);XCTAssertEqual(paired.result.refusal?.rawValue,"not-granted")
            let unattended=try await worker(id,args,f:.init(),caller:context(kind:.local,attended:false))
            XCTAssertFalse(unattended.result.ok);XCTAssertEqual(unattended.result.refusal?.rawValue,"not-permitted-unattended");XCTAssertTrue(unattended.result.error?.contains("Do not retry") == true)
        }
    }
    func testOnlyCallerOwnedWindowsAreMappedAndNoWindowAdviceMatchesCaller() async throws {
        let f=BackendDeckCoreTestPortSessionsWorkerFixture();f.slotsBySession=["s1":["w1":"B1"]]
        let mine=try await worker("browser.workers",.object([]),f:f),rows=try XCTUnwrap(mine.result.value["workers"].elements)
        XCTAssertEqual(rows.first{$0["name"] == .string("Worker 1") }?["window"],.string("B1"));XCTAssertEqual(rows.first{$0["name"] == .string("Worker 2") }?["window"],.null)
        let others=try await worker("browser.workers",.object([]),f:f,caller:context("s2"))
        XCTAssertTrue((others.result.value["workers"].elements ?? []).allSatisfy{$0["window"] == .null})
        XCTAssertEqual(f.windowCallers,["s1","s2"])
        let none=try await worker("browser.workers",.object([]),f:.init())
        XCTAssertTrue(none.result.value["note"].string?.contains("none can be driven yet") == true)
        let hoot=try await worker("browser.workers",.object([]),f:.init(),caller:context(kind:.local))
        XCTAssertTrue(hoot.result.value["note"].string?.contains("Hoot’s tab is not one") == true)
    }
    func testWorkerEmptySitesAndPaceDoNotExposeCookies() async throws {
        let empty=BackendDeckCoreTestPortSessionsWorkerFixture();empty.workers=[]
        let nothing=try await worker("browser.workers",.object([]),f:empty)
        XCTAssertTrue(nothing.result.value["note"].string?.contains("no worker profiles yet") == true)
        let result=try await worker("browser.workers",.object([]),f:.init()),blob=result.result.value.compact
        XCTAssertTrue(blob.contains("shop.example.com"));XCTAssertFalse(blob.contains("sessionid"));XCTAssertFalse(blob.contains("cookie"))
        XCTAssertEqual(result.result.value["maxConcurrent"],.number(2));XCTAssertEqual(result.result.value["minDelayMs"],.number(1000));XCTAssertEqual(result.result.value["jitterMs"],.number(500))
    }
    func testTakeReportsServedPaceMissingWindowAndActualWindow() async throws {
        let result=try await worker("browser.worker",.object([.init("action",.string("take"))]),f:.init())
        XCTAssertTrue(result.result.ok);XCTAssertEqual(result.result.value["pacedMs"],.number(1250));XCTAssertEqual(result.result.value["window"],.null)
        XCTAssertTrue(result.result.value["note"].string?.contains("cannot drive it yet") == true)
        let f=BackendDeckCoreTestPortSessionsWorkerFixture();f.slotsBySession=["s1":["w1":"B1"]]
        let actual=try await worker("browser.worker",S.o([("action",.string("take")),("worker",.string("Worker 1"))]),f:f)
        XCTAssertEqual(actual.result.value["window"],.string("B1"))
    }
    func testTakeResolvesPanelNameAndUnknownNamesOrPoolRefusalsAreExact() async throws {
        let f=BackendDeckCoreTestPortSessionsWorkerFixture()
        _ = try await worker("browser.worker",S.o([("action",.string("take")),("worker",.string("worker 2"))]),f:f)
        XCTAssertEqual(f.taken,[S.o([("holder",.string("session::s1")),("profileId",.string("w2"))])])
        let unknown=try await worker("browser.worker",S.o([("action",.string("take")),("worker",.string("Worker 9"))]),f:.init())
        XCTAssertFalse(unknown.result.ok);XCTAssertTrue(unknown.result.error?.contains("no worker by that name") == true)
        let denied=BackendDeckCoreTestPortSessionsWorkerFixture();denied.takeRefusal="every worker is out."
        let out=try await worker("browser.worker",.object([.init("action",.string("take"))]),f:denied)
        XCTAssertFalse(out.result.ok);XCTAssertTrue(out.result.error?.contains("every worker is out") == true)
    }
    func testReleasePropagatesCallerHolderAndRejectsMissingWorkerOrUnknownAction() async throws {
        let f=BackendDeckCoreTestPortSessionsWorkerFixture(),named=S.o([("action",.string("take")),("worker",.string("Worker 1"))])
        _ = try await worker("browser.worker",named,f:f)
        let other=try await worker("browser.worker",named.setting("action",.string("release")),f:f,caller:context("s2"))
        XCTAssertFalse(other.result.ok);XCTAssertTrue(other.result.error?.contains("not held by you") == true)
        let mine=try await worker("browser.worker",named.setting("action",.string("release")),f:f)
        XCTAssertTrue(mine.result.ok);XCTAssertEqual(f.releaseCallers,["session::s2","session::s1"])
        let missing=try await worker("browser.worker",.object([.init("action",.string("release"))]),f:.init())
        XCTAssertFalse(missing.result.ok);XCTAssertTrue(missing.result.error?.contains("needs the worker") == true)
        let bad=try await worker("browser.worker",.object([.init("action",.string("destroy"))]),f:.init())
        XCTAssertFalse(bad.result.ok);XCTAssertTrue(bad.result.error?.contains("action must be one of") == true)
    }
    private func lift(_ args: V, f: BackendDeckCoreTestPortSessionsFixture, bridge: BackendDeckCoreTestPortSessionsLiftBridge, attended: Bool = true) async throws -> BackendMCPToolReply {
        let defs=try BackendDeckToolsSessionsArea.liftDefinitions(runtime:f,requests:bridge)
        let call=BackendMCPCallContext(sessionID:"s1",machineID:"",projectRoot:nil,attended:attended,allowedTools:[],allowedTiers:[.read,.act,.alter],cancellation:.init())
        return try await XCTUnwrap(defs.first).handler(call,args)
    }
    func testLiftFilesActualInboxAndMovesNoLoginDataAndRepeatKeepsSameRow() async throws {
        let trace=BackendDeckCoreTestPortSessionsCounter(),transfers=BackendDeckCoreTestPortSessionsCounter()
        let inbox=BackendBrowserWorkersLiftRequests(profiles:{_ in [.init(id:"p-default",name:"Default"),.init(id:"w1",name:"Worker 1")]},authorize:{_,_,_,_,_ in},changed:{_ = trace.next()},transfer:{_,_ in _ = transfers.next();XCTFail("Filing must never copy a login");return 1})
        let bridge=BackendDeckCoreTestPortSessionsLiftBridge(inbox:inbox),f=BackendDeckCoreTestPortSessionsFixture(); f.identity = .init(kind:.session,sessionID:"s1",machineID:"",callID:"row")
        let first=try await lift(S.o([("from",.string("Default")),("reason",.string("The marina run needs signed-in workers."))]),f:f,bridge:bridge),value=try XCTUnwrap(first.structuredContent)
        XCTAssertFalse(first.isError);XCTAssertEqual(value["asked"],.bool(true));XCTAssertEqual(value["repeated"],.bool(false));XCTAssertEqual(value["from"],.string("Default"));XCTAssertEqual(value["into"],.array([.string("Worker 1")]))
        let rows=try await inbox.list(bridge.caller);XCTAssertEqual(rows.elements?.count,1);XCTAssertEqual(rows.elements?.first?["reason"],.string("The marina run needs signed-in workers."))
        XCTAssertEqual(trace.current,1); XCTAssertEqual(transfers.current,0); XCTAssertTrue(value["note"].string?.contains("Do not retry") == true)
        let repeated=try await lift(.object([.init("from",.string("Default"))]),f:f,bridge:bridge)
        XCTAssertFalse(repeated.isError);XCTAssertEqual(repeated.structuredContent?["repeated"],.bool(true));XCTAssertEqual(repeated.structuredContent?["requestId"],value["requestId"])
        let after=try await inbox.list(bridge.caller);XCTAssertEqual(after.elements?.count,1)
    }
    func testLiftUnknownProfileSourceSentenceAndCallerGatesLeaveInboxEmpty() async throws {
        let inbox=BackendBrowserWorkersLiftRequests(profiles:{_ in [.init(id:"p-default",name:"Default"),.init(id:"w1",name:"Worker 1")]},authorize:{_,_,_,_,_ in},changed:{})
        let bridge=BackendDeckCoreTestPortSessionsLiftBridge(inbox:inbox),f=BackendDeckCoreTestPortSessionsFixture(); f.identity = .init(kind:.session,sessionID:"s1",callID:"row")
        let unknown=try await lift(.object([.init("from",.string("Nope"))]),f:f,bridge:bridge)
        XCTAssertTrue(unknown.isError)
        // Intentionally retains the source wording. The current raw Safari
        // inbox says "Name one unambiguous source profile."; this catches the
        // missing named-ingress compatibility adapter at the combined gate.
        XCTAssertTrue(unknown.content.first?["text"].string?.contains("no profile called \"Nope\"") == true)
        let empty=try await inbox.list(bridge.caller);XCTAssertEqual(empty.elements?.count,0)
        f.identity = .init(kind:.remote,deviceID:"d1",callID:"row")
        let remote=try await lift(.object([.init("from",.string("Default"))]),f:f,bridge:bridge)
        XCTAssertTrue(remote.isError);XCTAssertEqual(remote.structuredContent?["refusal"],.string("not-granted"))
        f.identity = .init(kind:.session,sessionID:"s1",callID:"row")
        let unattended=try await lift(.object([.init("from",.string("Default"))]),f:f,bridge:bridge,attended:false)
        XCTAssertTrue(unattended.isError);XCTAssertEqual(unattended.structuredContent?["refusal"],.string("not-permitted-unattended"));XCTAssertTrue(unattended.content.first?["text"].string?.contains("Do not retry") == true)
        let final=try await inbox.list(bridge.caller);XCTAssertEqual(final.elements?.count,0)
    }
}

final class BackendDeckCoreTestPortSessionsWorkerFixture: BackendDeckToolsMachinesWorkerPool, BackendDeckToolsMachinesWorkerMetadata, @unchecked Sendable {
    typealias V=NativeRPCValue;typealias S=BackendDeckCoreTestPortSessionsDeviceFixtureSupport
    var workers:[V]=(1...2).map{S.o([("profileId",.string("w\($0)")),("name",.string("Worker \($0)")),("busy",.bool(false)),("holder",.string("")),("readyInMs",.number(0))])}
    var slotsBySession:[String:[String:String]]=[:],taken:[V]=[],windowCallers:[String]=[],releaseCallers:[String]=[],takeRefusal:String?
    private var held:[String:String]=[:]
    func view(context:BackendDeckToolsMachinesContext)->V{S.o([("workers",.array(workers)),("pace",S.o([("maxConcurrent",.number(2)),("minDelayMs",.number(1000)),("jitterMs",.number(500))]))])}
    func take(profileID:String?,holdMS:V,context:BackendDeckToolsMachinesContext)->V{
        var input=S.o([("holder",.string(context.holder))]);if let profileID{input=input.setting("profileId",.string(profileID))};taken.append(input)
        if let takeRefusal{return S.o([("ok",.bool(false)),("reason",.string(takeRefusal))])}
        let chosen=profileID ?? "w1";held[chosen]=context.holder
        guard let row=workers.first(where:{$0["profileId"].string==chosen})else{return S.o([("ok",.bool(false)),("reason",.string("there is no worker by that name."))])}
        workers = workers.map { $0["profileId"].string == chosen ? $0.setting("busy", .bool(true)).setting("holder", .string(context.holder)) : $0 }
        return S.o([("ok",.bool(true)),("profileId",.string(chosen)),("name",row["name"]),("pacedMs",.number(1250)),("expiresAt",.number(1_800_000_120_000))])
    }
    func release(profileID:String,renew:Bool,holdMS:V,context:BackendDeckToolsMachinesContext)->Bool{releaseCallers.append(context.holder);guard held[profileID]==context.holder else{return false};if !renew{held[profileID]=nil};return true}
    func windowsByWorker(context:BackendDeckToolsMachinesContext)->[String:String]{windowCallers.append(context.sessionID ?? "");return slotsBySession[context.sessionID ?? ""] ?? [:]}
    func signedInHosts(profileID:String,context:BackendDeckToolsMachinesContext)->[String]{profileID=="w1" ? ["shop.example.com"] : []}
}
struct BackendDeckCoreTestPortSessionsUnusedLift: BackendDeckToolsSessionsLiftRequests {
    func file(askedBy:String,from:String,into:[String],reason:NativeRPCValue,context:BackendMCPCallContext)throws->NativeRPCValue{throw NativeRPCError(code:"unused",message:"Definition-only fixture must not file an ask")}
}
struct BackendDeckCoreTestPortSessionsLiftBridge: BackendDeckToolsSessionsLiftRequests {
    let inbox:BackendBrowserWorkersLiftRequests
    var caller:BackendBrowserScrapingCaller{.init(ownerID:"session::s1",sessionID:"s1",machineID:"",attended:true,remote:false,rpc:.init(caller:.nativeApp,ownerID:"fixture"))}
    func file(askedBy:String,from:String,into:[String],reason:NativeRPCValue,context:BackendMCPCallContext)async throws->NativeRPCValue{
        let workers=NativeRPCValue.object([.init("workers",.array([.object([.init("profileId",.string("w1")),.init("name",.string("Worker 1"))])]))])
        let answer=try await inbox.file(.object([.init("from",.string(from)),.init("into",.array(into.map(NativeRPCValue.string))),.init("reason",reason)]),caller:caller,workers:workers)
        // A fixture projection of declared profile names, no inbox/transfer rules.
        let names=["p-default":"Default","w1":"Worker 1"]
        return answer.setting("fromName",names[answer["request"]["fromProfileId"].string ?? ""].map(NativeRPCValue.string) ?? .missing)
            .setting("intoNames",.array((answer["request"]["intoProfileIds"].elements ?? []).compactMap{names[$0.string ?? ""].map(NativeRPCValue.string)}))
    }
}
