/**
 * The click-flow recorder, for a page **this phone** is holding open.
 *
 * > *"you are giving record flow button in the windows side the server side it
 * > and you are not giving that into the if they are browsing locally in this
 * > machine. So there are so many differences if they both are capable for a
 * > feature why don't they both have."*
 *
 * ## The reason this was left out last round, and why it was the wrong reason
 *
 * `MachineBrowserWire`'s header says it plainly: a flow recorded in this phone's
 * web view is *"a recording of a page nothing on the machine ever loaded"*. That
 * is true of a **screenshot** — a picture of a phone is not a picture of the
 * machine — and it is true of **binding to a session**, because a session cannot
 * reach a socket bound on this phone's loopback.
 *
 * It was never true of a click flow, and he caught it. A recorded flow is not
 * pixels and it is not a handle to a window: it is a **list of sentences** —
 * *Go to localhost:3000/admin; Click "Sign in" (`#submit`); Type "asad@…" into
 * `#email`* — and every one of those sentences is about the site's own DOM. The
 * site is the machine's; the same route, the same selectors, the same form. An
 * agent handed that flow acts on the code that serves it, and it does not matter
 * one bit which browser the finger was in when the flow was written down.
 *
 * The machine's own recorder exists because the machine's browser is watched
 * through **pixels**: `MachineWindowView` sends a tap and receives a picture, so
 * there is no DOM on this side to listen to and the listening has to happen over
 * there. This screen is the opposite — the `WKWebView` *is* here — so recording
 * clicks is a script and a list, which is what this file is.
 *
 * ## One vocabulary, two recorders
 *
 * The rows Lane N's card draws are `RecordedStep`, the **same type** the
 * machine's steps arrive in (`Protocol/MachineBrowserWire.swift`), and this file
 * is a transcription of `src/main/browser-steps.ts` so that the two lists say the
 * same thing about the same click:
 *
 *  - `kind` is one of the seven words that file names — `navigate`, `click`,
 *    `type`, `select`, `check`, `press`, `submit` — plus `truncated` for the row
 *    that says a flow was cut, which is `TRUNCATED` in
 *    `src/main/remote/browser-control.ts`;
 *  - `detail` is `describeStep`'s sentence, **not** a second rendering of the
 *    same facts. That file's own comment is the argument and it is worth keeping
 *    in front of anybody editing this one: three spellings of *Click "Sign in"
 *    (`#submit`)* is how one of them comes to leak a password the other two
 *    redact;
 *  - `value` is dropped outright when the step was redacted, exactly as
 *    `wireStep` drops it, and for the same reason — *a field that carries a
 *    one-time-code in clear is not made safe by being short*.
 *
 * If this and `browser-steps.ts` ever disagree, the TypeScript is right and this
 * is the bug.
 *
 * ## A password's value is never recorded, on both sides of the check
 *
 * The page-side script refuses to send it (`PhoneRecordScript`), and this side
 * refuses to keep it even if a payload arrives with the flag stripped off — the
 * element's own `type` attribute is checked here, independently, which is the
 * same two-sided arrangement `parseGuestStep` describes. A `file` input counts
 * with `password`: its value is a path on somebody's own device and it names
 * them before it names anything else.
 *
 * A `WKScriptMessageHandler` is reachable from any script in the world it is
 * registered in, so *"the payload came from our script"* is not a fact this side
 * may assume — the same rule `Inspect.parseCapture` is written under, which is
 * why every payload goes through it before a step is made of it.
 *
 * ## What is deliberately **not** here
 *
 * A per-step screenshot, a replay button, an export format of its own. *"Record
 * what the machine's recorder records and nothing more"* — the machine collects
 * seven kinds of step and nothing else, and a recorder on this side that
 * collected an eighth would be the very drift he has now complained about twice.
 */

import Foundation
import Observation

