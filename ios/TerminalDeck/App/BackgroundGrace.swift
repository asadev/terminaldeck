/**
 * The half-minute after the phone goes in a pocket.
 *
 * iOS suspends an app shortly after it leaves the screen: the run loop stops,
 * the sockets stop being read, and nothing this app has noticed since is
 * noticed. For a terminal client that is exactly the wrong moment to stop
 * listening — you put the phone down *because* something is running.
 *
 * `beginBackgroundTask` buys the standard grace period, which iOS currently
 * settles at around thirty seconds. That is not a lot and it is worth having:
 * the most common shape of "I am waiting for this" is a command that finishes
 * within a few seconds of you looking away, and in that window the socket is
 * still up, the heartbeat is still ticking and `SessionAlerts` still fires.
 *
 * ## What it is not
 *
 * It is not a way to stay connected. When the grace expires the app is suspended
 * whatever this class does — `expirationHandler` is iOS saying "now, or I kill
 * you" — and the honest thing is to let go. Anything that happened afterwards is
 * caught up on the next connection and reported as a summary rather than
 * pretended to be live. See `SessionAlerts` and `AlertsView`, which says so on
 * screen.
 *
 * There is no `UIBackgroundModes` in this app's Info.plist and there must not
 * be: none of the declared modes describes what this does. `audio` and
 * `location` are the two people reach for to keep a socket alive, both are a lie
 * about what the app is doing, and both are rejected by review when they are
 * one.
 */

import UIKit

@MainActor
final class BackgroundGrace {

    private var identifier: UIBackgroundTaskIdentifier = .invalid

    /// Whether the assertion is held. Read by the tests, which is the only way
    /// to check this from outside — the system does not report it back.
    var isHeld: Bool { identifier != .invalid }

    /**
     * Ask for the grace period.
     *
     * Idempotent: a second scene phase change while one is held would otherwise
     * leak the first assertion, and a leaked assertion is not harmless — iOS
     * kills an app that is still holding one when the time runs out.
     */
    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "keep listening") { [weak self] in
            // The system's warning, delivered on the main thread. Ending it here
            // is what turns "you are about to be killed" into an ordinary
            // suspension.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
