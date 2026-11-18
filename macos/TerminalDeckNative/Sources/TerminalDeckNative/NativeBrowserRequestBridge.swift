import AppKit
import Security
import WebKit

struct NativeBrowserPageCapabilities: Sendable {
    let browserPasskeys: Bool
    let associatedDomains: [String]
    let locationDelegate: Bool

    static func live() -> Self {
        let task = SecTaskCreateFromSelf(nil)
        let browser = task.flatMap { SecTaskCopyValueForEntitlement($0, "com.apple.developer.web-browser.public-key-credential" as CFString, nil) } as? Bool ?? false
        let domains = task.flatMap { SecTaskCopyValueForEntitlement($0, "com.apple.developer.associated-domains" as CFString, nil) } as? [String] ?? []
        if #available(macOS 27.0, *) { return .init(browserPasskeys: browser, associatedDomains: domains, locationDelegate: true) }
        return .init(browserPasskeys: browser, associatedDomains: domains, locationDelegate: false)
    }
    func passkeyRefusal(relyingParty: String) -> String? {
        if browserPasskeys { return nil }
        if associatedDomains.contains("webcredentials:" + relyingParty) { return nil }
        return "This browser cannot show passkeys or security keys for this site: Apple's managed browser passkey entitlement is missing. Use a browser with passkey support."
    }
    static let locationRefusal = "The built-in browser cannot ask for this site's location on macOS 26: WebKit's public per-site location delegate requires macOS 27."
    static let notificationRefusal = "The built-in browser cannot show website notification permission: macOS WebKit has no public WKWebView website-notification delegate. App notifications are separate."
}