/**
 * Every recording this phone is holding, keyed by `BrowserTab.id`.
 *
 * Deliberately **not** `@MainActor`, for the reason `BrowserHistory` writes out:
 * a screen holds one of these as a default argument on a memberwise initialiser,
 * and default arguments are evaluated in a non-isolated context — so a
 * main-actor `shared` could not be named there at all. Nothing in here touches
 * UIKit or a socket; it is a dictionary, and every caller is a view or a bridge
 * already on the main thread.
 *
 * **In memory only.** The machine's recorder is the same: `browser-view.ts`
 * holds `entry.steps` on a live `WebContents` and nothing writes them to disk. A
 * flow belongs to the sitting in which it was recorded, and a flow found on disk
 * a week later — half of it about a page that has since been rewritten — is
 * worse than no flow, because it looks current.
 */
@Observable
final class PhoneClickFlow {

    /// The one the screens and the card read. A property of *this phone*, beside
    /// `BrowserHistory.shared` and `PortBook.shared`, rather than something hung
    /// off `DeckModel`: a recording must survive a reconnect rebuilding the model
    /// underneath it.
    static let shared = PhoneClickFlow()

    /**
     * Where a recording stops growing. `MAX_STEPS` in `src/main/browser-steps.ts`.
     *
     * The list stops rather than dropping its oldest steps, which is that file's
     * rule and its reasoning is the whole of why the number matters: *a flow is a
     * sequence, and one missing its beginning cannot be replayed at all, while
     * one missing its end is still a shorter true flow.*
     */
    static let maxSteps = 200

    /**
     * Two clicks closer together than this on the same element are one gesture.
     * `CLICK_MERGE_MS`, in milliseconds, and the same 400 rather than Chromium's
     * own 500: a little under the double-click threshold keeps deliberate repeat
     * clicks — a stepper, a `+` button — as the separate steps they are.
     */
    private static let clickMergeMS: Double = 400

    /// Longest value carried into a step (`MAX_VALUE`). Long enough for a URL
    /// typed into a text field.
    private static let maxValue = 200
    /// Longest label on a **field** (`MAX_LABEL`). A button keeps the capture's
    /// own label, which `Inspect` has already clamped.
    private static let maxLabel = 120
    private static let maxURL = 400

    /**
     * Selector, sentence and value length on a drawn row. `MAX_STEP_TEXT` in
     * `src/main/remote/browser-control.ts`.
     *
     * Applied here even though nothing is on a wire, and that is the point: these
     * rows are drawn by the **same** list as the machine's, so a phone step that
     * ran to four hundred characters would make one card in the app wrap where
     * the other truncates. The wire's *count* cap (`MAX_WIRE_STEPS`, sixty) is
     * deliberately not copied — it exists because two hundred selectors do not
     * fit in a 64 KiB frame, and there is no frame here.
     */
    private static let maxStepText = 160

    /// One line pasted into a prompt. `MAX_FLOW_LINE` in
    /// `src/main/browser-steps.ts`.
    private static let maxFlowLine = 1200

    /// The kind on the row that says a flow was cut. `TRUNCATED` over there.
    private static let truncatedKind = "truncated"

    /// Epoch milliseconds, as a seam. The coalescing window is the one piece of
    /// behaviour here with a duration in it, and a test proving it has to be able
    /// to move time rather than sleep through it. Milliseconds because that is
    /// what the machine stamps and what `MachineWindowSettingsView.offset`
    /// subtracts.
    private let now: () -> Double

    init(now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.now = now
    }

    /// One tab's recording.
    private struct Reel {
        var recording = false
        var steps: [PhoneStep] = []
        /// Where the page is, whether or not anything is being recorded. Kept so
        /// that `start` can write down where the flow begins — see it for why a
        /// flow with no first line cannot be replayed.
        var address = ""
    }

    private var reels: [String: Reel] = [:]

    // MARK: - The seam

    /// Whether this tab is recording right now.
    func isRecording(tab: String) -> Bool {
        reels[tab]?.recording ?? false
    }

