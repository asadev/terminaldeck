import Foundation
import Darwin
import TerminalDeckNativeCore

/// A paired phone's Files (#27, Asad 3 Nov: "everything should be like same as you own it, all the access"): the
/// remote `files` capability (`files.list`, `files.read`). Every native Mac declared it and none served it, so the
/// Files page on the person's own phone stayed hidden.
///
/// The person's own device walks and reads the whole Mac, as this Mac's own file browser can: any folder, files and
/// dot-files alike, and any file's text. A guest is never offered it and is refused (policy `.ownerOnly`): it reads
/// file contents, so a guest holding it could read a key out of a folder it was never lent.
///
/// Answers fit one phone frame (a phone ends the connection on an oversized message): a folder is listed in parts up to
/// the frame budget, and a file is read in windows the phone asks for one after another.
///
/// Parts of a folder (phone-files-27): every answer says where it starts (`from`), how many rows the folder has
/// (`total`) and, while rows are left, where the next part starts (`next`). The phone asks `files.list` again with
/// `from: next` as the person scrolls. The order is the same on every ask (folders first, then Finder's name order),
/// so `from` is a place in one list. `~` is this Mac's home folder, where the phone's Files opens.
public struct BackendPhoneFiles: Sendable {
    public static let messages: Set<String> = ["files.list", "files.read"]
    public static let guestRefusal = "Only one of the owner’s own devices may read files on this Mac."
    /// A named pipe, a socket or a device: nothing a phone can read as a file.
    public static let notAFile = "That is not a file this phone can read."
    /// The phones' cap on an ordinary message: 64 KiB of JSON (iOS `Wire.maxMessageBytes`, Android
    /// `Protocol.MAX_MESSAGE_BYTES`, this Mac's `limits["MAX_MESSAGE_BYTES"]`). Only `browser.frame` and `sims.frame` may be
    /// bigger; a phone drops anything else over it ("frame over the message limit").
    public static let phoneMessageLimit = BackendRemoteProtocol.limits["MAX_MESSAGE_BYTES"] ?? 64 * 1024
    /// What one answer may take, as sent: under the phones' cap with room for the reply id the host stamps on it and
    /// for sealing (review-install-27 #7: this was 80 KiB, so Android dropped a big folder's first part and every
    /// text window over 64 KiB, and spun on "No answer from Mac").
    static let frameBudget = 56 * 1024
    /// The most one read returns (the phones ask for 64 KiB; a window is cut to what fits `frameBudget`).
    static let maxRead = 64 * 1024
    static let maxEntries = 2000