/// Only request kinds, RP names and error names cross this bridge. Challenges, credentials, files,
/// positions and device data remain in WebKit. Shared popup controllers are installed exactly once.
@MainActor
final class NativeBrowserRequestBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "tdPageRequests"
    private weak var tabs: NativeBrowserTabs?
    private let capabilities: @MainActor () -> NativeBrowserPageCapabilities
    private var controllers: [ObjectIdentifier: WeakController] = [:]

    init(tabs: NativeBrowserTabs, capabilities: @escaping @MainActor () -> NativeBrowserPageCapabilities = { .live() }) {
        self.tabs = tabs; self.capabilities = capabilities
    }
    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController, key = ObjectIdentifier(configuration.userContentController)
        guard controllers[key]?.value !== controller else { return }
        controllers[key] = WeakController(controller)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.name)
        let capability = capabilities()
        let domains = (try? JSONEncoder().encode(capability.associatedDomains)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let script = Self.script.replacingOccurrences(of: "/*TD_LOCATION_NATIVE*/false", with: capability.locationDelegate ? "true" : "false")
            .replacingOccurrences(of: "/*TD_BROWSER_PASSKEYS*/false", with: capability.browserPasskeys ? "true" : "false")
            .replacingOccurrences(of: "/*TD_ASSOCIATED_DOMAINS*/[]", with: domains)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let tab = tabs?.tabs.first(where: { $0.webView === view }),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(["allow": false, "reason": "This browser page is no longer open."], nil); return
        }
        let site = message.frameInfo.securityOrigin.host
        Task { @MainActor in
            let answer = await self.answer(kind: kind, tab: tab, site: site, relyingParty: body["rp"] as? String,
                                           errorName: body["error"] as? String)
            replyHandler(answer, nil)
        }
    }

    func answer(kind: String, tab: NativeBrowserTab, site: String, relyingParty: String? = nil, errorName: String? = nil) async -> [String: Any] {
        let capability = capabilities()
        var refusal: String?
        switch kind {
        case "webauthn", "webauthn-visible": refusal = capability.passkeyRefusal(relyingParty: relyingParty ?? site)
        case "location": refusal = capability.locationDelegate ? nil : NativeBrowserPageCapabilities.locationRefusal
        case "notification": refusal = NativeBrowserPageCapabilities.notificationRefusal
        case "popup-blocked": refusal = "The built-in browser could not open this page's pop-up. WebKit may require a click in the page; use the page's sign-in button again."
        case "error-webauthn": refusal = "The passkey or security-key request did not complete (\(safeError(errorName))). macOS may have refused the sheet or the person cancelled it. WebKit may need another click on the page's sign-in button; this does not prove the website failed."
        case "error-media": refusal = "The camera or microphone request did not complete (\(safeError(errorName))). Check this site's permission and macOS Privacy & Security."
        case "error-location": refusal = "The location request did not complete. Check this site's permission and macOS Location Services."
        case "request-finished":
            if let id = UUID(uuidString: relyingParty ?? "") { tab.pageRequests.finish(id) }
            return ["allow": true]
        default: return ["allow": false, "reason": "Unknown page request."]
        }
        if let refusal {
            tab.pageRequests.unavailable(kind: kind, reason: refusal, site: site)
            return ["allow": false, "reason": refusal]
        }
        // WebKit itself shows media/location permission delegates. WebAuthn has no UI delegate,
        // so hold the JS request here until the person reviews its tab before invoking macOS.
        if kind == "webauthn-visible" {
            let ticket = tab.pageRequests.showing(kind: "webauthn", message: "Answer this page's passkey or security-key sheet.", site: site)
            return ["allow": true, "ticket": ticket.uuidString]
        }
        if kind == "webauthn" {
            guard let ticket = await tab.pageRequests.wait(kind: kind, message: "This page asks for a passkey or security key.", site: site) else {
                return ["allow": false, "reason": "The page's passkey request ended before the person reviewed it."]
            }
            return ["allow": true, "ticket": ticket.uuidString]
        }
        return ["allow": true]
    }
    private func safeError(_ name: String?) -> String {
        let allowed = ["NotAllowedError", "NotSupportedError", "SecurityError", "AbortError", "InvalidStateError", "NotFoundError", "NotReadableError", "OverconstrainedError"]
        return name.flatMap { allowed.contains($0) ? $0 : nil } ?? "request refused"
    }
    private final class WeakController {
        weak var value: WKUserContentController?
        init(_ value: WKUserContentController) { self.value = value }
    }

    static let script = #"""
    (()=>{
      if (window.__tdPageRequestsInstalled) return;
      Object.defineProperty(window,'__tdPageRequestsInstalled',{value:true});
      const send = body => window.webkit.messageHandlers.tdPageRequests.postMessage(body);
      const gate = async body => { const a=await send(body); if(!a.allow) throw new DOMException(a.reason,'NotSupportedError'); return a; };
      const finish = a => a&&a.ticket ? send({kind:'request-finished',rp:a.ticket}) : Promise.resolve();
      if (navigator.credentials) for (const method of ['get','create']) {
        const original=navigator.credentials[method];
        if(typeof original!=='function') continue;
        navigator.credentials[method]=async function(options){
          if(!options||!options.publicKey) return original.call(this,options);
          const p=options.publicKey, rp=method==='get'?p.rpId:p.rp&&p.rp.id;
          const relyingParty=rp||location.hostname;
          const capable=/*TD_BROWSER_PASSKEYS*/false||/*TD_ASSOCIATED_DOMAINS*/[].includes('webcredentials:'+relyingParty);
          if(capable&&document.hasFocus()&&navigator.userActivation&&navigator.userActivation.isActive){
            // Preserve the real page click's user activation: no bridge await before the native API.
            const tracking=send({kind:'webauthn-visible',rp:relyingParty});
            try{return await original.call(this,options)}
            catch(e){await send({kind:'error-webauthn',error:e.name});throw e}
            finally{await finish(await tracking)}
          }
          const a=await gate({kind:'webauthn',rp:relyingParty});
          try {return await original.call(this,options)}
          catch(e){await send({kind:'error-webauthn',error:e.name});throw e}
          finally {await finish(a)}
        };
      }
      const denyNotifications=function(callback){
        return gate({kind:'notification'}).then(()=> 'default',()=>{if(callback)callback('denied');return 'denied'});
      };
      if(!window.Notification){
        class UnavailableNotification {
          constructor(){send({kind:'notification'});throw new DOMException('Website notifications are unavailable in this built-in browser.','NotSupportedError')}
          static get permission(){return 'denied'}
          static requestPermission(callback){return denyNotifications(callback)}
        }
        Object.defineProperty(window,'Notification',{value:UnavailableNotification,configurable:true});
      } else {
        Notification.requestPermission=function(callback){
          return gate({kind:'notification'}).then(()=> 'default',()=>{if(callback)callback('denied');return 'denied'});
        };
      }
      if(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia){
        const original=navigator.mediaDevices.getUserMedia;
        navigator.mediaDevices.getUserMedia=async function(c){
          try{return await original.call(this,c)}catch(e){await send({kind:'error-media',error:e.name});throw e}
        };
      }
      if(navigator.geolocation && !/*TD_LOCATION_NATIVE*/false) {
        let next=0;const cancelled=new Set();const clear=navigator.geolocation.clearWatch;
        for(const method of ['getCurrentPosition','watchPosition']) navigator.geolocation[method]=function(success,error){
          const id=++next;
          send({kind:'location'}).then(a=>{if(!cancelled.has(id)&&error)error({code:1,message:a.reason,PERMISSION_DENIED:1})});
          return method==='watchPosition'?id:undefined;
        };
        navigator.geolocation.clearWatch=function(id){cancelled.add(id);return clear.call(this,id)};
      }
      if(navigator.geolocation && /*TD_LOCATION_NATIVE*/false) for(const method of ['getCurrentPosition','watchPosition']){
        const original=navigator.geolocation[method];
        navigator.geolocation[method]=function(success,error,options){
          return original.call(this,success,e=>{send({kind:'error-location'});if(error)error(e)},options);
        };
      }
      const open=window.open;
      window.open=function(...args){const child=open.apply(this,args);if(!child&&!/(?:^|,)\s*(?:noopener|noreferrer)(?:[=,]|$)/i.test(String(args[2]||'')))send({kind:'popup-blocked'});return child};
    })();
    """#
}