    /**
     * The rows, in order, ready to draw.
     *
     * Built on read rather than held, because the drawn shape is a *rendering* of
     * the flow — the sentence, the trimmed selector, the value withheld — and the
     * flow itself is the richer thing above it. One source, one place the
     * redaction happens.
     *
     * The last row is the cut, when there is one. A silent stop at two hundred
     * reads as *that is all of them*, which is the same defect
     * `MachineBrowserState.notDrawn` exists to prevent on the other list.
     */
    func steps(tab: String) -> [RecordedStep] {
        guard let reel = reels[tab] else { return [] }
        var rows = reel.steps.enumerated().map { Self.row($0.element, index: $0.offset) }
        if reel.steps.count >= Self.maxSteps {
            rows.append(RecordedStep(at: reel.steps.last?.at ?? 0,
                                     kind: Self.truncatedKind,
                                     detail: "Recording stopped at \(Self.maxSteps) steps.",
                                     selector: nil,
                                     value: nil,
                                     index: rows.count))
        }
        return rows
    }

    /**
     * Start recording this tab.
     *
     * The first step is written here rather than waiting for one to happen, and
     * the machine does exactly the same thing in `setBrowserViewRecording`: *"a
     * flow that does not say where it starts cannot be replayed."* Where the page
     * is comes from `at(tab:url:)`, which the screen calls on every navigation —
     * never from the page's own claim about itself.
     *
     * Starting an already-running recording is a no-op rather than a restart. The
     * card is a toggle and a second press of an on switch is a press somebody did
     * not mean; throwing away a flow for it would be unrecoverable.
     */
    func start(tab: String) {
        guard !tab.isEmpty else { return }
        var reel = reels[tab] ?? Reel()
        guard !reel.recording else { return }
        reel.recording = true
        if !reel.address.isEmpty {
            reel.steps = Self.append(reel.steps, Self.navigate(reel.address, at: now()))
        }
        reels[tab] = reel
    }

    /// Stop. The steps stay — stopping is *finish this flow*, and the card's own
    /// Clear is the verb that ends one.
    func stop(tab: String) {
        guard var reel = reels[tab], reel.recording else { return }
        reel.recording = false
        reels[tab] = reel
    }

    /// Throw the flow away. `browser-view:record-clear` on the machine, and like
    /// it this leaves the recorder running if it was: clearing is *start again
    /// from here*, which is what somebody does after a false start.
    func clear(tab: String) {
        guard var reel = reels[tab] else { return }
        reel.steps = []
        reels[tab] = reel
        if reel.recording, !reel.address.isEmpty {
            // Re-seeded for the same reason `start` seeds: the flow that is being
            // recorded from this moment still has to say where it began.
            reels[tab]?.steps = Self.append([], Self.navigate(reel.address, at: now()))
        }
    }

    // MARK: - What the web view feeds it

    /**
     * Where this tab's page is, as **this app** knows it.
     *
     * Called on every navigation whether or not anything is recording, so that a
     * recording started later can say where it began. Never the page's own claim:
     * `browser-steps.ts` insists on the same thing for the same reason — *a page
     * that can forge these messages must not also get to name the site whose flow
     * the user is about to hand an agent.*
     *
     * While a recording is running this is also a **step**: a single-page app
     * rewrites its URL on every route change and each of those is a navigation
     * somebody performed. The repeat-URL fold in `append` is what keeps a
     * redirect chain that ends where it started from becoming two rows.
     */
    func at(tab: String, url: String) {
        guard !tab.isEmpty else { return }
        let line = Inspect.sanitizeLine(url, max: Self.maxURL)
        guard !line.isEmpty else { return }
        var reel = reels[tab] ?? Reel()
        let changed = reel.address != line
        reel.address = line
        if reel.recording, changed {
            reel.steps = Self.append(reel.steps, Self.navigate(line, at: now()))
        }
        reels[tab] = reel
    }

