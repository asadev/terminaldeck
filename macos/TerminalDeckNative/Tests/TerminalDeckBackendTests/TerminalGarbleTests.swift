import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 27 Oct (Asad: "This kind of problem is very common in both applications, mobile and Mac, when we are using a
/// terminal session"). His iLoop Claude Code session on the phone: rows written over each other, red diff rows
/// smeared, words cut at the left edge, status lines painted into other lines.
///
/// Every test replays a real Claude Code recording (`TerminalGarbleFixture`, full-screen view, a file edit,
/// then the sizes the Mac and the phone gave it) into the same terminal engine both apps draw with. The fix: one
/// owner of the size (28 Oct: the device where the session was chosen last), and a clean redraw for whoever takes
/// it back. A phone from 27 Oct that only attaches shows a picture at exactly the owner's size.
final class TerminalGarbleTests: XCTestCase {
    private var mac: (cols: Int, rows: Int) { (TerminalGarbleFixture.segments[0].cols, TerminalGarbleFixture.segments[0].rows) }
    private var drawnForTheMac: Data { TerminalGarbleFixture.segments[0].bytes }
    private var drawnForThePhone: Data { TerminalGarbleFixture.segments[1].bytes }   // 45x60: the phone won
    private var drawnBackForTheMac: Data { TerminalGarbleFixture.segments[3].bytes } // 120x40 again: a full repaint

    private func chunks(_ data: Data, size: Int = 512) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    /// The cause, phone side: a 45-column terminal fed what Claude Code drew for 120 columns.
    func testAPhoneFedTheMacsDrawingShowsTheGarble() {
        let exact = BackendTerminalProbe(cols: 120, rows: 40); exact.feed(drawnForTheMac)
        // (The row's mark is a symbol whose width differs between engines; the rest of the row is what counts.)
        XCTAssertTrue(exact.rows.contains { $0.hasSuffix("Update(notes.txt)") }, exact.rows.joined(separator: "\n"))
        XCTAssertEqual(exact.rows.filter { $0.contains("-line ") }.count, 12, "every removed line on its own row")

        let phone = BackendTerminalProbe(cols: 45, rows: 60); phone.feed(drawnForTheMac)
        let rows = phone.rows
        XCTAssertFalse(rows.contains { $0.hasSuffix("Update(notes.txt)") }, "the header is written over:\n" + rows.joined(separator: "\n"))
        XCTAssertTrue(rows.contains { $0.hasPrefix("ctor away") || $0.hasPrefix("octor away") },
                      "words cut at the left edge, as in his screenshot:\n" + rows.joined(separator: "\n"))
    }

    /// The cause, Mac side: the phone made the session 60 rows tall; the Mac's terminal has 40.
    func testAMacFedThePhonesTallerDrawingShowsTheGarble() {
        let macView = BackendTerminalProbe(cols: 120, rows: 40)
        macView.feed(drawnForTheMac); macView.feed(drawnForThePhone)
        let bottom = macView.rows.last ?? ""
        XCTAssertTrue(bottom.contains("auto mode on") && bottom.contains("─"),
                      "the input box's rule and the footer land on one row:\n" + macView.rows.joined(separator: "\n"))
    }

    /// The Mac has it: a phone that attaches without choosing it (a 27 Oct phone showing pictures) is never asked
    /// to draw at its own width. It shows a picture of the Mac's exact screen: its terminal is the session's size,
    /// fed the remount and then the live output, and only the picture is scaled to the phone.
    func testWhileTheMacHasItAPicturePhoneShowsTheMacsScreen() throws {
        var viewers = BackendTerminalViewers()
        viewers.mac = .init(cols: 120, rows: 40)
        XCTAssertEqual(viewers.settle(), .init(cols: 120, rows: 40))
        viewers.claims = [.init(viewer: "phone", size: .init(cols: 45, rows: 60))]
        XCTAssertNil(viewers.settle(), "a phone attached without choosing it changes nothing")
        XCTAssertEqual(viewers.owner, .mac)
        let frame = BackendRemoteHost.sizeFields("s1", state: viewers, viewer: "phone", hostName: "Asad's Mac mini")
        XCTAssertEqual(NativeRPCValue.object(frame)["owner"], .string("mac"))
        XCTAssertEqual(NativeRPCValue.object(frame)["name"], .string("Asad's Mac mini"))
        XCTAssertEqual(NativeRPCValue.object(frame)["cols"], .number(120))
        XCTAssertEqual(NativeRPCValue.object(frame)["rows"], .number(40))

        let exact = BackendTerminalProbe(cols: 120, rows: 40); exact.feed(drawnForTheMac); exact.feed(drawnBackForTheMac)
        let picture = BackendTerminalProbe(cols: 120, rows: 40)   // the phone's picture: the session's size, from `size`
        picture.feed(try BackendPTYManager.remountForTesting(cols: 120, rows: 40, chunks: chunks(drawnForTheMac)))
        picture.feed(drawnBackForTheMac)
        XCTAssertEqual(picture.rows, exact.rows, "the phone's picture is the Mac's screen, row for row")
        for row in 0..<40 { XCTAssertEqual(picture.backgrounds(row: row), exact.backgrounds(row: row), "colours, row \(row)") }
        // The Mac, which owns the size, draws it as itself: nothing to compare but that it is whole.
        XCTAssertTrue(exact.rows.contains { $0.hasSuffix("Update(notes.txt)") } || exact.rows.contains { $0.contains("auto mode on") })
    }

    /// Chosen on the phone: the phone owns the size and gets an ordinary terminal at its own width; when the session
    /// is chosen on the Mac again it takes the size back and its terminal, fed the phone's drawing meanwhile, is
    /// redrawn clean from the remount.
    func testChosenOnThePhoneItOwnsTheSizeAndTheMacIsRedrawnCleanWhenItComesBack() throws {
        var viewers = BackendTerminalViewers()
        viewers.mac = .init(cols: 120, rows: 40); _ = viewers.settle()
        viewers.claims = [.init(viewer: "phone", size: .init(cols: 45, rows: 60), name: "Asad's iPhone", platform: "ios")]
        XCTAssertNil(viewers.settle())
        viewers.used(by: .viewer("phone"), name: "Asad's iPhone", platform: "ios", turn: 1)
        XCTAssertEqual(viewers.settle(), .init(cols: 45, rows: 60), "opened on the phone: the phone's size")
        XCTAssertEqual(viewers.owner, .viewer("phone"))
        XCTAssertEqual(NativeRPCValue.object(BackendRemoteHost.sizeFields("s1", state: viewers, viewer: "phone", hostName: "Mac"))["owner"], .string("you"))
        let other = NativeRPCValue.object(BackendRemoteHost.sizeFields("s1", state: viewers, viewer: "ipad", hostName: "Mac"))
        XCTAssertEqual(other["owner"], .string("phone"))
        XCTAssertEqual(other["name"], .string("Asad's iPhone"), "the other device's panel says where it is open")

        // The phone: an ordinary 45x60 terminal, the same as the session's own parse of it.
        let shadowReads = chunks(drawnForTheMac) + [Data()] + chunks(drawnForThePhone)
        let atPhone = [chunks(drawnForTheMac).count: (cols: 45, rows: 60)]
        let exactPhone = BackendTerminalProbe(cols: 120, rows: 40)
        exactPhone.feed(drawnForTheMac); exactPhone.resize(cols: 45, rows: 60); exactPhone.feed(drawnForThePhone)
        let phone = BackendTerminalProbe(cols: 45, rows: 60)
        phone.feed(try BackendPTYManager.remountForTesting(cols: 120, rows: 40, chunks: chunks(drawnForTheMac) + [Data()], resizes: atPhone))
        phone.feed(drawnForThePhone)
        XCTAssertEqual(phone.rows, exactPhone.rows, "the phone's own terminal is whole")

        // The Mac's terminal stayed 120x40 off screen and was fed the 45x60 drawing: garbled, out of sight.
        let macView = BackendTerminalProbe(cols: 120, rows: 40)
        macView.feed(drawnForTheMac); macView.feed(drawnForThePhone)

        // Chosen on the Mac again: it takes the size and redraws from the remount, then the program's own repaint
        // at 120x40 arrives.
        viewers.used(by: .mac, turn: 2)
        XCTAssertEqual(viewers.settle(), .init(cols: 120, rows: 40))
        let exact = BackendTerminalProbe(cols: 120, rows: 40)
        exact.feed(drawnForTheMac); exact.resize(cols: 45, rows: 60); exact.feed(drawnForThePhone); exact.resize(cols: 120, rows: 40)
        let remount = try BackendPTYManager.remountForTesting(cols: 120, rows: 40, chunks: shadowReads + [Data()],
            resizes: [chunks(drawnForTheMac).count: (45, 60), shadowReads.count: (120, 40)])
        macView.feed("\u{1b}c" + remount)
        XCTAssertEqual(macView.rows, exact.rows, "clean the moment it is redrawn")
        exact.feed(drawnBackForTheMac); macView.feed(drawnBackForTheMac)
        XCTAssertEqual(macView.rows, exact.rows, "and after the program's own repaint")
        for row in 0..<40 { XCTAssertEqual(macView.backgrounds(row: row), exact.backgrounds(row: row), "colours, row \(row)") }
    }

    /// Who owns the size, every way it can move (28 Oct: where the session was chosen last).
    func testTheSizeFollowsWhereTheSessionWasChosenLast() {
        var viewers = BackendTerminalViewers()
        XCTAssertEqual(viewers.owner, .mac); XCTAssertNil(viewers.settle(), "nothing known yet: the size stays")
        XCTAssertEqual(NativeRPCValue.object(BackendRemoteHost.sizeFields("s1", state: viewers, viewer: "a", hostName: "Mac"))["owner"], .string("none"))
        XCTAssertEqual(NativeRPCValue.object(BackendRemoteHost.sizeFields("s1", state: nil, viewer: "a", hostName: "Mac"))["cols"], .null)
        viewers.claims = [.init(viewer: "a", size: .init(cols: 45, rows: 60))]
        XCTAssertNil(viewers.settle(), "attached without choosing it: nothing")
        viewers.used(by: .viewer("a"), turn: 1)
        XCTAssertEqual(viewers.settle(), .init(cols: 45, rows: 60), "opened on a")
        viewers.claims.append(.init(viewer: "b", size: .init(cols: 60, rows: 30)))
        XCTAssertNil(viewers.settle(), "b attached but did not choose it")
        viewers.used(by: .viewer("b"), turn: 2)
        XCTAssertEqual(viewers.settle(), .init(cols: 60, rows: 30), "opened on b")
        viewers.claims.removeAll { $0.viewer == "b" }
        XCTAssertNil(viewers.settle(), "b left: it keeps the session (and its size) until another device chooses it")
        XCTAssertEqual(viewers.owner, .viewer("b"))
        viewers.mac = .init(cols: 100, rows: 30)
        XCTAssertNil(viewers.settle(), "the Mac's window size is kept for when it has the session")
        viewers.used(by: .mac, turn: 3)
        XCTAssertEqual(viewers.settle(), .init(cols: 100, rows: 30), "chosen on the Mac")
        viewers.mac = .init(cols: 110, rows: 30)
        XCTAssertEqual(viewers.settle(), .init(cols: 110, rows: 30), "the Mac's window grew while it has it")
        viewers.claims = []
        XCTAssertNil(viewers.settle())
        XCTAssertEqual(viewers.turn, 3)
    }

    /// The fix for joining late: the remount draws the session as it is; the raw tail of reads could not.
    func testRemountRebuildsTheScreenWhereARawTailCannot() throws {
        let reads = chunks(drawnForTheMac)
        let exact = BackendTerminalProbe(cols: 120, rows: 40); exact.feed(drawnForTheMac)

        let remount = try BackendPTYManager.remountForTesting(cols: 120, rows: 40, chunks: reads)
        let joined = BackendTerminalProbe(cols: 120, rows: 40); joined.feed(remount)
        XCTAssertEqual(joined.rows, exact.rows)
        for row in 0..<40 { XCTAssertEqual(joined.backgrounds(row: row), exact.backgrounds(row: row), "colours, row \(row)") }
        XCTAssertTrue(joined.fullScreen, "back in the full screen, so the main screen's history stays clean")
        XCTAssertTrue(joined.reportsMouse, "the wheel still scrolls Claude Code's own view")
        XCTAssertEqual(joined.cursor.row, exact.cursor.row); XCTAssertEqual(joined.cursor.col, exact.cursor.col)
        XCTAssertFalse(remount.contains("\u{1b}[c") || remount.contains("\u{1b}[>0q"), "no questions to the viewer's terminal")

        // What a late viewer used to get: the reads after the oldest ones fell out of the 4,000-read buffer.
        let tail = BackendTerminalProbe(cols: 120, rows: 40)
        for read in reads.dropFirst(reads.count * 2 / 5) { tail.feed(read) }
        XCTAssertNotEqual(tail.rows, exact.rows, "changes laid over a frame that is not in the tail")
        XCTAssertFalse(tail.fullScreen, "and the switch into the full screen fell out with it")
    }

    /// Every size the session went through: the remount is the session as it is after the last one.
    func testRemountFollowsEveryResize() throws {
        var reads: [Data] = [], resizes: [Int: (cols: Int, rows: Int)] = [:]
        let exact = BackendTerminalProbe(cols: mac.cols, rows: mac.rows)
        for (index, segment) in TerminalGarbleFixture.segments.enumerated() {
            if index > 0 { resizes[reads.count] = (segment.cols, segment.rows); exact.resize(cols: segment.cols, rows: segment.rows) }
            reads += chunks(segment.bytes); exact.feed(segment.bytes)
        }
        let remount = try BackendPTYManager.remountForTesting(cols: mac.cols, rows: mac.rows, chunks: reads, resizes: resizes)
        let joined = BackendTerminalProbe(cols: 120, rows: 40); joined.feed(remount)
        XCTAssertEqual(joined.rows, exact.rows)
        // A phone narrower than the session gets each row cut at its edge, never spilled over the next one.
        let narrow = BackendTerminalProbe(cols: 45, rows: 40); narrow.feed(remount)
        // (With wrapping off, what does not fit is written over the last column, so compare up to it.)
        func cut(_ text: String) -> String { String(String(text.prefix(44)).reversed().drop { $0 == " " }.reversed()) }
        for row in 0..<40 { XCTAssertEqual(cut(narrow.rows[row]), cut(exact.rows[row]), "narrow row \(row)") }
    }

    /// An ordinary shell: history comes back as lines, colours kept, the cursor where it was, and a long line
    /// wraps again at a narrower viewer's edge instead of being cut.
    func testRemountOfAShellKeepsItsHistory() throws {
        var output = ""
        for n in 1...150 { output += "\u{1b}[3\(n % 7 + 1)mline \(n)\u{1b}[0m done\r\n" }
        output += String(repeating: "x", count: 100) + "\r\n"
        output += "$ ls -la\u{1b}[3D"
        let shell = BackendTerminalProbe(cols: 80, rows: 24); shell.feed(output)
        let remount = try BackendPTYManager.remountForTesting(cols: 80, rows: 24, chunks: [Data(output.utf8)])

        let same = BackendTerminalProbe(cols: 80, rows: 24); same.feed(remount)
        XCTAssertEqual(same.rows, shell.rows)
        XCTAssertEqual(same.cursor.row, shell.cursor.row); XCTAssertEqual(same.cursor.col, shell.cursor.col)
        XCTAssertTrue(same.history.contains("line 1 done"), "the oldest line is in the history")
        XCTAssertFalse(same.fullScreen)

        let narrow = BackendTerminalProbe(cols: 45, rows: 24); narrow.feed(remount)
        let text = narrow.history.joined(separator: "\n")
        XCTAssertTrue(text.contains(String(repeating: "x", count: 45) + "\n" + String(repeating: "x", count: 45) + "\n" + String(repeating: "x", count: 10)),
                      "the 100-character line wraps at 45")
    }

    /// The modes are read off the output as it passes, even when a sequence is split between two reads.
    func testModesAreReadAcrossReads() {
        var modes = BackendTerminalModes()
        for piece in ["\u{1b}[?10", "06h\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1000l\u{1b}[?1003h\u{1b}]2;iLo", "op\u{07}\u{1b}[>1u\u{1b}[2 q\u{1b}[?25l\u{1b}[?1049h"] {
            modes.scan(Array(piece.utf8))
        }
        let restore = modes.restore()
        for wanted in ["\u{1b}[?1006h", "\u{1b}[?2004h", "\u{1b}[?1003h", "\u{1b}[?25l", "\u{1b}[>1u", "\u{1b}[2 q", "\u{1b}]2;iLoop\u{07}"] {
            XCTAssertTrue(restore.contains(wanted), "\(wanted.debugDescription) in \(restore.debugDescription)")
        }
        XCTAssertFalse(restore.contains("1049"), "switching screens is the remount's own business")
        XCTAssertFalse(restore.contains("?1000"), "only the mouse tracking mode that is on")
        modes.scan(Array("\u{1b}c".utf8))
        XCTAssertEqual(modes.restore(), "", "a full reset forgets them")
    }

    /// End to end on a real pty: the Mac and a phone choosing the session in turn, the size following the owner.
    func testOnARealTerminalTheOwnerSetsTheSize() async throws {
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        addTeardownBlock { manager.beginShutdown(); _ = await manager.drain(timeoutMilliseconds: 2_000) }
        let meta = try manager.create(.init(cwd: "/tmp", provider: "shell"),
                                      spawn: .init(provider: "shell", command: "/bin/sh", args: [], path: "/usr/bin:/bin"))
        let told = TerminalGarbleCounter()
        let watch = manager.observeSizes { if $0 == meta.id { told.add() } }
        defer { Task { await watch.cancelAndWait() } }
        func size(_ marker: String) async throws -> String {
            try manager.write(meta.id, data: "echo \(marker) $(stty size)\n")
            for _ in 0..<100 {
                let text = manager.scrollbackText(meta.id) ?? ""
                if let line = text.components(separatedBy: "\n").last(where: { $0.hasPrefix(marker + " ") }) {
                    return String(line.dropFirst(marker.count + 1)).trimmingCharacters(in: .whitespaces)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("no answer for \(marker)"); return ""
        }
        let phone = BackendTerminalViewers.Claim(viewer: "phone", size: .init(cols: 45, rows: 60), name: "Asad's iPhone", platform: "ios")
        try manager.resize(meta.id, cols: 120, rows: 40)                     // the Mac has it from the start
        let macHas = try await size("A"); XCTAssertEqual(macHas, "40 120")
        XCTAssertFalse(try manager.setViewerSizes(meta.id, [phone]))
        let phoneAttached = try await size("B"); XCTAssertEqual(phoneAttached, "40 120", "attached, not chosen: nothing moves")
        XCTAssertTrue(try manager.setViewerSizes(meta.id, [phone], user: "phone"))
        let phoneChose = try await size("C"); XCTAssertEqual(phoneChose, "60 45", "opened on the phone: the phone's size")
        XCTAssertEqual(manager.owner(meta.id).here, false)
        XCTAssertEqual(manager.owner(meta.id).name, "Asad's iPhone")
        XCTAssertEqual(manager.owner(meta.id).kind, "phone")
        try manager.resize(meta.id, cols: 130, rows: 40)
        let macGrew = try await size("D"); XCTAssertEqual(macGrew, "60 45", "the Mac's window changing size takes nothing")
        XCTAssertTrue(try manager.macUsed(meta.id, cols: 120, rows: 40))
        XCTAssertFalse(try manager.macUsed(meta.id, cols: 120, rows: 40), "already here at that size")
        let macBack = try await size("E"); XCTAssertEqual(macBack, "40 120", "chosen on the Mac again")
        XCTAssertTrue(manager.owner(meta.id).here)
        XCTAssertFalse(try manager.setViewerSizes(meta.id, [phone], user: "phone", keep: true),
                       "the phone coming back after its link dropped does not take what the Mac chose since")
        try manager.setViewerSizes(meta.id, [])
        let nobody = try await size("F"); XCTAssertEqual(nobody, "40 120")
        XCTAssertGreaterThanOrEqual(told.count, 3, "every change of owner or size is told")
    }

    /// The reader of modes costs one memchr per read of plain text, still finds a sequence split between reads,
    /// and keeps only the one mouse tracking mode that is on.
    func testModesSkipPlainTextAndKeepOneMouseMode() {
        var modes = BackendTerminalModes()
        modes.scan(Array(String(repeating: "plain text, no escapes at all ", count: 100).utf8))
        modes.scan(Array("text then \u{1b}[?100".utf8)); modes.scan(Array("0h more text\u{1b}[?1002h\u{1b}[?1006h".utf8))
        XCTAssertEqual(modes.mouseTracking, 1002)
        var restore = modes.restore()
        XCTAssertTrue(restore.contains("\u{1b}[?1002h") && restore.contains("\u{1b}[?1006h"), restore.debugDescription)
        XCTAssertFalse(restore.contains("?1000"), "a replaced tracking mode is not replayed")
        modes.scan(Array("\u{1b}[?1003h".utf8)); XCTAssertEqual(modes.mouseTracking, 1003)
        modes.scan(Array("\u{1b}[?1000l".utf8)); XCTAssertNil(modes.mouseTracking, "any of them off turns tracking off")
        restore = modes.restore()
        for gone in ["?9h", "?1000h", "?1001h", "?1002h", "?1003h"] { XCTAssertFalse(restore.contains(gone), restore.debugDescription) }
        XCTAssertTrue(restore.contains("\u{1b}[?1006h"), "the encoding is its own mode")
    }

    /// A shell that set a scroll region, joined by a taller terminal: the cursor lands on the line it was on, not
    /// on the same row number.
    func testAScrollRegionKeepsTheCursorOnItsLineInATallerViewer() throws {
        var output = ""
        for n in 1...100 { output += "line \(n)\r\n" }
        output += "\u{1b}[1;20r\u{1b}[10;5H"
        let shell = BackendTerminalProbe(cols: 80, rows: 24); shell.feed(output)
        let remount = try BackendPTYManager.remountForTesting(cols: 80, rows: 24, chunks: [Data(output.utf8)])
        for height in [24, 40] {
            let viewer = BackendTerminalProbe(cols: 80, rows: height); viewer.feed(remount)
            XCTAssertEqual(viewer.rows[viewer.cursor.row], shell.rows[shell.cursor.row], "\(height) rows: the cursor's line")
            XCTAssertEqual(viewer.cursor.col, shell.cursor.col)
        }
    }
}

/// Counts notices from a background queue.
final class TerminalGarbleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
