import Foundation

/// An AI's tool call never moves the person (Asad, 31 Oct and again 13 Nov 2026: "if I am in any other session or
/// any other page … and any session wants to use any simulator or any browser … it takes me to there … it should
/// not be happening").
///
/// When a session, an agent or Hoot uses a phone (the devices tools, simulators_open) or a browser tab (the browser
/// tools), the app does not change which session, tab or pane is selected, which page shows, which window is key or
/// in front, or where the keyboard is. The phone panel or the tab is attached and live in the background; the person
/// finds it there when he opens that session himself. A small mark on the session's row says it is using a phone or
/// a browser, and a raised hand when a tool hands a page over to him (browser_handover).
///
/// NativeFrontPolicy keeps windows from coming forward; this keeps the app's own view still. Its test holds every
/// source file on a tool path (`toolPathPrefixes`) to `navigationCalls`: a call there is allowed only on a line that
/// names why it is the person's own action (`person-ok:`) or why it gives the person's place straight back
/// (`background-ok:`).
public enum NativeBackgroundToolsPolicy {
    /// Source files whose code a devices or browser tool reaches (a new file with one of these names is covered at once).
    public static let toolPathPrefixes = ["NativeSafari", "BrowserDriver", "BackendBrowserService", "BackendBrowserRuntime",
        "BackendANDROIDPhone", "BackendDeckToolsMachinesDevices", "BackendUIGSessionSimulator", "BackendFIXESSimulator",
        "BackendAppDevice", "NativeDeviceDirect", "NativeCompositionPhoneDevices", "NativeFIXESDeviceContextMenu"]

    /// Calls that move the person: a selection, a page, a window, the keyboard.
    public static let navigationCalls = ["selectTab(", "AppModel.shared.select(", "openScreenWindow(", "requestSettings(",
        "selectSettingsSection(", "openHootPage(", "showSettings(", "movePageToWindow(", "runButton(.select", "runButton(.focusPane",
        "onSelect?(", "showForPerson(", "makeFirstResponder(", "activateFileViewerSelecting(", "NSWorkspace.shared.open("]
        + NativeFrontPolicy.raisingCalls

    /// MAC-NEXT-14 (Asad, 14 Nov 00:59: an AI's typing appeared in the session he was typing in). Calls that put
    /// input through AppKit's keyboard: a first responder change, a synthesised key event, text inserted into a
    /// view, an event handed to the app. On a tool path NO marker excuses them: AppKit gives every key event to the
    /// key window's first responder (his terminal, his field), and WebKit hands back to the app the keys a page did
    /// not take. A tool types at page level (BrowserDriverScripts.scriptedInput) or through its device's own input
    /// helper, never through the app's keyboard.
    public static let keyboardCalls = ["makeFirstResponder(", "NSEvent.keyEvent(", ".keyDown(with:", ".keyUp(with:",
        "insertText(", "performKeyEquivalent(with:", "sendEvent(", "postEvent(", "CGEvent(keyboardEventSource:", "NSTextInputContext"]
    public static func keyboard(in code: String) -> [String] { keyboardCalls.filter { code.contains($0) } }

    /// MAC-NEXT-15b: his clipboard is never read or written by a tool. Calls that reach the Mac's pasteboard (or a
    /// simulator's, which Apple's Simulator app can copy to the Mac's). On a tool path each is named in the rule test
    /// with why it is his own action or never reaches his clipboard.
    public static let pasteboardCalls = ["NSPasteboard", "UIPasteboard", "generalPasteboard", "pbcopy", "pbpaste"]
    public static func pasteboard(in code: String) -> [String] { pasteboardCalls.filter { code.contains($0) } }

    /// B3 (MAC-NEXT-13): a tool parking a page silences it only when an AI opened it in the background and the person
    /// never had it in one of his windows; a page he left playing sound in a tab he is not looking at keeps playing.
    public static func silencesParkedPage(shownToPerson: Bool, inWindow: Bool) -> Bool { !inWindow && !shownToPerson }

    /// Any file that registers a tool is on a tool path too (13 Nov, second round: "anything it is controlling").
    public static let toolRegistrationMarkers = ["BackendMCPTool(", "BackendDeckToolsDefinition(", "mcpPolicy(", "BackendMCPToolSpec("]
    public static func isToolFile(_ fileName: String, source: String) -> Bool {
        fileName != "NativeBackgroundToolsPolicy.swift" && (isToolPath(fileName) || toolRegistrationMarkers.contains { source.contains($0) })
    }

    /// The explicit window tools (window_buttons select/select-tab, the session dock, page-to-window, open a profile
    /// or task, a device panel's show:true, ui.do focus/settings) exist to move the view when someone asks Hoot to.
    /// Kept as they are: nothing a tool call carries says whether the person asked for this move just now. `attended`
    /// only says the run's config is the watched one (a chat he can see), not that he asked; a turn's first message
    /// is his, but every later call in that turn is the AI's own choice. So they are named, not gated.

    public static let personMarker = "person-ok:"
    public static let backgroundMarker = "background-ok:"
    public static let windowToolMarker = "window-tool-ok:"
    public static let markers = [personMarker, backgroundMarker, windowToolMarker]

    public static func isToolPath(_ fileName: String) -> Bool { toolPathPrefixes.contains { fileName.hasPrefix($0) } }

    /// The navigation calls on one line of code (comments taken out by the caller).
    public static func navigation(in code: String) -> [String] { navigationCalls.filter { code.contains($0) } }

    /// The quiet marks at the end of a session's row, in drawn order: the raised hand first (a page waits for him),
    /// then a phone, then a browser. Empty when no tool works for that session.
    public enum Mark: String, Equatable, Sendable, CaseIterable {
        case handover, phone, browser
        /// SF Symbol, drawn the way the row's other small marks are (StatusMark: caption, secondary; the hand orange).
        public var symbol: String {
            switch self { case .handover: "hand.raised.fill"; case .phone: "iphone"; case .browser: "globe" }
        }
        public var words: String {
            switch self {
            case .handover: "A browser page is waiting for you in this session: click the row to open it"
            case .phone: "This session is using a phone"
            case .browser: "This session is using a browser tab"
            }
        }
    }
    public static func marks(phone: Bool, browser: Bool, handover: Bool) -> [Mark] {
        var marks: [Mark] = []
        if handover { marks.append(.handover) }
        if phone { marks.append(.phone) }
        if browser && !handover { marks.append(.browser) }
        return marks
    }
}