    /**
     * One message from the page-side recorder.
     *
     * Dropped in silence when it is malformed, when nothing is recording, or when
     * `Inspect.parseCapture` refuses the element — the same rule `parseGuestStep`
     * follows, and for the same reason: a complaint written by the page is not a
     * complaint worth showing.
     *
     * `url` is the web view's own, handed in by the bridge.
     */
    func note(_ raw: Any?, url: String, tab: String) {
        guard !tab.isEmpty, isRecording(tab: tab) else { return }
        guard let step = Self.parse(raw, url: url, at: now()) else { return }
        guard var reel = reels[tab] else { return }
        let next = Self.append(reel.steps, step)
        // `append` hands back the same array when a step folded into the previous
        // one or the cap was hit. Re-publishing for that redraws the card for
        // nothing, and @Observable would happily do it.
        guard next.count != reel.steps.count || next.last != reel.steps.last else { return }
        reel.steps = next
        reels[tab] = reel
    }

    /**
     * The whole flow on **one line**, for handing to an agent.
     *
     * `flowLine`, transcribed, and it is here rather than left to the card for
     * the reason `wireStep` gives about `detail`: three spellings of the same
     * flow is how one of them comes to leak a password the other two redact. The
     * card that sends a phone flow to a session and the panel that sends a
     * machine flow to one have to hand it the same sentence about the same click.
     *
     * Single line by construction, like every other string this app types into a
     * PTY: Deck types this into a terminal running a coding CLI, where a newline
     * submits — a multi-line flow would send `1. Go to…` as the whole
     * instruction. `Inspect.sanitizeLine` is the function that makes a string
     * safe for that, by the same rules, on both clients.
     */
    func line(tab: String) -> String {
        let steps = reels[tab]?.steps ?? []
        guard !steps.isEmpty else { return "" }
        let body = steps.enumerated()
            .map { "\($0.offset + 1)) \(Self.describe($0.element))" }
            .joined(separator: "; ")
        return Inspect.sanitizeLine("[browser flow: \(body)]", max: Self.maxFlowLine)
    }

    /// The tab is gone. Called when a page is closed, so a phone that has been
    /// used all day is not holding flows for windows nobody can see.
    func forget(tab: String) {
        reels[tab] = nil
    }
}

/* -------------------------------------------------------------------------- */
/* The model, transcribed from src/main/browser-steps.ts                       */
/* -------------------------------------------------------------------------- */

/**
 * One step, before it is rendered into a row.
 *
 * Flat with every field present rather than an enum with payloads, which is what
 * `browser-steps.ts` does and its reason holds here too: the shape crosses a
 * boundary — there, an IPC bridge; here, a JavaScript payload and a drawn list —
 * and a flat record survives that without two declarations having to agree about
 * which members exist.
 */
struct PhoneStep: Equatable {
    /// The seven words `StepKind` names in `src/main/browser-steps.ts`, and no
    /// eighth. `CaseIterable` so a test can say the list out loud rather than
    /// asserting one word at a time and missing the one that was added.
    enum Kind: String, CaseIterable {
        case navigate, click, type, select, check, press, submit
    }

    var kind: Kind
    /// CSS selector for the element. Empty for `navigate`.
    var selector = ""
    /// Human handle — the element's text, or the field's name. May be empty.
    var label = ""
    /// Element tag, when it was one we would emit.
    var tag = ""
    /// What was typed or chosen. Empty when redacted or not applicable.
    var value = ""
    /// The value was deliberately withheld: a password or a file path.
    var redacted = false
    /// For `press`. One of `PhoneClickFlow.notableKeys`.
    var key = ""
    /// For `check`.
    var checked = false
    /// The page this happened on, as **this app** knows it.
    var url = ""
    /// Epoch milliseconds, stamped on this side. The page never gets to stamp
    /// its own steps.
    var at: Double = 0
}

extension PhoneClickFlow {

