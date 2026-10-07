import Foundation
@testable import TerminalDeckBackend

/// A deterministic event clock. Tests await registration, never poll or sleep.
final class BackendDeckCoreTestPortSessionsManualClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private struct Entry { let at: Double; let order: Int; let run: @Sendable () -> Void }
    private let lock=NSLock()
    private var time=10_000.0, created=0
    private var pending:[UUID:Entry]=[:]
    private var waiters:[(Int,CheckedContinuation<Void,Never>)]=[]
    func now()->Double{lock.withLock{time}}
    var pendingCount:Int{lock.withLock{pending.count}}
    var scheduleCount:Int{lock.withLock{created}}
    func schedule(after milliseconds:Double,_ run:@escaping @Sendable()->Void)->UUID{
        let id=UUID()
        let ready=lock.withLock{()->[CheckedContinuation<Void,Never>] in
            created+=1;pending[id]=Entry(at:time+milliseconds,order:created,run:run)
            let ready=waiters.filter{$0.0<=created}.map{$0.1};waiters.removeAll{$0.0<=created};return ready
        }
        for waiter in ready{waiter.resume()};return id
    }
    func cancel(_ handle:UUID){lock.withLock{pending[handle]=nil}}
    func waitForScheduled(_ count:Int)async{
        await withCheckedContinuation{continuation in
            let ready=lock.withLock{()->Bool in
                if created>=count{return true};waiters.append((count,continuation));return false
            }
            if ready{continuation.resume()}
        }
    }
    func advance(_ milliseconds:Double){
        let ready=lock.withLock{()->[Entry] in
            time+=milliseconds
            let ready=pending.filter{$0.value.at<=time}.sorted{$0.value.at == $1.value.at ? $0.value.order<$1.value.order : $0.value.at<$1.value.at}
            for entry in ready{pending[entry.key]=nil};return ready.map(\.value)
        }
        for entry in ready{entry.run()}
    }
}
