/**
 * The phone's half of "send a photo, a video or a file into the terminal".
 *
 * A person picks something in the OS's own picker; this reads it in slices, puts
 * them on the sealed channel that is already open, and watches the Mac
 * acknowledge each one. When the last slice is acknowledged it sends the digest
 * of what it read; the Mac compares that against what it wrote and answers with
 * the path. `DeckModel` then types that path into the terminal.
 *
 * ## Why the window, and why progress is drawn from acknowledgements
 *
 * Flash on a modern phone reads faster than any link this travels over. Without
 * a window, a 200 MB video is handed to the socket in a couple of seconds and
 * then sits in the Mac's heap until its backpressure cap drops this phone — a
 * feature that fails *only* on the large files, which is the worst way for it to
 * fail. So no more than `Wire.uploadWindowBytes` may be unacknowledged at once,
 * and the next read is armed by an acknowledgement rather than by a timer. It is
 * the same shape `PortTunnel` uses, where `NWConnection` being pull-based makes
 * the point for you; here the file is not pull-based and the pump has to be
 * written down.
 *
 * The bar is drawn from the same acknowledgements. Drawn from bytes handed to
 * the socket it would fill in two seconds and then sit at 100% for a minute,
 * which is not a progress bar, it is a lie with an animation.
 *
 * ## Why the digest
 *
 * A truncated video with the right name is worse than no video: it surfaces
 * later, somewhere else, as a file nobody can open. This hashes what it *reads*,
 * the Mac hashes what it *writes*, and a mismatch deletes the file rather than
 * renaming it into place. That covers a dropped slice, a bug in either chunker,
 * and a disk that lied — none of which the byte count alone would catch.
 *
 * ## Where the file came from
 *
 * A URL handed over by `PHPickerViewController` or `UIDocumentPickerViewController`,
 * both of which run **out of process**. This app never opens the photo library,
 * so there is no `NSPhotoLibraryUsageDescription`, no permission prompt and
 * nothing extra for App Review. See `FilePickers.swift`; that choice is a design
 * constraint, not a preference.
 */

import CryptoKit
import Foundation
import Observation

/// What a `FileUpload` needs from the connection it rides. `DeckModel` provides it.
@MainActor
protocol UploadWire: AnyObject {
    /// False when the socket is down. Never queues, for the same reason the
    /// terminal's input path does not: a slice held back and delivered after a
    /// reconnect lands in the middle of a file the Mac has already given up on.
    @discardableResult
    func send(_ message: ClientMessage) -> Bool
}

/// A file the user picked, before anything has been sent.
struct PickedFile: Equatable {
    /// A local URL this app owns and may delete. Both pickers copy.
    let url: URL
    /// What to suggest calling it on the Mac. The Mac decides the real name.
    let name: String
    let size: Int
    /// Whether `url` is a copy in this app's temporary directory, to be deleted
    /// when the upload ends however it ends.
    let temporary: Bool
}

@MainActor
@Observable
final class FileUpload: Identifiable {

    /// Every state the progress row can be in, each carrying what it should show.
    enum Phase: Equatable {
        /// `upload.begin` is on the wire; the Mac has not named a path yet.
        case opening
        /// Sending. `path` is where it is going, and it is on screen while
        /// Cancel still means something.
        case sending(path: String)
        /// Every byte is acknowledged and the digest has gone; the Mac is
        /// renaming the file into place.
        case finishing(path: String)
        case landed(path: String)
        /// It did not land. `detail` is for the person, not the log.
        case failed(String)
    }

    private(set) var phase: Phase = .opening
    /// Bytes the Mac has said it has written. What the bar is drawn from.
    private(set) var acked = 0

    /// A UUID, which satisfies the desktop's id shape. Not derived from the file
    /// name: an id is a routing key and a name is attacker-adjacent text.
    let id = UUID().uuidString
    let name: String
    let size: Int

    private let file: PickedFile
    private weak var wire: UploadWire?
    /// Called once, with the path, when the file has landed. `DeckModel` types it.
    private let onLanded: (String) -> Void

    private var handle: FileHandle?
    /// Bytes read and sent that have not been acknowledged. Never above the window.
    private var inFlight = 0
    /// Bytes read off disk so far. Reaches `size` well before `acked` does.
    private var read = 0
    private var digest = SHA256()
    /// Set once `upload.end` has gone, so a late acknowledgement cannot send it twice.
    private var ended = false
    private var finished = false

    init(file: PickedFile, wire: UploadWire, onLanded: @escaping (String) -> Void) {
        self.file = file
        self.name = file.name
        self.size = file.size
        self.wire = wire
        self.onLanded = onLanded
    }

    /// 0…1, from acknowledgements. Zero-size files cannot reach here — the
    /// desktop refuses them — but the guard keeps this from being the one place
    /// that divides by zero.
    var fraction: Double {
        size > 0 ? min(1, Double(acked) / Double(size)) : 0
    }

    /// Announce the file. Nothing is read until the Mac answers with a path.
    func start() {
        guard wire?.send(.uploadBegin(id: id, name: name, size: size)) == true else {
            end(.failed("The connection to the machine is not up."), tellMac: false)
            return
        }
    }

    /// The Cancel button, and the only way to stop a stalled upload from here.
    func cancel() {
        end(.failed("Cancelled."), tellMac: true)
    }

