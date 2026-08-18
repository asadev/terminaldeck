/**
 * Light, dark, or whatever the phone is set to.
 *
 * Asad: *"mobile iOS is only dark mode — it should have both, in settings."*
 *
 * ## Three choices, and System is the default
 *
 * Because a phone already has this setting, at the top of Control Centre and on
 * a schedule, and an app that ignores it is an app that comes up white at
 * midnight. Honouring the system is what people expect; the other two exist
 * because a terminal is a thing some people want dark on a bright desk and some
 * want light on a dim one, and neither of them is wrong.
 *
 * `system` is `nil` rather than a third painted value — see `colorScheme`. That
 * is the difference between *following* the phone and *guessing what the phone
 * currently says*: a preference resolved once to `.light` at launch would stop
 * tracking the moment the phone crossed into its dark schedule with the app
 * open, which is the case this setting exists to serve.
 *
 * ## Where it is applied, and where it is not
 *
 * **Once, at the root.** `RootView` reads this and states it for the whole
 * window. Nothing else in the app may state a colour scheme, and that rule is
 * the change rather than a tidiness: this app had eleven
 * `.preferredColorScheme(.dark)` calls scattered over the screens and every one
 * of them was an override that would have silently ignored this setting for that
 * screen. `AppearanceRuleTests` walks the source and fails if one comes back.
 *
 * Above the app there was a third pin, and it was the one that mattered most:
 * `UIUserInterfaceStyle = Dark` in `Support/Info.plist`. That is the operating
 * system's own override — it forces every window in the process dark before any
 * view is asked, so while it was there this whole file would have had no effect
 * whatsoever. It is gone.
 *
 * ## Why `UserDefaults` and not the Keychain
 *
 * It is a preference, not a secret, and it must survive a relaunch — which
 * `UserDefaults` does by writing it out itself. Same shape as `TextSize`, which
 * is the other setting that belongs to the phone rather than to a machine, and
 * deliberately so: two settings stores is how two settings stop behaving the
 * same way.
 */

import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    /// Follow the phone. The default, and the only one that keeps tracking.
    case system
    case light
    case dark

    var id: String { rawValue }

    /**
     * The defaults key.
     *
     * Public because `@AppStorage` needs the literal at each use site and two
     * screens read it — the root, which paints it, and Settings, which changes
     * it. A second spelling of this string is a setting that appears to save and
     * comes back on the next launch as the default.
     *
     * `.v1` because a stored preference outlives the build that wrote it: if
     * the cases ever change meaning, the key changes with them rather than a new
     * build inheriting a value that means something else.
     */
    static let key = "terminaldeck.appearance.v1"

    /**
     * What SwiftUI is told.
     *
     * `nil` for `system`, and that is the whole of "follow the phone":
     * `.preferredColorScheme(nil)` states no preference, so the window inherits
     * the trait collection iOS gives it and keeps inheriting it as that changes.
     */
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// What the control reads. Sentence case, like every other value in
    /// Settings.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /**
     * The stored preference.
     *
     * Falls back to `system` on anything unexpected — an absent key on a fresh
     * install, and a value written by a build whose cases were different. A
     * preference read off disk is input, and the failure to design for is a
     * phone that comes up in a scheme nobody chose.
     *
     * The store is a parameter so the tests can use a suite of their own rather
     * than writing into the preferences of whatever simulator they run on.
     */
    static func stored(in defaults: UserDefaults = .standard) -> Appearance {
        guard let raw = defaults.string(forKey: key), let value = Appearance(rawValue: raw) else {
            return .system
        }
        return value
    }

    static func save(_ appearance: Appearance, in defaults: UserDefaults = .standard) {
        defaults.set(appearance.rawValue, forKey: key)
    }
}
