import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// A DOM/input host for the real BrowserDriverEngine. It does not create a WKWebView.
@MainActor
final class BackendDeckCoreTestPortSessionsBrowserHost: BackendBrowserRuntime {
    var ownTabID:String?
    var urls:[String:String]=[:],clock=10_000.0
    func add(_ id:String,url:String="http://localhost:3000/"){urls[id]=url}
    func bindings()async->BrowserBindings{.init(windows:[:])}
    func tabExists(_ id:String)->Bool{urls[id] != nil}
    func createTab(url:URL,isolated:Bool)->String{let id="new-\(urls.count)";urls[id]=url.absoluteString;return id}
    func createProfileTab(url:URL,isolated:Bool,profileID:String)->String{createTab(url:url,isolated:isolated)}
    func attach(_ id:String,to session:BrowserDriverSession)async->String?{"B1"}
    func load(_ id:String,url:URL){urls[id]=url.absoluteString}
    func isIsolated(_ id:String)->Bool{false}
    func setIsolated(_ id:String,_ isolated:Bool){}
    func settle(_ id:String,timeoutMs:Int)async->Bool{true}
    func pageURL(_ id:String)->String{urls[id] ?? ""}
    func title(_ id:String)->String{"Dev"}
    func displayTitle(_ id:String)->String{"Dev"}
    func evaluate(_ id:String,_ script:String)async throws->Any?{
        // Facts from a fake DOM. The actual driver performs targeting, stability,
        // secret checks and command execution; no driver behavior lives here.
        ["url":pageURL(id),"title":"Dev","text":"hello","textTruncated":false,"elements":[],"matched":0,"truncated":false,
         "found":true,"visible":true,"enabled":true,"hit":true,"secret":false,"label":"Go","tag":"BUTTON","ok":true,
         "rect":["x":10,"y":10,"width":100,"height":20],"viewport":["width":1024,"height":768]] as [String:Any]
    }
    func reveal(_ id:String)async->Bool{true}
    func click(_ id:String,cssRect:CGRect)->Bool{true}
    func focusForTyping(_ id:String)->Bool{true}
    func type(_ id:String,plan:BrowserTypingPlan)->Bool{true}
    func press(_ id:String,key:BrowserKeySpec)->Bool{true}
    func screenshot(_ id:String)async throws->(path:String,width:Int,height:Int,masked:Int){("/tmp/x.png",1,1,0)}
    func handoverPrompt(_ id:String)->String?{nil}
    func otherHandover(than id:String)->String?{nil}
    func handOver(_ id:String,prompt:String,windowMs:Int)async->String{"resumed"}
    func closeTab(_ id:String){urls[id]=nil}
    func unbind(_ id:String){}
    func now()->Double{clock}
    func pause(ms:Int)async{clock+=Double(ms)}
    func pageState(_ tabID:String)throws->NativeRPCValue{.object([.init("id",.string(tabID)),.init("url",.string(pageURL(tabID))),.init("profileId",.string("default"))])}
    func pageCommand(_ tabID:String,operation:String,arguments:NativeRPCValue)async throws->NativeRPCValue{throw NativeRPCError(code:"unused",message:"No toolbar operation was expected")}
    func frameCommand(_ tabID:String,operation:String,arguments:NativeRPCValue)async throws->NativeRPCValue{throw NativeRPCError(code:"unused",message:"No frame operation was expected")}
    func dataCommand(_ operation:String,arguments:NativeRPCValue)async throws->NativeRPCValue{throw NativeRPCError(code:"unused",message:"No site data operation was expected")}
    func revealScreenshot(_ path:String)throws{XCTFail("The fixture does not open files")}
}

@MainActor
final class BackendDeckCoreTestPortSessionsBrowserFixture {
    let host=BackendDeckCoreTestPortSessionsBrowserHost(),bindings=BackendBrowserBindings()
    let service:BackendBrowserService
    private init(host:BackendDeckCoreTestPortSessionsBrowserHost,bindings:BackendBrowserBindings,service:BackendBrowserService){self.service=service}
    init(){
        let host=self.host,bindings=self.bindings
        service=BackendBrowserService(runtime:host,bindings:bindings,resolve:{ context in
            let parts=context.ownerID.components(separatedBy:"|")
            return .init(ownerID:context.ownerID,sessionID:parts.count>1 ? parts[1] : "s1",machineID:parts.first ?? "")
        },resolveSession:{.init(sessionId:$0,machineId:"")},resolveProfile:{_,_ in .init(id:"default",name:"Default",partition:"persist:default")},
            resolveCreationProfile:{_,_ in .init(id:"default",name:"Default",partition:"persist:default")},authorize:{_ in},publish:{_,_,_ in},reportEventFailure:{_ in})
    }
    func attach(_ tab:String,session:String="s1",machine:String="")throws{
        host.add(tab);bindings.observe(.init(tabID:tab,viewID:"view-"+tab,url:"http://localhost:3000/",title:"Docs"))
        _ = try bindings.attach(tab,to:.init(sessionId:session,machineId:machine))
    }
    func registrations()async throws->[(BackendMCPTool,BackendNativeMCPServer.Handler)]{
        let server=BackendNativeMCPServer()
        try await BackendBrowserFactories.registerTools(server,service:service,context:{caller in
            .init(caller:.internalEngine,ownerID:caller.machineID+"|"+caller.sessionID)
        })
        return await server.registrations()
    }
}

