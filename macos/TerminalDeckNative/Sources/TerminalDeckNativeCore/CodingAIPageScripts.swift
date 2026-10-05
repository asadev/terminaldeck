import Foundation

/// The few things the native Coding AI screen has to say to the pages.
///
/// Three, and each is something the web section does inside its own page that
/// a native screen can only do by asking one:
///
///  - **The settings relay** (`terminaldeck:native-settings`, a BroadcastChannel
///    the main window listens on — `settings/native-settings.ts`). Sign in opens
///    a session there (`start-session`), and a saved setting is handed back
///    there (`changed`), exactly as the Settings page does.
///  - **"The account list changed"** (`deck:accounts-changed` on `window`), which
///    every account list in a page — the chip inside each session — re-reads on.
///  - **The page's own storage**, where the stale-CLI warnings somebody put away
///    are kept (`readiness.dismissed.v1`), so putting one away here puts it away
///    on the page too.
public enum CodingAIPageScripts {
    public static let relayChannel = "terminaldeck:native-settings"
    public static let accountsChangedEvent = "deck:accounts-changed"

    /// Post one message on the settings relay. Answers `true` when it was posted.
    public static func relay(_ message: CodingAIJSON) -> String {
        let channel = PageCommand.javaScriptString(relayChannel)
        let body = PageCommand.javaScriptString(message.jsonText)
        return "(function(){try{var c=new BroadcastChannel(\(channel));c.postMessage(JSON.parse(\(body)));setTimeout(function(){c.close()},2000);return true}catch(e){return false}})()"
    }

    /// `start-session`: what Sign in asks the main window to open.
    public static func startSessionMessage(profileId: String, provider: String?) -> CodingAIJSON {
        var message: [String: CodingAIJSON] = ["type": .string("start-session"), "profileId": .string(profileId)]
        if let provider { message["provider"] = .string(provider) }
        return .object(message)
    }

    /// Tell every account list in the page to read again.
    public static var announceAccountsChanged: String {
        "(function(){try{window.dispatchEvent(new CustomEvent(\(PageCommand.javaScriptString(accountsChangedEvent))));return true}catch(e){return false}})()"
    }

    /// Read one key of the page's localStorage (a string, or null).
    public static func readStorage(_ key: String) -> String {
        "(function(){try{return window.localStorage.getItem(\(PageCommand.javaScriptString(key)))}catch(e){return null}})()"
    }

    /// Write one key of the page's localStorage.
    public static func writeStorage(_ key: String, _ value: String) -> String {
        "(function(){try{window.localStorage.setItem(\(PageCommand.javaScriptString(key)),\(PageCommand.javaScriptString(value)));return true}catch(e){return false}})()"
    }
}

/// What a page asks of Settings → Coding AI when it opens the Settings window.
///
/// The account chip's **Add account** in a session opens Settings with
/// `{type: 'open-settings', section: 'agents', action: 'add-account'}`; the
/// native section answers by opening its Add-account sheet, as the web pane
/// opened its popup (`askForAddAccount`). `provider` is the agent already
/// chosen, when the request named one.
public struct CodingAISettingsRequest: Equatable, Sendable {
    public var provider: String?

    public static let addAccountAction = "add-account"

    /// The request in an `open-settings` message, or nil when it carries none.
    public static func parse(_ message: CodingAIJSON) -> CodingAISettingsRequest? {
        guard message["type"].string == "open-settings",
              message["action"].string == addAccountAction else { return nil }
        let provider = message["provider"].text
        return CodingAISettingsRequest(provider: CodingAICatalog.isProvider(provider) ? provider : nil)
    }
}
