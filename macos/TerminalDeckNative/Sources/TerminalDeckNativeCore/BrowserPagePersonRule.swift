import Foundation

/// MAC-NEXT-15 (Asad, 14 Nov: "things are leaking between them … I told you many many times"). What a page may do
/// to the person while an AI's tool drives it: never take his keyboard, never move him, never put anything over his
/// work. A page's own requests (alert/confirm/prompt, the Mac's file chooser, a new window) are answered here by who
/// is acting on the page right now, not by which window the page happens to sit in.
public enum BrowserPagePersonRule {
    /// A tool's input or navigation on a page (a click, typing, a key, a navigation, an upload, a scripted action;
    /// never a read, a screenshot or a state query) counts as "a tool is driving it" for this long, unless the person's
    /// own click or key in that page came after it. Long enough to cover what the page does in answer to a step (a
    /// dialog, a popup, a chooser arrives a moment after the click); short enough that a page an AI used earlier is
    /// his again once he works in it.
    public static let toolWindowSeconds: Double = 20

    /// Whether a tool is driving the page now. Times are one steady clock (seconds).
    public static func toolDriving(toolAt: Double?, personAt: Double?, now: Double) -> Bool {
        guard let toolAt, now - toolAt < toolWindowSeconds, now >= toolAt else { return false }
        guard let personAt else { return true }
        return personAt < toolAt
    }

    /// Who answers a page's alert / confirm / prompt (and its camera question and site sign-in).
    /// MAC-NEXT-15b (Asad: "regular workflow has more importance than the special cases"): only a page a tool drives
    /// is answered silently. His own pages behave as they always did; nothing of his is ever cancelled for him.
    public enum DialogRoute: Equatable, Sendable {
        /// An agent set a standing answer for this tab (browser_page dialogs): used, as before.
        case standing
        /// A tool drives the page: answered at once without showing anything (alert dismissed, confirm and prompt
        /// cancelled), its text reported to the AI in the step's result.
        case tool
        /// He is on the page (it holds his key window's keyboard): shown on its window, as before.
        case person
        /// He is not on the page (another tab, another window, his keyboard elsewhere): held, never cancelled, and
        /// shown when he comes back to it. Nothing goes over his other work meanwhile. If a tool starts driving that
        /// page while it waits, it is answered for the tool then (as `.tool`), so the tool's step is not blocked
        /// behind it (MAC-NEXT-15c).
        case hold
    }

    /// MAC-NEXT-15c: a page an AI opened in the background and the person has never been shown (`shownToPerson`
    /// false) is not his: nobody would ever come back to answer it, and a held question there would stall every later
    /// step of that AI. So it is answered at once like a driven page, however long since the AI's last step.
    public static func dialogRoute(standingAnswer: Bool, toolDriving: Bool, personOnPage: Bool, shownToPerson: Bool) -> DialogRoute {
        if standingAnswer { return .standing }
        if toolDriving || !shownToPerson { return .tool }
        return personOnPage ? .person : .hold
    }

    /// The Mac's file chooser never opens for a page a tool drives (its files go in through the upload step; armed
    /// files are answered before this is asked). His own page opens it as before, when it is on screen.
    public static func fileChooserOpens(toolDriving: Bool, onScreen: Bool) -> Bool { !toolDriving && onScreen }

    /// A new window a page opens (window.open, target=_blank, ⌘-click) becomes a tab; it is selected and shown only
    /// when the person asked for that himself, never when a tool's click opened it.
    public static func newTabShows(personAskedToShow: Bool, toolDriving: Bool) -> Bool { personAskedToShow && !toolDriving }

    /// The driver's own scripts that act on a page (input, not reading): running one is a tool driving the page.
    public static let actingScripts: Set<String> = ["scriptedInput", "domAction", "focusAndSelect", "select", "files"]

    /// What the tool is told when a page it drives tried to open the Mac's file chooser.
    /// What a tool is told when it asks to print: the page goes to a PDF file, never the print sheet on his window.
    public static let printNote = "The page was saved as a PDF file instead of opening the print sheet (that would cover the person's window)."

    public static let fileChooserRefusal = "the page tried to open the Mac's file chooser. It was not opened (it would have covered the person's window). Hand files to that field with an upload step: verb \"upload\", the field's selector, and files: [full paths]."
}