    /// Keys the recorder is allowed to report. `NOTABLE_KEYS`, and the same
    /// three: everything else a person types arrives as the field's value on
    /// `change`, and Escape and Tab are how a form is dismissed or moved through.
    static let notableKeys = ["Enter", "Escape", "Tab"]

    /* ----------------------------------------------------------- parsing -- */

    /**
     * Validate one message from the page-side recorder.
     *
     * The element goes through `Inspect.parseCapture` — the same function the
     * inspector's taps go through — so the selector this produces is computed by
     * the rules `selector.ts` lays down and matches the one the desktop would
     * have written for the same element. Nothing about a selector is decided in
     * JavaScript on either client.
     */
    static func parse(_ raw: Any?, url: String, at: Double) -> PhoneStep? {
        guard let payload = raw as? [String: Any] else { return nil }
        // Read as an `NSNumber` rather than `as? Int`, the way `Inspect
        // .wholeNumber` reads every number that arrives from a page: a JavaScript
        // number crosses this boundary as a double-typed `NSNumber`, and how
        // forgiving `as? Int` is about that has changed across Swift releases.
        // A version check that quietly starts failing would silently drop every
        // step, which is the worst shape this could break in.
        guard let version = payload["v"] as? NSNumber, version.doubleValue == 1 else { return nil }
        guard let word = payload["kind"] as? String, let kind = PhoneStep.Kind(rawValue: word),
              kind != .navigate else { return nil }
        guard let capture = Inspect.parseCapture(payload["target"], url: url) else { return nil }

        var step = PhoneStep(kind: kind, at: at)
        step.selector = capture.selector
        step.tag = capture.tag
        step.url = capture.url
        // A button is named by what is written on it; a field is named by what
        // names it. `fieldLabel` is the second rule and it exists because both of
        // the obvious fallbacks are wrong on a form — see it.
        step.label = (kind == .click || kind == .submit)
            ? capture.label
            : fieldLabel(capture.attributes)

        switch kind {
        case .press:
            let key = payload["key"] as? String ?? ""
            guard notableKeys.contains(key) else { return nil }
            step.key = key
        case .check:
            step.checked = payload["checked"] as? Bool == true
        case .type, .select:
            // Two independent reasons to withhold, both checked. The page-side
            // script flags the field it knows to be secret; the capture's own
            // `type` attribute catches a payload where that flag was stripped on
            // the way here.
            if payload["secret"] as? Bool == true || isSecret(capture.attributes) {
                step.redacted = true
            } else {
                step.value = Inspect.sanitizeLine(payload["value"], max: maxValue)
            }
        default:
            break
        }
        return step
    }

    /// A navigation. Built from the view's own address, never from the page's.
    static func navigate(_ url: String, at: Double) -> PhoneStep {
        PhoneStep(kind: .navigate, url: Inspect.sanitizeLine(url, max: maxURL), at: at)
    }

    /**
     * The best name for a **field**, which is not the best name for a button.
     *
     * Only the naming attributes, and never the element's own text or its value.
     * Both of those fallbacks are wrong here in ways `browser-steps.ts` recorded
     * as *measured on a real page*, not guessed:
     *
     *  - a capture falls back to an element's live value when it has no text,
     *    which labels the email box with the email address — *Type "a@b.com" into
     *    a@b.com*;
     *  - a `<select>`'s text content is the concatenation of its own options, so
     *    the city picker in that probe came back named `DubaiLahore`. A
     *    `<textarea>`'s is whatever it was seeded with. Neither names the field.
     *
     * An unnamed field is left unnamed; the selector alone reads better than a
     * confident wrong label.
     */
    static func fieldLabel(_ attributes: [String: String]) -> String {
        for key in ["aria-label", "placeholder", "title", "name"] {
            if let value = attributes[key], !value.isEmpty {
                return Inspect.sanitizeLine(value, max: maxLabel)
            }
        }
        return ""
    }

