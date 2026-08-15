/**
 * Putting an alert on the lock screen, and the two settings that gate it.
 *
 * `SessionAlerts` decides *that* something happened. This decides what iOS is
 * told about it, asks for permission at the one moment a person has said they
 * want it, and routes a tap back to the session it was about.
 *
 * ## Sound only for the one that is asking
 *
 * A session that wants you makes a sound, because that is the whole point of
 * being told: an agent has stopped mid-task and every minute after that is
 * wasted. A session that has *finished* arrives silently — it is worth seeing
 * next time you look at the phone and it is not worth a buzz, and an app that
 * buzzes for both is one people turn off entirely inside a week, which loses
 * them the alert that mattered.
 *
 * ## No badge
 *
 * Deliberately. A badge would have to be a number about the machines, and this
 * app cannot keep one true: the moment iOS suspends it the sessions carry on
 * changing and nothing here is running to notice. A red "2" that means "two
 * sessions needed you at some point before lunch" is a lie in a place people
 * trust, and there is no push service behind this product to make it honest.
 * The notifications themselves are timestamped and are not.
 *
 * ## Permission is asked when it is chosen, never at launch
 *
 * The system prompt is one question and it can only be asked once. Asking it in
 * the first three seconds of the first launch — before the phone has been paired
 * with anything, when there is nothing to be notified about — is how it gets
 * refused. It is asked from `AlertsView`, which is reached by somebody who has
 * gone looking for it.
 */

import Foundation
import UIKit
import UserNotifications

/// What iOS says about this app's notifications.
enum AlertPermission: Equatable {
    /// Nobody has been asked yet. The only state from which asking is possible.
    case notAsked
    case allowed
    case denied
    /// Provisional, ephemeral, or a state a later iOS invented. Treated as
    /// allowed for the purpose of posting — the system will do whatever it does
    /// — but never reported to the user as a plain yes.
    case other
}

/// What the person has switched on. Separate from the permission, because they
/// answer different questions: iOS says whether this app *may* interrupt, and
/// these say whether it *should*.
enum AlertSettings {
    private static let needsYouKey = "terminaldeck.alerts.needsYou.v1"
    private static let finishedKey = "terminaldeck.alerts.finished.v1"

    /// Both default to on. The permission prompt is the real gate — nothing can
    /// be delivered until somebody says yes to that — so defaulting these off
    /// would mean two switches to reach the feature and a person who granted
    /// permission and then received nothing.
    static var needsYou: Bool {
        get { UserDefaults.standard.object(forKey: needsYouKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: needsYouKey) }
    }

    static var finished: Bool {
        get { UserDefaults.standard.object(forKey: finishedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: finishedKey) }
    }

    static func wants(_ kind: SessionAlert.Kind) -> Bool {
        switch kind {
        case .needsYou: return needsYou
        case .finished: return finished
        }
    }
}

/**
 * The seam.
 *
 * `DeckModel` holds one of these and never names `UNUserNotificationCenter`,
 * which is what lets the routing rules — what is suppressed, what is summarised,
 * what is posted — be tested without a simulator asking anybody for permission.
 */
@MainActor
protocol AlertPresenting: AnyObject {
    func permission() async -> AlertPermission
    /// Ask iOS. Only meaningful from `.notAsked`; from anywhere else it reports
    /// the state that is already settled.
    func request() async -> AlertPermission
    func present(_ alert: SessionAlert)
}

@MainActor
final class NotificationAlerts: AlertPresenting {

    private let center = UNUserNotificationCenter.current()

    func permission() async -> AlertPermission {
        Self.permission(from: await center.notificationSettings().authorizationStatus)
    }

    func request() async -> AlertPermission {
        let current = await permission()
        guard current == .notAsked else { return current }
        // `.alert` and `.sound` only. No badge is requested because none is set
        // — asking for a permission the app does not use is how a settings
        // screen ends up with a switch that does nothing.
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        // Read back rather than trusted: the return value says what the person
        // tapped, and the settings say what the system actually holds — which
        // differ under a device management profile.
        _ = granted
        return await permission()
    }

    func present(_ alert: SessionAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = alert.thread
        content.userInfo = [NotificationRouter.hostKey: alert.hostId,
                            NotificationRouter.sessionKey: alert.sessionId]
        if alert.kind == .needsYou {
            content.sound = .default
            // The one level above the default that does not require an
            // entitlement. It lets a "waiting for you" through a Focus the
            // person has allowed this app in, which is exactly the situation the
            // feature exists for.
            content.interruptionLevel = .timeSensitive
        }

        // `trigger: nil` — deliver now. Everything here is a thing that has
        // already happened; scheduling it would be describing the past in the
        // future tense.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }

    private static func permission(from status: UNAuthorizationStatus) -> AlertPermission {
        switch status {
        case .notDetermined: return .notAsked
        case .denied: return .denied
        case .authorized: return .allowed
        default: return .other
        }
    }
}

/**
 * A tapped notification, on its way to the session it was about.
 *
 * A singleton with a closure rather than a reference to the model, for one
 * reason: the object that receives the tap is the `UIApplicationDelegate`, which
 * iOS builds, and the model is built by SwiftUI in a `@State`. Neither can name
 * the other.
 *
 * ## Why it holds a pending tap
 *
 * A notification tapped while the app is **not running** launches the app, and
 * the delegate is handed the response during launch — before the root view's
 * `task` has run and wired `open`. Without somewhere to put it, that tap opens
 * the app on the session list and the person is left wondering which machine was
 * asking. So it is kept and delivered the moment the wiring appears.
 */
@MainActor
final class NotificationRouter {
    static let shared = NotificationRouter()

    static let hostKey = "host"
    static let sessionKey = "session"

    /// Set by the root view once the model exists.
    var open: ((String, String) -> Void)? {
        didSet { drain() }
    }

    private var pending: (host: String, session: String)?

    private init() {}

    /// Called from the notification delegate. Ids are checked before they are
    /// acted on: the payload is this app's own, but it has been round-tripped
    /// through the system and `DeckModel.open` refuses a malformed id anyway.
    func deliver(userInfo: [AnyHashable: Any]) {
        guard let host = userInfo[Self.hostKey] as? String,
              let session = userInfo[Self.sessionKey] as? String,
              !host.isEmpty, SessionID.isValid(session) else { return }
        if let open {
            open(host, session)
        } else {
            pending = (host, session)
        }
    }

    private func drain() {
        guard let pending, let open else { return }
        self.pending = nil
        open(pending.host, pending.session)
    }
}

/**
 * The delegate, and the only reason there is an app delegate in this app at all.
 *
 * `UNUserNotificationCenter.delegate` has to be set **before the app finishes
 * launching** or a tap that launched the app is delivered to nobody. A SwiftUI
 * `.task` runs after that point, so this is the one thing that cannot live in
 * the scene.
 */
final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// A notification that arrives while the app is on screen still shows.
    ///
    /// The alternative — silence in the foreground, which is the SwiftUI default
    /// — would be wrong here: this app is very often open on *one* machine's
    /// session while a *different* machine's session is the one that needs
    /// somebody. `.sound` is in the list so that the content decides whether to
    /// make one, which is where that decision belongs.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run { NotificationRouter.shared.deliver(userInfo: userInfo) }
    }
}
