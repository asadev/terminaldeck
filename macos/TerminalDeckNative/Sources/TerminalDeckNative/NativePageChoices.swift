import Foundation
import TerminalDeckNativeCore

/// Choices the hidden page used to keep in its own localStorage — the remembered effort, the
/// feature switches, the dismissed readiness and agent-update notices — kept in the app's
/// settings under the same keys, so they hold whether or not the page is loaded (#55, #70).
/// A value the page still holds is taken over once, the first time the app has none.
@MainActor
enum NativePageChoices {
    /// Swapped for a scratch store by checks.
    static var defaults = UserDefaults.standard
    /// Runs a script in a page (answering nil when it is not loaded); swapped for a fake page by checks.
    static var evaluate: @MainActor (String, NativeCodingAIPages.Page, (@MainActor (String?) -> Void)?) -> Void = { script, page, answer in
        _ = NativeCodingAIPages.evaluate(script, in: page, answer: answer)
    }

    static func read(_ key: String) -> String? { defaults.string(forKey: key) }

    /// Kept in the app; `mirror` also hands it to a page that still reads it (when that page is loaded).
    static func write(_ key: String, _ value: String, mirror page: NativeCodingAIPages.Page? = nil) {
        defaults.set(value, forKey: key)
        if let page { evaluate(CodingAIPageScripts.writeStorage(key, value), page, nil) }
    }

    /// The app's own value — at once when it has one; else the page's is taken over first (nil
    /// when neither has one). Every change reads through here, so two screens never overwrite each other.
    static func adopting(_ key: String, from page: NativeCodingAIPages.Page, _ done: @escaping @MainActor (String?) -> Void) {
        if let own = read(key) { done(own); return }
        evaluate(CodingAIPageScripts.readStorage(key), page) { value in
            if let value, read(key) == nil { defaults.set(value, forKey: key) }
            done(read(key))
        }
    }

    /// For a value still set on the page (the feature switches): the app's last copy at once,
    /// then the page's when it is loaded and says something new.
    static func following(_ key: String, from page: NativeCodingAIPages.Page, _ done: @escaping @MainActor (String?) -> Void) {
        done(read(key))
        evaluate(CodingAIPageScripts.readStorage(key), page) { value in
            guard let value, value != read(key) else { return }
            defaults.set(value, forKey: key)
            done(value)
        }
    }
}