    /// The socket went away underneath it. The Mac deletes its half on its own.
    func connectionLost(_ detail: String) {
        end(.failed(detail), tellMac: false)
    }

    /**
     * A frame from the Mac. True when it belonged to this upload.
     *
     * Returning a Bool rather than filtering upstream keeps the routing in one
     * place, exactly as `PortTunnel.receive` does: `DeckModel` has no idea which
     * upload ids are whose, and giving it one would be a second copy of this
     * state to keep in step.
     */
    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .uploadReady(id, path) where id == self.id:
            begin(at: path)
            return true
        case let .uploadAck(id, bytes) where id == self.id:
            acknowledge(bytes)
            return true
        case let .uploadDone(id, path, _, _) where id == self.id:
            // The Mac decided it is over, so it is not told again.
            end(.landed(path: path), tellMac: false)
            onLanded(path)
            return true
        case let .uploadFailed(id, detail) where id == self.id:
            end(.failed(detail), tellMac: false)
            return true
        default:
            return false
        }
    }

    // MARK: - Sending

    private func begin(at path: String) {
        guard case .opening = phase else { return }
        do {
            handle = try FileHandle(forReadingFrom: file.url)
        } catch {
            // The picker handed over a URL and it is already gone. Rare, and the
            // honest answer is to stop rather than to send a shorter file.
            end(.failed("This phone could not read that file any more."), tellMac: true)
            return
        }
        phase = .sending(path: path)
        pump()
    }

    /**
     * Read and send until the window is full or the file is done.
     *
     * Reading happens here on the main actor rather than on a background task,
     * and that is a deliberate trade rather than an oversight: the pump is driven
     * by acknowledgements, so it never reads more than one window — eleven
     * 24 KiB slices — before yielding, which is well under a frame's budget even
     * on the oldest phone this runs on. A background reader would buy nothing and
     * would need its own synchronisation with a state machine that is otherwise
     * entirely main-actor.
     */
    private func pump() {
        guard case .sending = phase, let handle else { return }
        // `inFlight + a whole slice <= window`, not `inFlight < window`. The
        // looser condition reads one more slice when it is already 240 KiB ahead
        // and overshoots the window by a chunk — which is small, and is also the
        // difference between a bound this can be tested against and a bound that
        // is approximately true. The tunnel's `forward` has the looser shape
        // because it is handed whatever the kernel gives it; here the read size
        // is ours to choose, so the exact version costs nothing.
        while inFlight + Wire.maxUploadChunkBytes <= Wire.uploadWindowBytes && read < size {
            let slice: Data?
            do {
                slice = try handle.read(upToCount: Wire.maxUploadChunkBytes)
            } catch {
                end(.failed("This phone could not read that file any more."), tellMac: true)
                return
            }
            guard let chunk = slice, !chunk.isEmpty else {
                // The file is shorter than it said. Stopping here would send a
                // truncated file the Mac would then refuse on the byte count; it
                // is clearer to say so from the end that knows why.
                end(.failed("That file changed while it was being sent."), tellMac: true)
                return
            }
            read += chunk.count
            digest.update(data: chunk)
            guard wire?.send(.uploadData(id: id, data: chunk)) == true else {
                end(.failed("The connection dropped."), tellMac: false)
                return
            }
            inFlight += chunk.count
        }
    }

    private func acknowledge(_ bytes: Int) {
        guard case .sending(let path) = phase else { return }
        acked = min(size, acked + bytes)
        inFlight = max(0, inFlight - bytes)
        if acked >= size {
            guard !ended else { return }
            ended = true
            phase = .finishing(path: path)
            let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard wire?.send(.uploadEnd(id: id, sha256: hex)) == true else {
                end(.failed("The connection dropped."), tellMac: false)
                return
            }
            return
        }
        pump()
    }

    // MARK: - Ending

    private func end(_ next: Phase, tellMac: Bool) {
        guard !finished else { return }
        finished = true
        if tellMac { wire?.send(.uploadCancel(id: id)) }
        phase = next
        try? handle?.close()
        handle = nil
        // The picker copied the file into this app's temporary directory, and
        // nothing else will clean it up: iOS empties `tmp` only under storage
        // pressure, so a phone that sent ten videos would be holding two copies
        // of each until then.
        if file.temporary { try? FileManager.default.removeItem(at: file.url) }
    }
}

/**
 * A byte count as a person would say it.
 *
 * Written here rather than reached for through `ByteCountFormatter` because this
 * number appears in refusals — "that paste is 3.4 MB, the most this can send is
 * 1 MB" — and those two figures have to be produced the same way or the sentence
 * reads as nonsense. Decimal units, which is what a phone's storage screen and
 * every file size in the Finder use.
 */
func byteSize(_ bytes: Int) -> String {
    let units = ["bytes", "KB", "MB", "GB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1000 && unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    if unit == 0 { return "\(bytes) bytes" }
    return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
}

/**
 * A path, quoted so a shell reads it as one word.
 *
 * Single quotes, because inside them a shell interprets nothing at all — no
 * `$`, no backtick, no backslash — and a file name really can contain every one
 * of those. The only character that needs care is the quote itself, which is
 * closed, escaped and reopened: `it's` becomes `'it'\''s'`.
 *
 * This is why `safeName` on the desktop deliberately does *not* strip shell
 * punctuation out of people's file names. The hazard is handled here, once, at
 * the point where a path becomes a command line.
 */
func shellQuoted(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
}