    /// This Mac's home folder: what `~` means in an asked path.
    let home: String

    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "files", messageTypes: Self.messages, policy: .ownerOnly) { message, context in
            // The host already refuses a guest (.ownerOnly); this is the same rule where the bytes are read.
            guard context.kind == .mine, context.reach.unrestricted else {
                throw NativeRPCError(code: "unauthorized", message: Self.guestRefusal)
            }
            let path = message["path"].string ?? ""
            if message.type == "files.list" { return [try Self.list(path, from: Int(message["from"].number ?? 0), home: home)] }
            return [try Self.read(path, at: Int(message["at"].number ?? 0), max: Int(message["max"].number ?? Double(Self.maxRead)), home: home)]
        }
    }

    /// One part of a folder's files and folders, from row `from`: folders first, then names in Finder's order. Dot-files
    /// are kept (this is looking at the Mac, where `.env` or `.gitignore` is often what someone came for). A part holds
    /// as many rows as fit one phone frame; `next` says where the following part starts, absent on the last part.
    static func list(_ asked: String, from: Int = 0, home: String = NSHomeDirectory()) throws -> BackendRemoteServerMessage {
        let here = try absolute(asked, home: home)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: here, isDirectory: &isFolder), isFolder.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: here) else {
            throw NativeRPCError(code: "unavailable", message: "That folder could not be read on this Mac.")
        }
        // The whole folder's order first (one stat per name), the details only for the rows this part sends.
        var kinds: [(name: String, directory: Bool)] = names.map { name in
            var folder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: (here as NSString).appendingPathComponent(name), isDirectory: &folder)
            return (name, exists && folder.boolValue)
        }
        kinds.sort { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let start = Swift.max(0, Swift.min(from, kinds.count))
        var entries: [NativeRPCValue] = [], used = 640 + here.utf8.count * 2, index = start
        while index < kinds.count, entries.count < Self.maxEntries {
            let row = Self.row(in: here, kinds[index].name, directory: kinds[index].directory)
            let size = (try? row.encodedJSON().count) ?? 512
            guard entries.isEmpty || used + size + 1 <= Self.frameBudget else { break }
            used += size + 1; entries.append(row); index += 1
        }
        let up = (here as NSString).deletingLastPathComponent
        // Measured as it is sent; a part that still comes out over the budget gives back rows until it fits.
        while true {
            var fields: [NativeRPCValue.Field] = [.init("path", .string(here)), .init("parent", here == "/" || up == here ? .null : .string(up)),
                .init("entries", .array(entries)), .init("from", .number(Double(start))), .init("total", .number(Double(kinds.count)))]
            if start + entries.count < kinds.count { fields.append(.init("next", .number(Double(start + entries.count)))) }
            let part = try BackendRemoteServerMessage(.fileRows, fields: fields)
            if entries.count <= 1 || Self.sentSize(part) <= Self.frameBudget { return part }
            entries.removeLast(Swift.max(1, entries.count / 10))
        }
    }

    /// An answer's size as the phone receives it.
    static func sentSize(_ message: BackendRemoteServerMessage) -> Int {
        ((try? BackendRemoteProtocol.serialize(message)) ?? "").utf8.count
    }

    /// One row: its name and full path, folder or file, whether this account can open it, and a file's size and time.
    /// A named pipe, a socket or a device says which in `special` ("pipe", "socket", "device") and has no size or time,
    /// so the phone draws it as "Not a file" without asking (Decker, 4 Nov). A link is judged by what it points to.
    private static func row(in here: String, _ name: String, directory: Bool) -> NativeRPCValue {
        let full = (here as NSString).appendingPathComponent(name)
        var fields: [NativeRPCValue.Field] = [.init("name", .string(name)), .init("path", .string(full)),
            .init("directory", .bool(directory)), .init("readable", .bool(FileManager.default.isReadableFile(atPath: full)))]
        var info = stat()
        if !directory, stat(full, &info) == 0, let kind = special(info.st_mode) {
            fields.append(.init("special", .string(kind)))
            return .object(fields)
        }
        if !directory, let meta = try? FileManager.default.attributesOfItem(atPath: full) {
            if let size = meta[.size] as? NSNumber { fields.append(.init("size", .number(size.doubleValue))) }
            if let at = meta[.modificationDate] as? Date { fields.append(.init("at", .number((at.timeIntervalSince1970 * 1000).rounded()))) }
        }
        return .object(fields)
    }

    /// What a file that is not a plain file is, in the word the phones know; nil for a plain file (or a folder).
    static func special(_ mode: mode_t) -> String? {
        switch mode & S_IFMT {
        case S_IFIFO: return "pipe"
        case S_IFSOCK: return "socket"
        case S_IFCHR, S_IFBLK: return "device"
        default: return nil
        }
    }

    /// One window of a file from `at`. Binary is decided from the bytes (a NUL in what was read), never from a name;
    /// a binary file answers with no text. A character cut by the window's end waits for the next window, so the
    /// phone's next read (from `at` plus the text's bytes) starts exactly where this one stopped.
    static func read(_ asked: String, at: Int, max: Int, home: String = NSHomeDirectory()) throws -> BackendRemoteServerMessage {
        let path = try absolute(asked, home: home)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            throw NativeRPCError(code: "unavailable", message: "That file could not be read on this Mac.")
        }
        guard !isFolder.boolValue else { throw NativeRPCError(code: "unavailable", message: "That is a folder, not a file.") }
        // Opened without waiting and read only when it is a plain file (review-install-27 #8). A named pipe would wait
        // in open(2) for a writer, inside the host, and freeze every paired device; a device file never ends.
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeRPCError(code: "unavailable", message: "That file could not be read on this Mac.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw NativeRPCError(code: "unavailable", message: Self.notAFile)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let total = Int(info.st_size), start = Swift.max(0, Swift.min(at, total))
        // Plain text fits the budget at the first try; text full of characters JSON escapes is halved below.
        var want = Swift.max(0, Swift.min(Swift.max(1, max), Self.maxRead, Self.frameBudget - 2048, total - start))
        while true {
            try handle.seek(toOffset: UInt64(start))
            let bytes = (try handle.read(upToCount: want)) ?? Data()
            var binary = bytes.contains(0), text = "", more = false
            if !binary {
                // A character the window's end cut (up to three bytes) waits for the next window, so the text the
                // phone counts is exactly the bytes it read. Text that is not UTF-8 at all is shown as binary, never garbled.
                var cut = bytes, decoded = String(data: cut, encoding: .utf8), trims = 0
                while decoded == nil, trims < 3, !cut.isEmpty { cut.removeLast(); trims += 1; decoded = String(data: cut, encoding: .utf8) }
                // Not UTF-8 from here (even when only the last bytes of the file are a broken character): said as
                // binary from this offset, so the phone keeps what it showed and says the rest is not text, never a
                // file that silently ends short (review-install-27 S-D6).
                if decoded == nil || (cut.isEmpty && !bytes.isEmpty) { binary = true }
                else { text = decoded ?? ""; more = start + cut.count < total }
            }
            let message = try BackendRemoteServerMessage(.fileText, fields: [.init("path", .string(path)), .init("text", .string(text)),
                .init("at", .number(Double(start))), .init("truncated", .bool(more)), .init("binary", .bool(binary))])
            // Text full of characters JSON escapes grows past one frame: send a smaller window instead.
            if Self.sentSize(message) <= Self.frameBudget || want <= 1024 { return message }
            want /= 2
        }
    }

    /// A full path with `.` and `..` resolved and nothing else changed (Foundation's standardizing would also turn
    /// /private/var into /var, a different spelling than the one the phone asked for). Any folder on this Mac; `~` and
    /// `~/…` are in this Mac's home folder (the phone does not know where that is, and opens Files there).
    static func absolute(_ asked: String, home: String = NSHomeDirectory()) throws -> String {
        var asked = asked
        if asked == "~" || asked.hasPrefix("~/") { asked = home + asked.dropFirst() }
        guard asked.hasPrefix("/") else { throw NativeRPCError(code: "bad-message", message: "Choose a file or folder by its full path.") }
        var parts: [Substring] = []
        for part in asked.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}
