/**
 * THE ONLY PLACE THE PRODUCT NAME LIVES IN THIS TARGET.
 *
 * The desktop has `src/shared/brand.ts` and the same rule; Swift cannot import
 * TypeScript, so this is its mirror rather than its second copy. Renaming the
 * app means changing the values here and then the places that cannot import
 * Swift:
 *   - `Support/Info.plist`     -> CFBundleDisplayName, the URL scheme
 *   - `project.yml`            -> target name, PRODUCT_BUNDLE_IDENTIFIER
 *   - `ios/README.md`
 * No view, no model and no test spells the name out.
 */

import Foundation

enum Brand {
    /// Display name, shown in the navigation bar and on the home screen.
    static let name = "Terminal Deck"

    /// Lowercase slug. Also the URL scheme the desktop opens a session with.
    static let id = "terminaldeck"

    /*
     * There was a `tagline` here — "Run your coding agents on one deck" — and it
     * had exactly one reader, the session list's empty state. That sentence has
     * been replaced by one that says something true about *this* screen: the list
     * only ever holds sessions this product started, so a Claude running in
     * Terminal.app is missing from it by design rather than by failure. A brand
     * constant with no reader is a constant whose comment starts lying about
     * where it is used, so it went with the copy that used it.
     */

    /// Read rather than restated: `project.yml` already has to declare it, and
    /// a constant here would be a second copy that can disagree with the bundle
    /// the code is actually running inside.
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "0"
    }
}
