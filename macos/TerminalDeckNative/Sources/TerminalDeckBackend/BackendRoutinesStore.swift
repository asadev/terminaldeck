import Foundation
import CoreServices
import Darwin
import TerminalDeckNativeCore

public struct BackendRoutinesStoredRoutine: Sendable, Equatable {
    public let id: String, file: String, routine: BackendRoutinesRoutine?, warnings: [String], problems: [String]
    public var ok: Bool { routine != nil }
    public init(id: String, file: String, routine: BackendRoutinesRoutine, warnings: [String] = []) { self.id = id; self.file = file; self.routine = routine; self.warnings = warnings; problems = [] }
    public init(id: String, file: String, problems: [String]) { self.id = id; self.file = file; routine = nil; warnings = []; self.problems = problems }
    public var wire: NativeRPCValue {
        var fields: [(String, NativeRPCValue)] = [("ok", .bool(ok)), ("id", .string(id)), ("file", .string(file))]
        if let routine { fields += [("routine", routine.wire), ("warnings", .array(warnings.map(NativeRPCValue.string)))] }
        else { fields.append(("problems", .array(problems.map(NativeRPCValue.string)))) }
        return BackendRoutinesValues.object(fields)
    }
}

public struct BackendRoutinesTextResult: Sendable, Equatable {
    public let text: String?, file: String?, error: String?
    public var ok: Bool { error == nil }
    public init(text: String, file: String) { self.text = text; self.file = file; error = nil }
    public init(error: String) { text = nil; file = nil; self.error = error }
    public var wire: NativeRPCValue {
        if let error { return BackendRoutinesValues.object([("ok", .bool(false)), ("error", .string(error))]) }
        return BackendRoutinesValues.object([("ok", .bool(true)), ("text", .string(text ?? "")), ("file", .string(file ?? ""))])
    }
}