    /// A field whose value belongs to the person rather than to the page. `file`
    /// counts for the same reason `password` does: the value is a path on their
    /// own disk, usually beginning with their name.
    static func isSecret(_ attributes: [String: String]) -> Bool {
        let type = (attributes["type"] ?? "").lowercased()
        return type == "password" || type == "file"
    }

    /* --------------------------------------------------------- appending -- */

    /**
     * Add a step, folding it into the previous one where they are really the same
     * action. The rules, and why each exists — all three transcribed:
     *
     *  - **Repeated typing in one field replaces itself.** `change` fires every
     *    time the field is left, so tabbing back to fix a typo would otherwise
     *    record the half-typed value *and* the finished one, and a replay would
     *    use the first.
     *  - **A repeat navigation to the same URL is dropped.** A single-page app
     *    rewrites its URL alongside a real navigation, and a redirect chain ends
     *    where it started often enough to matter.
     *  - **Two fast clicks on one element merge.** That is a double-click, not
     *    two steps, and no replay wants the second.
     *
     * Once the cap is reached the list stops growing rather than dropping its
     * oldest steps. See `maxSteps`.
     */
    static func append(_ steps: [PhoneStep], _ next: PhoneStep) -> [PhoneStep] {
        if let last = steps.last {
            if (next.kind == .type || next.kind == .select), last.kind == next.kind,
               sameTarget(last, next) {
                return Array(steps.dropLast()) + [next]
            }
            if next.kind == .navigate, last.kind == .navigate, last.url == next.url {
                return steps
            }
            if next.kind == .click, last.kind == .click, sameTarget(last, next),
               next.at - last.at < clickMergeMS {
                return steps
            }
        }
        guard steps.count < maxSteps else { return steps }
        return steps + [next]
    }

    private static func sameTarget(_ a: PhoneStep, _ b: PhoneStep) -> Bool {
        !a.selector.isEmpty && a.selector == b.selector
    }

    /* ---------------------------------------------------------- printing -- */

    /**
     * One step in a sentence a person can follow and a machine can replay.
     * `describeStep`, word for word — the two lists are drawn by the same rows
     * and a step described one way here and another way there is the difference
     * he has now pointed at twice.
     */
    static func describe(_ step: PhoneStep) -> String {
        switch step.kind {
        case .navigate:
            return "Go to \(step.url)"
        case .click:
            return "Click \(target(step))"
        case .type:
            return step.redacted
                ? "Type the password into \(target(step))"
                : "Type \"\(step.value)\" into \(target(step))"
        case .select:
            return step.redacted
                ? "Choose a value in \(target(step))"
                : "Choose \"\(step.value)\" in \(target(step))"
        case .check:
            return "\(step.checked ? "Check" : "Uncheck") \(target(step))"
        case .press:
            return "Press \(step.key) in \(target(step))"
        case .submit:
            return "Submit \(target(step))"
        }
    }

    private static func target(_ step: PhoneStep) -> String {
        let named = step.label.isEmpty ? "" : "\"\(step.label)\""
        let where_ = !step.selector.isEmpty
            ? "`\(step.selector)`"
            : (!step.tag.isEmpty ? "<\(step.tag)>" : "the page")
        return named.isEmpty ? where_ : "\(named) (\(where_))"
    }

    /// One step as the list draws it. `wireStep`, including the one thing that
    /// file is emphatic about: the value is dropped outright when the step was
    /// redacted.
    static func row(_ step: PhoneStep, index: Int) -> RecordedStep {
        let detail = Inspect.sanitizeLine(describe(step), max: maxStepText)
        let selector = Inspect.sanitizeLine(step.selector, max: maxStepText)
        let value = step.redacted ? "" : Inspect.sanitizeLine(step.value, max: maxStepText)
        return RecordedStep(at: step.at,
                            kind: step.kind.rawValue,
                            detail: detail.isEmpty ? nil : detail,
                            selector: selector.isEmpty ? nil : selector,
                            value: value.isEmpty ? nil : value,
                            index: index)
    }
}
