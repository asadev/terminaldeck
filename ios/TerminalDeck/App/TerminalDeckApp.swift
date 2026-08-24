/**
 * The composition root: the four objects the app is made of, and who owns whom.
 *
 * The credential store is created here and handed to the model, which hands it
 * to every transport it builds. That is deliberate — the store holds the device
 * key as well as the credential, and a second instance would generate a second
 * identity and turn a paired phone into a stranger on the next launch.
 *
 * ## Two reasons to retry, both wired here
 *
 * Coming back from the background is the moment a stale backoff is describing a
 * network condition that has already ended. A route change is the same thing
 * arriving from the other direction, and it happens while the app is in front of
 * the user, where twenty seconds of a dead terminal is very visible.
 */

import SwiftUI

@main
struct TerminalDeckApp: App {
    /**
     * The delegate exists for one thing: `UNUserNotificationCenter.delegate`
     * has to be set before launch finishes, or a notification that *launched*
     * the app is delivered to nobody. A SwiftUI `task` runs after that moment.
     * See `NotificationDelegate`.
     */
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var delegate

    @State private var model = Composition.model()
    @State private var network = NetworkWatch()
    @State private var grace = BackgroundGrace()

    /**
     * The lock on the front door, owned here because it is older than any
     * screen: a fresh process is a locked process, and `AppLock`'s initialiser
     * is what decides that. Created before the first body is evaluated, so there
     * is no frame in which the session list is on screen before the lock is.
     */
    @State private var lock = AppLock()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                // Above the sheets, above the snapshot. See `AppLockShield`.
                .appLock(lock)
                // Read by the one row that changes it, on the main Settings page.
                .environment(lock)
                .task {
                    model.start()
                    network.onChange = { model.resume() }
                    network.start()
                    // A tap that arrived during launch is held until this line;
                    // setting it delivers it.
                    NotificationRouter.shared.open = { host, session in
                        model.open(session: session, on: host)
                    }
                    await model.refreshAlertPermission()
                }
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.isForeground = true
                // Before anything else this line does: whether five minutes have
                // passed is a question about the moment the app came back, not
                // about the moment a refresh finished.
                lock.becameActive()
                // The assertion is released the moment the app is back: holding
                // one that is not needed is how an app is killed for still
                // holding it when the time runs out.
                grace.end()
                model.resume()
                // Permission can be changed in Settings while this app is not
                // running, so it is re-read rather than remembered.
                Task { await model.refreshAlertPermission() }
            case .background:
                model.isForeground = false
                // The lock's clock starts here and nowhere else — the biometric
                // sheet makes this app *inactive*, never backgrounded, which is
                // exactly why the grace is measured from this phase.
                lock.wentToBackground()
                // Keep listening for as long as iOS allows. This is what makes
                // an alert possible at all in the minute after the phone goes
                // into a pocket — which is the minute people care about.
                grace.begin()
            case .inactive:
                // The notification-centre pull-down and the app switcher both
                // land here and neither is leaving, so nothing about the
                // connection changes. The lock still wants to know: this is the
                // moment before iOS takes the app-switcher snapshot, and with
                // the lock on that snapshot must not be somebody's terminal.
                lock.wentInactive()
            @unknown default:
                break
            }
        }
    }
}

@MainActor
enum Composition {
    static func model() -> DeckModel {
        DeckModel(credentials: KeychainCredentialStore(), device: DeviceIdentity.describe())
    }

}