/// store.ts. The directory is the database; broken files stay visible.
public final class BackendRoutinesStore: @unchecked Sendable {
    public static let maxRoutines = 100, routineExtension = ".md"
    public let directory: URL
    public var dir: String { directory.path }
    private let lock = NSRecursiveLock()
    private var watcher: EventStream?, debounce: DispatchWorkItem?, stopped = false
    private let watchQueue = DispatchQueue(label: "dev.terminaldeck.routines.folder", qos: .utility)
    private var snapshot: [String: Fingerprint] = [:]
    public init(directory: URL? = nil, userData: URL? = nil) {
        self.directory = directory ?? BackendRoutinesPaths.routinesDirFor(userData ?? BackendRoutinesPaths.userData)
    }
    public static func routinesDirFor(_ userData: URL) -> URL { BackendRoutinesPaths.routinesDirFor(userData) }
    public static func routineFilePath(_ dir: String, id: String) throws -> String {
        guard BackendRoutinesFormat.isValidId(id) else { throw NativeRPCError.invalidArguments("routines: `\(id)` is not a usable routine name") }
        return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(id + routineExtension).path
    }
    public func routineFilePath(_ id: String) throws -> String { try Self.routineFilePath(dir, id: id) }
    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func list() -> [BackendRoutinesStoredRoutine] {
        lock.lock(); defer { lock.unlock() }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [BackendRoutinesStoredRoutine] = []
        for name in names.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) where name.hasSuffix(Self.routineExtension) {
            let id = String(name.dropLast(Self.routineExtension.count)), file = directory.appendingPathComponent(name).path
            if !BackendRoutinesFormat.isValidId(id) {
                out.append(.init(id: id, file: file, problems: ["`\(name)` is not a usable routine name. Use lowercase letters, digits and hyphens."])); continue
            }
            if out.count >= Self.maxRoutines {
                out.append(.init(id: id, file: file, problems: ["This folder holds more than \(Self.maxRoutines) routines, so this one was not loaded."])); continue
            }
            do { out.append(try read(id)) }
            catch { out.append(.init(id: id, file: file, problems: ["This routine could not be read: \(error.localizedDescription)"])) }
        }
        return out
    }
    public func read(_ id: String) throws -> BackendRoutinesStoredRoutine {
        lock.lock(); defer { lock.unlock() }
        let file = try routineFilePath(id)
        let text: String
        do { text = try readFile(URL(fileURLWithPath: file)) }
        catch {
            let problem = (error as? NativeRPCError)?.code == "routine-size" ? error.localizedDescription : "This routine could not be read: \(error.localizedDescription)"
            return .init(id: id, file: file, problems: [problem])
        }
        let parsed = BackendRoutinesFormat.parseRoutine(id, text: text)
        if let routine = parsed.routine { return .init(id: id, file: file, routine: routine, warnings: parsed.warnings) }
        return .init(id: id, file: file, problems: parsed.problems)
    }
    public func save(_ routine: BackendRoutinesRoutine) throws -> String {
        lock.lock(); defer { lock.unlock() }; try ensureDir()
        let file = try routineFilePath(routine.id)
        try BackendAccountFiles.writeAtomic(Data(BackendRoutinesFormat.serializeRoutine(routine).utf8), to: URL(fileURLWithPath: file))
        return file
    }
    public func readText(_ id: String) -> BackendRoutinesTextResult {
        lock.lock(); defer { lock.unlock() }
        do { let file = try routineFilePath(id); return .init(text: try readFile(URL(fileURLWithPath: file)), file: file) }
        catch { return .init(error: error.localizedDescription) }
    }
    public func saveText(_ id: String, text: String) throws -> String {
        lock.lock(); defer { lock.unlock() }; try ensureDir()
        let file = try routineFilePath(id)
        // Validity belongs to the API. This writer preserves the person's text.
        try BackendAccountFiles.writeAtomic(Data(text.utf8), to: URL(fileURLWithPath: file)); return file
    }
    public func remove(_ id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; let file = try routineFilePath(id)
        // Node rmSync without recursive removes a file/symlink and refuses a
        // directory. FileManager.removeItem would recursively erase a .md dir.
        return Darwin.unlink(file) == 0
    }
    private func readFile(_ file: URL) throws -> String {
        var info = stat()
        guard stat(file.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if info.st_size > BackendRoutinesFormat.maxFileBytes {
            throw NativeRPCError(code: "routine-size", message: "This file is larger than \(BackendRoutinesFormat.maxFileBytes) bytes.")
        }
        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }
    public func startWatching(onChange: @escaping @Sendable () -> Void, debounceMs: Double = 150) throws {
        lock.lock(); defer { lock.unlock() }
        if watcher != nil || stopped { return }
        try ensureDir(); snapshot = folderSnapshot()
        watcher = try EventStream(path: dir, queue: watchQueue) { [weak self] in
            self?.folderChanged(onChange: onChange, debounceMs: debounceMs)
        }
    }
    private func folderChanged(onChange: @escaping @Sendable () -> Void, debounceMs: Double) {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
        let next = folderSnapshot(); guard next != snapshot else { return }; snapshot = next
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }; self.debounce = nil; onChange()
        }
        debounce = work; watchQueue.asyncAfter(deadline: .now() + max(0, debounceMs) / 1_000, execute: work)
    }
    public func stop() {
        lock.lock(); stopped = true; debounce?.cancel(); debounce = nil
        let old = watcher; watcher = nil; lock.unlock(); old?.stop()
    }
    private struct Fingerprint: Equatable { let size: Int64, modified: Double, inode: UInt64 }
    private func folderSnapshot() -> [String: Fingerprint] {
        var result: [String: Fingerprint] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard let info = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
                  info[.type] as? FileAttributeType != .typeDirectory else { continue }
            result[name] = .init(size: (info[.size] as? NSNumber)?.int64Value ?? 0,
                modified: (info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                inode: (info[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }
        return result
    }
    private final class EventBox: @unchecked Sendable {
        let event: @Sendable () -> Void
        init(_ event: @escaping @Sendable () -> Void) { self.event = event }
    }
    private final class EventStream: @unchecked Sendable {
        private var stream: FSEventStreamRef?
        private let box: EventBox
        init(path: String, queue: DispatchQueue, event: @escaping @Sendable () -> Void) throws {
            box = EventBox(event)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { pointer in guard let pointer else { return nil }; _ = Unmanaged<EventBox>.fromOpaque(pointer).retain(); return pointer },
                release: { pointer in if let pointer { Unmanaged<EventBox>.fromOpaque(pointer).release() } }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                if let info { Unmanaged<EventBox>.fromOpaque(info).takeUnretainedValue().event() }
            }
            guard let reference = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else {
                throw NativeRPCError(code: "routine-watch-unavailable", message: "[routines] the routines folder could not be watched: the native event stream could not be created")
            }
            stream = reference; FSEventStreamSetDispatchQueue(reference, queue)
            guard FSEventStreamStart(reference) else { stop(); throw NativeRPCError(code: "routine-watch-unavailable", message: "[routines] the routines folder could not be watched: the native event stream could not be started") }
        }
        func stop() { guard let reference = stream else { return }; stream = nil; FSEventStreamStop(reference); FSEventStreamInvalidate(reference); FSEventStreamRelease(reference) }
        deinit { stop() }
    }
    deinit { watcher?.stop(); debounce?.cancel() }
}