struct BackendDeckCoreTestPortSessionsListener: BackendDeckCoreSecurityListening {
    func start(port:Int)async throws->Int{port==0 ? 52913 : port}
    func stop()async{}
}

actor BackendDeckCoreTestPortSessionsEndpoint: BackendMCPToolEndpoint {
    nonisolated let readiness:BackendLaunchReadiness = .ready
    private struct Binding:Sendable {var session:String?;var machine="";let grant:BackendMCPCallerGrant}
    private let endpoint:BackendDeckCoreSecurityEndpoint
    private let tools:[BackendMCPTool]
    private var bindings:[UUID:Binding]=[:]
    var available=true
    init(endpoint:BackendDeckCoreSecurityEndpoint,tools:[BackendMCPTool]){self.endpoint=endpoint;self.tools=tools}
    func setAvailable(_ flag:Bool){available=flag}
    func description()throws->BackendMCPEndpointDescription?{available ? try .init(url:endpoint.url,implementation:.native) : nil}
    func catalogue()->[BackendMCPTool]{tools}
    func register(token:String,grant:BackendMCPCallerGrant)async throws->BackendMCPRegistration{
        let id=UUID()
        let registration=try await endpoint.callers.set(token:token,grant:.init(identity:id.uuidString,attended:grant.attended,tools:grant.allowedTools,caller:{[weak self] in
            guard let self else{return .init(kind:.session,tiers:[])}
            return await self.caller(id)
        }))
        bindings[id]=Binding(grant:grant)
        // Registration IDs are the real credential-table IDs; keep a separate
        // identity lookup only to supply the endpoint protocol's session binding.
        registrations[registration]=id
        return .init(id:registration)
    }
    private var registrations:[UUID:UUID]=[:]
    private func caller(_ id:UUID)async->BackendDeckCoreSecurityCaller{
        guard let binding=bindings[id]else{return .init(kind:.session,tiers:[])}
        let permitted=await binding.grant.permitted()
        return .init(kind:.session,tiers:permitted ? binding.grant.allowedTiers : [],sessionID:binding.session,machineID:binding.machine)
    }
    func bind(_ registration:BackendMCPRegistration,sessionID:String,machineID:String)throws{
        guard let id=registrations[registration.id],var binding=bindings[id]else{throw NativeRPCError.invalidArguments("The token was revoked")}
        binding.session=sessionID;binding.machine=machineID;bindings[id]=binding
    }
    func revoke(_ registration:BackendMCPRegistration)async{
        if let id=registrations.removeValue(forKey:registration.id){bindings[id]=nil}
        await endpoint.callers.revoke(registration.id)
    }
}

