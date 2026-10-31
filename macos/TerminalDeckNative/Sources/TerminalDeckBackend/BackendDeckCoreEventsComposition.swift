import Foundation
import TerminalDeckNativeCore

/// Source index.ts notification wiring packaged into one explicit owner graph.
/// Construction stays inert; make() is called only after the old writer stops.
public struct BackendDeckCoreEventsComposition: Sendable {
    public let hub: BackendDeckCoreEventsHub
    public let events: BackendDeckCoreEvents
    public let detector: BackendDeckCoreEventsDetector
    public static func make(directory: URL?, keys: BackendDeckCoreSecurityAccessKeys,
                            surface: any BackendDeckCoreEventsDetectionSurface,
                            starterOf: @escaping @Sendable (String) async -> String?,
                            clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock(),
                            callbackPost: @escaping BackendDeckCoreEventsCallbackPost = BackendDeckCoreEventsCallback.post,
                            webhookPost: @escaping BackendDeckCoreEventsWebhookPost = BackendDeckCoreEventsCallback.webhookPost,
                            onChange: @escaping @Sendable () -> Void = {}, report: @escaping @Sendable (String) -> Void = { _ in }) async -> Self {
        let hub = BackendDeckCoreEventsHub(directory:directory,settings:{ await keys.notifySettings(id:$0) },clock:clock,post:webhookPost,onChange:onChange,report:report)
        let events = BackendDeckCoreEvents(directory:directory,mode:{ await keys.notifySettings(id:$0)?["mode"].string },internet:{ await keys.internet() },clock:clock,post:callbackPost,onDelivered:{ key,event in _ = await hub.deliveredBy(keyId:key,id:event,via:"event") },owed:{ await hub.owes(keyId:$0,id:$1) },onChange:onChange,report:report)
        await hub.setPushing { await events.owes(keyId:$0,eventId:$1) }
        await hub.load(); await events.load()
        let detector = BackendDeckCoreEventsDetector(surface:surface,starterOf:starterOf,enqueue:{ key,event,turn in
            guard await hub.enqueue(keyId:key,event:event,turn:turn) else { return false }
            _ = await events.offer(keyId:key,event:event); return true
        },clock:clock,report:report)
        return Self(hub:hub,events:events,detector:detector)
    }
    public func reconcile() async { await hub.reconcile(); await events.reconcile() }
    public func stop() async { await detector.stop(); await events.stop(); await hub.stop() }
}
