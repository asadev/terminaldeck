import Foundation
import Darwin
import TerminalDeckNativeCore

/// Approval questions shown on phones: only enumerated fields cross.
/// Arguments are reserved for a question's actual approvers.
public enum BackendCopilotRemoteWiring {
    private static func phoneSummary(_ request: BackendDeckCoreSecurityConsentRequest) -> String {
        request.askedBy.map { "From “\($0)”: \(request.summary)" } ?? request.summary
    }
    public static func pendingRow(_ request: BackendDeckCoreSecurityConsentRequest, mine: Bool) -> NativeRPCValue {
        .object([.init("id", .string(request.id)), .init("tool", .string(request.tool)), .init("summary", .string(phoneSummary(request))),
            .init("requestedAt", .number(request.requestedAt)), .init("expiresAt", .number(request.expiresAt)), .init("mine", .bool(mine))])
    }
    public static func consentQuestion(_ request: BackendDeckCoreSecurityConsentRequest) -> NativeRPCValue {
        .object([.init("id", .string(request.id)), .init("tool", .string(request.tool)), .init("tier", .string(request.tier.rawValue)),
            .init("summary", .string(phoneSummary(request))), .init("args", request.arguments),
            .init("origin", .string(request.origin.hasPrefix("key:") ? request.label ?? request.origin : request.origin)),
            .init("requestedAt", .number(request.requestedAt)), .init("expiresAt", .number(request.expiresAt))])
    }
}

public struct BackendCopilotRemoteChatUpdate: Sendable {
    public let messages: [NativeRPCValue]
    public let reset: Bool
    public init(messages: [NativeRPCValue], reset: Bool) { self.messages = messages; self.reset = reset }
}

/// Real OS event watch, with the source's 2-second discovery fallback only
/// while a brand-new transcript directory/file does not exist. It ceases once
/// the exact named file is attached. No terminal bytes ever leave this reader.
public actor BackendCopilotRemoteChatWatcher {
    private let cwd: String
    private let sessionID: String?
    private let scope: NativeTranscriptScope
    private let update: @Sendable (BackendCopilotRemoteChatUpdate) async -> Void
    private var reader: NativeChatTranscriptReader?
    private var watches: [BackendCopilotRemoteFileWatch] = []
    private var fileWatch: BackendCopilotRemoteFileWatch?
    private var discovery: Task<Void, Never>?
    private var stopped = false
    private var attaching = false
    private var reading = false
    private var again = false
    public init(cwd: String, agentSessionID: String? = nil, scope: NativeTranscriptScope,
                update: @escaping @Sendable (BackendCopilotRemoteChatUpdate) async -> Void) {
        self.cwd = cwd; sessionID = agentSessionID; self.scope = scope; self.update = update
    }
    public func start() async throws {
        guard !stopped, watches.isEmpty, discovery == nil else { return }
        let directories = try NativeTranscriptPaths.projectDirectories(cwd, scope: scope)
        for directory in directories {
            if let watch = BackendCopilotRemoteFileWatch(path: directory, changed: { [weak self] in Task { await self?.attach() } }) { watches.append(watch) }
        }
        discovery = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }; await self.attach()
            }
        }
        await attach()
    }
    public func stop() {
        stopped = true; discovery?.cancel(); discovery = nil
        fileWatch?.close(); fileWatch = nil
        for watch in watches { watch.close() }; watches.removeAll(); reader = nil
    }
    private func attach() async {
        guard !stopped, reader == nil, !attaching else { return }
        attaching = true; defer { attaching = false }
        do {
            let path: String?
            if let sessionID {
                path = try NativeTranscriptPaths.projectDirectories(cwd, scope: scope).lazy.map {
                    URL(fileURLWithPath: $0).appendingPathComponent(sessionID + ".jsonl").path
                }.first { FileManager.default.fileExists(atPath: $0) }
            } else { path = try NativeTranscriptPaths.newest(cwd, scope: scope)?.path }
            guard !stopped, let path else { return }
            let checked = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
            // Install the watch before reading, avoiding a missed append between them.
            guard let watch = BackendCopilotRemoteFileWatch(path: checked, changed: { [weak self] in Task { await self?.drain() } }) else { return }
            fileWatch = watch
            reader = NativeChatTranscriptReader(path: checked, sessionID: sessionID, allowedRoots: try NativeTranscriptPaths.approvedRoots(scope))
            discovery?.cancel(); discovery = nil
            await drain()
        } catch { /* Local filesystem errors do not put a home path on the wire. */ }
    }
    private func drain() async {
        guard !stopped else { return }
        if reading { again = true; return }
        reading = true; defer { reading = false; again = false }
        do {
            repeat {
                again = false
                guard !stopped, let reader else { return }
                let chunk = try await reader.readAll()
                guard !stopped else { return }
                if !chunk.messages.isEmpty || chunk.reset {
                    let messages = chunk.messages.map { message in
                        NativeRPCValue.object([.init("id", .string(message.id)), .init("role", .string(message.role.rawValue)),
                            .init("text", .string(message.text)), .init("at", .number(message.at))])
                    }
                    await update(.init(messages: messages, reset: chunk.reset))
                }
            } while again
        } catch { /* Keep the run alive; transcript failure is a quiet chat, not PTY input. */ }
    }
}
private final class BackendCopilotRemoteFileWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var source: (any DispatchSourceFileSystemObject)?
    init?(path: String, changed: @escaping @Sendable () -> Void) {
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .global(qos: .utility))
        self.source = source; source.setEventHandler(handler: changed)
        source.setCancelHandler { Darwin.close(fd) }; source.resume()
    }
    func close() { lock.lock(); let old = source; source = nil; lock.unlock(); old?.cancel() }
    deinit { close() }
}