@MainActor
final class BackendDeckCoreTestPortSessionsDoorFixture {
    typealias V=NativeRPCValue
    let browser:BackendDeckCoreTestPortSessionsBrowserFixture
    let clock:BackendDeckCoreTestPortSessionsManualClock
    let root:URL
    let server:BackendDeckCoreSecurityServer
    let endpoint:BackendDeckCoreSecurityEndpoint
    let bridge:BackendDeckCoreTestPortSessionsEndpoint
    let local:BackendSessionToolLeases
    let leases:BackendDeckToolsSessionsLeaseFacade
    private init(root:URL,server:BackendDeckCoreSecurityServer,endpoint:BackendDeckCoreSecurityEndpoint,bridge:BackendDeckCoreTestPortSessionsEndpoint,
                 local:BackendSessionToolLeases,clock:BackendDeckCoreTestPortSessionsManualClock,browser:BackendDeckCoreTestPortSessionsBrowserFixture){
        self.root=root;self.server=server;self.endpoint=endpoint;self.bridge=bridge;self.local=local;self.browser=browser;self.clock=clock
        leases = .init(local:local,endpoint:bridge,clock:clock)
    }
    static func make(network:Bool=false,devices:F?=nil)async throws->BackendDeckCoreTestPortSessionsDoorFixture{
        let browser=BackendDeckCoreTestPortSessionsBrowserFixture(),clock=BackendDeckCoreTestPortSessionsManualClock()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreTestPortSessions-door-"+UUID().uuidString)
        var policies:[BackendDeckCoreSecurityToolPolicy]=[],metadata:[BackendDeckCoreCatalogueMetadata]=[]
        for (spec,handler) in try await browser.registrations() where ["browser.open","browser.read","browser.step","browser.screenshot","browser.handover","browser.close"].contains(spec.id){
            policies.append(.init(tool:spec,summary:{_,_ in spec.id},run:{args,context in
                let reply=try await handler(context.native,args)
                guard !reply.isError else{throw NativeRPCError(code:"not-permitted",message:reply.content.first?["text"].string ?? "Browser refused")}
                guard let value=reply.structuredContent else{throw NativeRPCError(code:"invalid-provider",message:"Browser returned no structured result")}
                return .init(value:value,summary:.object([]))
            }))
            metadata += try BackendDeckCoreBrowserMetadata.entries(specs:[spec])
        }
        if network {
            let spec=try XCTUnwrap(BackendBrowserScrapingMCP.tools().first{$0.id=="browser.network"})
            metadata += try BackendDeckCoreBrowserMetadata.entries(specs:[spec])
            policies.append(.init(tool:spec,summary:{_,_ in "Network definition"},run:{_,_ in throw NativeRPCError(code:"unused",message:"This fixture only describes network; it must never arm it")}))
        }
        if let devices {
            let domain=BackendDeckToolsMachinesDevices(service:devices)
            for row in try BackendDeckToolsMachinesCatalogue.rows() where (row["id"].string ?? "").hasPrefix("devices."){
                let spec=try BackendDeckCoreTestPortSessionsDeviceFixtureSupport.spec(row["id"].string!)
                metadata.append(.init(tool:spec,title:row["title"].string!,index:row["index"].string))
                policies.append(.init(tool:spec,spendsDeviceInput:["devices.tap","devices.swipe","devices.type","devices.button"].contains(spec.id),summary:{_,_ in spec.id},run:{args,context in
                    let machine=BackendDeckCoreTestPortSessionsDeviceFixtureSupport.context(.session)
                    _ = try await domain.policy(spec,args,machine)
                    let output=try await domain.run(spec.id,args,machine);return .init(value:output.value,summary:output.summary)
                }))
            }
        }
        if network || devices != nil {
            let snapshot=metadata
            let describe=try BackendDeckCoreCatalogueDescribe.tools(catalogue:{snapshot})
            policies += describe.policies;metadata += describe.metadata
        }
        let final=metadata
        let control=try BackendDeckCoreSecurityControl(log:.init(directory:root.appendingPathComponent("log"),now:{clock.now()}),
            consent:.init(clock:clock,ask:{_ in false}),policies:policies,now:{clock.now()})
        let server=BackendDeckCoreSecurityServer(control:control,ownPorts:.init(),listenerFactory:{_ in BackendDeckCoreTestPortSessionsListener()},listing:{_,caller,grant in
            try BackendDeckCoreCatalogueDescribe.wireListing(metadata:final,caller:caller,granted:grant)
        })
        let endpoint=try await server.start()
        let bridge=BackendDeckCoreTestPortSessionsEndpoint(endpoint:endpoint,tools:policies.map(\.tool))
        let local=try BackendSessionToolLeases(endpoint:bridge,userData:root,clock:clock)
        let fixture=BackendDeckCoreTestPortSessionsDoorFixture(root:root,server:server,endpoint:endpoint,bridge:bridge,local:local,clock:clock,browser:browser)
        return fixture
    }
    typealias F=BackendDeckCoreTestPortSessionsDeviceFixture
    func request(_ method:String,params:V = .object([]),token:String)async throws->V{
        let body=try V.object([.init("jsonrpc",.string("2.0")),.init("id",.number(1)),.init("method",.string(method)),.init("params",params)]).encodedJSON()
        let response=await server.respond(.init(method:"POST",path:"/mcp",headers:["host":"127.0.0.1:\(endpoint.port)","authorization":"Bearer "+token,"content-type":"application/json","accept":"application/json, text/event-stream"],body:body))
        guard response.status==200 else{throw NativeRPCError(code:"http-\(response.status)",message:"Request was refused before a tool was named")}
        return try V.parseJSON(response.body)["result"]
    }
    func token(_ prepared:BackendPreparedToolLease)throws->String{
        let index=try XCTUnwrap(prepared.arguments.firstIndex(of:"--mcp-config"))
        let config=try V.parseJSON(Data(contentsOf:URL(fileURLWithPath:prepared.arguments[index+1])))
        return String(try config["mcpServers"]["deck-control"]["headers"]["Authorization"].requireString("Authorization").dropFirst(7))
    }
    func token(_ text:String)throws->String{
        let config=try V.parseJSON(Data(text.utf8));return String(try config["mcpServers"]["deck-control"]["headers"]["Authorization"].requireString("Authorization").dropFirst(7))
    }
    func tool(_ name:String,args:V = .object([]),token:String)async throws->V{try await request("tools/call",params:.object([.init("name",.string(name)),.init("arguments",args)]),token:token)}
    func close()async{
        await leases.stop();await server.stop();browser.service.shutdown();try? FileManager.default.removeItem(at:root)
    }
}
