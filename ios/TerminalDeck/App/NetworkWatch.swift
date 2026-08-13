/**
 * Reconnect when the network changes, rather than when the backoff says so.
 *
 * A phone loses this connection constantly and for reasons that have nothing to
 * do with the desktop: wifi to cellular in a doorway, a tunnel re-keying, a lift.
 * The backoff exists for the case where nothing is known, and it is deliberately
 * slow at the top end — up to twenty seconds. Twenty seconds of a dead terminal
 * after the wifi came back is the difference between an app someone keeps and
 * one they delete.
 *
 * `NWPathMonitor` says when the route changed. That is not the same as saying
 * the desktop is reachable, so this does not report a connection — it only tells
 * the transport that the thing its backoff was waiting out has ended, and the
 * transport tries immediately.
 *
 * ## Why a change, not a state
 *
 * The interesting event is *becoming* satisfied, and also switching interface
 * while remaining satisfied: a socket bound to the old wifi route is dead
 * whether or not the phone still has a network. Firing on every meaningful
 * transition and letting `resume()` be idempotent is simpler and misses less
 * than trying to be clever about which transition mattered.
 */

import Foundation
import Network

@MainActor
final class NetworkWatch {

    /// Called when the route changed in a way that makes retrying worthwhile.
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var last: (satisfied: Bool, interface: NWInterface.InterfaceType?)?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interface: NWInterface.InterfaceType? = [.wifi, .cellular, .wiredEthernet]
                .first { path.usesInterfaceType($0) }
            Task { @MainActor [weak self] in
                self?.consider(satisfied: satisfied, interface: interface)
            }
        }
        monitor.start(queue: DispatchQueue(label: "\(Brand.id).network"))
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    private func consider(satisfied: Bool, interface: NWInterface.InterfaceType?) {
        defer { last = (satisfied, interface) }
        guard let last else {
            // The first callback is the current state, not a change. Acting on
            // it would fire a reconnect on every launch, half a second after
            // the one `start()` already did.
            return
        }
        guard satisfied else { return }
        if !last.satisfied || last.interface != interface {
            onChange?()
        }
    }
}
