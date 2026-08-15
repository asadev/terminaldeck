/**
 * Getting a session's output off the phone and into somebody else's hands.
 *
 * Copy already exists and is not this. Copy takes the **screen** — or a
 * selection — and puts it on the pasteboard, which is the right tool for one
 * line you are looking at. This takes **everything the terminal is holding**,
 * scrollback included, and hands it to the share sheet as a file, because that
 * is the other half of the job: the reason to send a session to a colleague is
 * the stack trace that has already scrolled off the top, and five hundred lines
 * of it is a file rather than a message body.
 *
 * Two tools with no overlap, rather than one that half does both.
 *
 * ## Why a file and not a string
 *
 * A string handed to the share sheet becomes the *body* of whatever it lands
 * in: five hundred lines pasted into a message. A `.txt` file arrives as an
 * attachment in Mail, Messages and WhatsApp, opens in Quick Look, saves into
 * Files, and AirDrops to the Mac the session is running on — which is the one
 * everybody actually wants.
 *
 * ## The name carries the identity, the content does not
 *
 * No header is prepended to the text. What comes out of a terminal is what
 * somebody is going to paste into an issue or grep, and a product banner glued
 * to the top of it is one more line they have to delete. The file is called
 * after the session and the moment instead, which is where a file's identity
 * belongs.
 */

import SwiftUI
import UIKit

enum ShareOutput {

    /**
     * What the shared file is called.
     *
     * Pure, and tested, because a file name is the one part of this a person
     * reads before opening it. The session title is the folder the desktop
     * named it after, so it is already the most recognisable string available —
     * reduced here to what is safe in a file name on every system it might land
     * on, which rules out slashes, colons and spaces.
     */
    static func fileName(session: String, at date: Date = Date()) -> String {
        let stamp = DateFormatter.stamp.string(from: date)
        let slug = slugify(session)
        return slug.isEmpty ? "session-\(stamp).txt" : "\(slug)-\(stamp).txt"
    }

    /// Lower case, ASCII letters, digits and hyphens; runs of anything else
    /// become one hyphen. Bounded, because a session title comes from a folder
    /// name and a folder name can be very long.
    private static func slugify(_ text: String) -> String {
        var out = ""
        var lastWasDash = false
        for character in text.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /**
     * Put the text in a temporary file and hand back where it went.
     *
     * In a subfolder that is emptied first, so the phone does not accumulate one
     * transcript per share for the life of the install — the system clears the
     * temporary directory eventually, and "eventually" is not a cleanup story
     * for something that can be several hundred kilobytes a time.
     *
     * Nil when the write fails. The caller says so on screen rather than
     * presenting a share sheet for a file that is not there.
     */
    static func write(_ text: String, named name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private extension DateFormatter {
    /// `2026-08-15-1642`. Sortable, no colons — a colon in a file name is
    /// legal on iOS and becomes a path separator the moment the file reaches a
    /// Mac's Finder.
    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/**
 * The system share sheet, over whatever raised it.
 *
 * A representable rather than SwiftUI's `ShareLink`, for one reason: `ShareLink`
 * builds its item when the *view* is built, and the thing being shared here is
 * a snapshot of a terminal that is still printing. The file has to be written at
 * the moment the sheet is asked for, or it shares whatever the session looked
 * like when the screen was drawn.
 */
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// What Mail puts in the subject line. Not part of the file.
    let subject: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [SubjectSource(url: url, subject: subject)],
                                                  applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/**
 * A file, with a subject for the targets that ask for one.
 *
 * `UIActivityItemSource` exists for exactly this: handing a bare URL to the
 * share sheet gives Mail an empty subject line, and a mail with no subject
 * carrying a file called `something-2026-08-15-1642.txt` is one nobody opens.
 */
private final class SubjectSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let subject: String

    init(url: URL, subject: String) {
        self.url = url
        self.subject = subject
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String { subject }
}
