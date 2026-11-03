import AppKit
import Darwin
import Observation
import SwiftUI
import TerminalDeckNativeCore

struct NativeArtifactsSourceRequest: Identifiable, Sendable {
    let projectRoot: String
    let relativePath: String
    let sessionIDs: [String]
    let title: String
    var id: String { projectRoot + "\u{0}" + relativePath }
}

/// A source is proved by a file-writing tool block, never guessed from a chat's
/// text or timestamp. Only that block's public text and matching file excerpt
/// may appear here; reasoning and unrelated tool results are excluded.
struct NativeArtifactsSourceRecord: Sendable, Equatable {
    let transcriptPath: String
    let sessionID: String
    let messageID: String
    let toolUseID: String
    let lineNumber: Int
    let at: Double
    let tool: String
    let text: String
    let excerpt: String
    var id: String { "artifact-source:" + sessionID + ":" + String(lineNumber) + ":" + toolUseID }
}

enum NativeArtifactsSourceFinder {
    static let maximumFileBytes: Int64 = 128 * 1024 * 1024
    static let maximumLineBytes = 16 * 1024 * 1024

    static func failure(_ message: String) -> NSError {
        NSError(domain: "CATALOGSource", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func record(line: Data, lineNumber: Int, transcriptPath: String,
                       sessionID: String, request: NativeArtifactsSourceRequest) -> [NativeArtifactsSourceRecord] {
        guard request.sessionIDs.contains(sessionID),
              line.range(of: Data("tool_use".utf8)) != nil,
              let expected = ArtifactRules.locatedURL(root: request.projectRoot, relPath: request.relativePath),
              let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              raw["type"] as? String == "assistant",
              let message = raw["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        let messageID = message["id"] as? String ?? raw["uuid"] as? String ?? ""
        let stamp = raw["timestamp"] as? String ?? ""
        let at = ((try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
                  ?? (try? Date.ISO8601FormatStyle().parse(stamp)))?.timeIntervalSince1970 ?? 0
        let text = String(content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n\n").prefix(8_000))
        return content.compactMap { block in
            guard block["type"] as? String == "tool_use", let tool = block["name"] as? String,
                  let input = block["input"] as? [String: Any] else { return nil }
            // A file the session never wrote with the Write tool is found where it handed it over:
            // published as a page, sent to the person, or saved by a screenshot tool.
            guard ["Write", "Edit", "NotebookEdit"].contains(tool) else {
                let handed = ArtifactRules.handedOver(tool: tool, string: { input[$0] as? String },
                                                      strings: { (input[$0] as? [Any])?.compactMap { $0 as? String } ?? [] })
                guard handed.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == expected.path }) else { return nil }
                return NativeArtifactsSourceRecord(transcriptPath: transcriptPath, sessionID: sessionID,
                    messageID: messageID, toolUseID: block["id"] as? String ?? "", lineNumber: lineNumber,
                    at: at * 1_000, tool: tool, text: text, excerpt: String((input["caption"] as? String ?? input["description"] as? String ?? "").prefix(8_000)))
            }
            guard let path = input[tool == "NotebookEdit" ? "notebook_path" : "file_path"] as? String,
                  path.hasPrefix("/"), !path.contains("\0"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == expected.path else { return nil }
            let value = input[tool == "Write" ? "content" : tool == "Edit" ? "new_string" : "new_source"] as? String ?? ""
            return NativeArtifactsSourceRecord(transcriptPath: transcriptPath, sessionID: sessionID,
                messageID: messageID, toolUseID: block["id"] as? String ?? "", lineNumber: lineNumber,
                at: at * 1_000, tool: tool, text: text, excerpt: String(value.prefix(8_000)))
        }
    }

    /// Candidates are supplied only by the app's configured transcript owner.
    /// The opened descriptor must remain that exact approved regular file.
    static func find(request: NativeArtifactsSourceRequest, files: [NativeTranscriptFile]) throws -> NativeArtifactsSourceRecord {
        guard ArtifactRules.locatedURL(root: request.projectRoot, relPath: request.relativePath) != nil,
              !request.sessionIDs.isEmpty else { throw failure("This artifact has no recorded conversation.") }
        let candidates = files.filter { request.sessionIDs.contains($0.sessionID) }
        guard !candidates.isEmpty else { throw failure("The conversation that made this file is no longer available here.") }
        guard candidates.count <= 40 else { throw failure("Too many recorded conversations match this file to locate its source safely.") }
        var newest: NativeArtifactsSourceRecord?
        let deadline = Date().addingTimeInterval(8)
        var totalBytes: Int64 = 0
        for file in candidates {
            try Task.checkCancellation()
            let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw failure("The recorded conversation could not be opened.") }
            defer { Darwin.close(fd) }
            var info = stat(), opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= maximumFileBytes,
                  fcntl(fd, F_GETPATH, &opened) == 0,
                  URL(fileURLWithPath: String(decoding: opened.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).standardizedFileURL.path == URL(fileURLWithPath: file.path).standardizedFileURL.path else {
                throw failure("The conversation changed location or is too large to read here.")
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var pending = Data(), bytes: Int64 = 0, lineNumber = 0
            func consume() throws {
                lineNumber += 1
                try Task.checkCancellation()
                if lineNumber % 512 == 0 {
                    guard Date() < deadline else { throw failure("Reading the source took too long. Try Again.") }
                }
                for found in record(line: pending, lineNumber: lineNumber, transcriptPath: file.path,
                                    sessionID: file.sessionID, request: request) {
                    if newest == nil || found.at > newest!.at || (found.at == newest!.at && found.lineNumber >= newest!.lineNumber) {
                        newest = found
                    }
                }
                pending.removeAll(keepingCapacity: true)
            }
            while true {
                try Task.checkCancellation()
                guard Date() < deadline else { throw failure("Reading the source took too long. Try Again.") }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw failure("The recorded conversation could not be read.") }
                if count == 0 { if !pending.isEmpty { try consume() }; break }
                bytes += Int64(count)
                totalBytes += Int64(count)
                guard bytes <= maximumFileBytes, totalBytes <= 256 * 1024 * 1024 else { throw failure("The conversation is too large to read here.") }
                for byte in buffer.prefix(count) {
                    if byte == 10 { try consume() }
                    else {
                        pending.append(byte)
                        guard pending.count <= maximumLineBytes else { throw failure("A message is too large to read here.") }
                    }
                }
            }
        }
        guard let newest else { throw failure("No recorded file-writing message matches this artifact.") }
        return newest
    }
}

@MainActor @Observable
final class NativeArtifactsSourceModel {
    private enum ReadOutcome: Sendable {
        case found(NativeArtifactsSourceRecord, [ChatMessage])
        case failed(String)
        case cancelled
    }
    private(set) var source: NativeArtifactsSourceRecord?
    private(set) var messages: [ChatMessage] = []
    private(set) var error: String?
    private(set) var loading = true
    private var run = 0
    @ObservationIgnored private var sourceWork: Task<ReadOutcome, Never>?

    func load(_ request: NativeArtifactsSourceRequest) async {
        run += 1
        let current = run
        sourceWork?.cancel()
        loading = true; error = nil; source = nil; messages = []
        let work = Task { await read(request) }
        sourceWork = work
        // Reuse the existing one-shot deadline race. Waiting ends at ten seconds
        // even if a filesystem discovery ignores cancellation until it returns.
        let answer = await withTaskCancellationHandler {
            await IntentDeadline.wait(for: work, upTo: .seconds(10))
        } onCancel: { work.cancel() }
        guard current == run else { work.cancel(); return }
        sourceWork = nil; loading = false
        guard !Task.isCancelled else { work.cancel(); return }
        switch answer {
        case .timedOut:
            work.cancel()
            error = "Couldn't read the conversation within 10 seconds. Try Again."
        case .finished(.found(let found, let chat)):
            source = found; messages = chat
        case .finished(.failed(let message)):
            error = message
        case .finished(.cancelled): break
        }
    }

    private func read(_ request: NativeArtifactsSourceRequest) async -> ReadOutcome {
        do {
            // The native transcript owner uses the composition's configured
            // account/home grants. This code never constructs a home/config path.
            var roots = [request.projectRoot] + NativePROJLabels.shared.projects.flatMap(\.folders)
            // Wider artifact scans can find work started in another open root.
            // Its real session folder may outlive the project registry entry.
            if let sessions = try? await EngineBridge.shared.invoke("session:list", [], timeout: 10) as? [[String: Any]] {
                for session in sessions {
                    let identifiers = [session["id"] as? String, session["agentSessionId"] as? String].compactMap { $0 }
                    if identifiers.contains(where: { request.sessionIDs.contains($0) }), let cwd = session["cwd"] as? String {
                        roots.append(cwd)
                    }
                }
            }
            var seenRoots = Set<String>(), filesByPath: [String: NativeTranscriptFile] = [:], sourceRoots: [String: String] = [:]
            roots = roots.filter { $0.hasPrefix("/") && seenRoots.insert($0).inserted }
            guard roots.count <= 64 else { throw NativeArtifactsSourceFinder.failure("There are too many project folders to locate this source safely.") }
            for root in roots {
                try Task.checkCancellation()
                // The configured transcript owner remains the only discovery
                // authority. There is no global config/home directory scan.
                for file in (try? await NativeTranscriptBackend.shared.listTranscripts(cwd: root)) ?? [] {
                    if request.sessionIDs.contains(file.sessionID), filesByPath[file.path] == nil {
                        filesByPath[file.path] = file; sourceRoots[file.path] = root
                        guard filesByPath.count <= 40 else { throw NativeArtifactsSourceFinder.failure("Too many recorded conversations match this file to locate its source safely.") }
                    }
                }
            }
            let files = filesByPath.values.sorted { $0.modifiedAt > $1.modifiedAt }
            let scan = Task.detached(priority: .utility) {
                try NativeArtifactsSourceFinder.find(request: request, files: files)
            }
            let found = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
            guard let sourceRoot = sourceRoots[found.transcriptPath] else {
                throw NativeArtifactsSourceFinder.failure("The recorded conversation has no authorized source folder.")
            }
            let currentFiles = try await NativeTranscriptBackend.shared.listTranscripts(cwd: sourceRoot)
            guard currentFiles.contains(where: { $0.path == found.transcriptPath && $0.sessionID == found.sessionID }) else {
                throw NativeArtifactsSourceFinder.failure("The recorded conversation is no longer available here.")
            }
            let raw = try await EngineBridge.shared.invoke("chat:load", [["transcriptPath": found.transcriptPath]], timeout: 10)
            guard let chat = ChatUpdate.decode(raw), chat.found,
                  chat.transcriptPath == found.transcriptPath else {
                throw NativeArtifactsSourceFinder.failure("The recorded conversation could not be loaded.")
            }
            try Task.checkCancellation()
            return .found(found, chat.messages)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Tool-only messages are excluded by readable chat. Insert that exact
    /// source record in chronological position without inventing readable text.
    var sourceMessageIndex: Int? {
        guard let source, !source.messageID.isEmpty else { return nil }
        // NativeChatTranscriptReader prefixes role onto the provider ID. Some
        // older readers already return the unprefixed provider ID.
        return messages.firstIndex { $0.id == source.messageID || $0.id == "agent:" + source.messageID }
    }

    var sourceInsertion: Int {
        guard let source else { return 0 }
        if let index = sourceMessageIndex { return index + 1 }
        return messages.firstIndex(where: { $0.at > source.at }) ?? messages.count
    }
}

struct NativeArtifactsSourcePreview: View {
    let request: NativeArtifactsSourceRequest
    var onOpenSession: ((String) -> Void)? = nil
    @State private var model = NativeArtifactsSourceModel()
    @Environment(\.dismiss) private var dismiss

    init(request: NativeArtifactsSourceRequest, onOpenSession: ((String) -> Void)? = nil) {
        self.request = request; self.onOpenSession = onOpenSession
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("Where this artifact came from").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if let source = model.source, let onOpenSession {
                    Button("Open session") { onOpenSession(source.sessionID) }
                        .buttonStyle(.bordered)
                }
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }.padding(16)
            Divider()
            content
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 840, minHeight: 420, idealHeight: 560)
        .background(NativeCatalogTokens.card)
        .task(id: request.id) { await model.load(request) }
    }

    @ViewBuilder private var content: some View {
        if model.loading {
            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3))
                        .frame(maxWidth: index.isMultiple(of: 2) ? .infinity : 420).frame(height: 64)
                }
                Spacer(minLength: 0)
            }.padding(20).accessibilityLabel("Loading conversation")
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Couldn't open the conversation", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                DeckRetryButton { Task { await model.load(request) } }.buttonStyle(.bordered)
            }
        } else if let source = model.source {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(0...model.messages.count, id: \.self) { index in
                            if index == model.sourceInsertion { sourceCard(source).id(source.id) }
                            if index < model.messages.count {
                                message(model.messages[index]).id(model.messages[index].id)
                            }
                        }
                    }.padding(20)
                }
                .task(id: source.id) {
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(source.id, anchor: .center)
                }
            }
        }
    }

    private func message(_ value: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(value.role == .you ? "You" : "Assistant").fontWeight(.semibold)
                Spacer()
                Text(ChatRules.time(value.at)).foregroundStyle(.secondary)
            }.font(.system(size: 11))
            Text(value.text).font(.system(size: 13)).textSelection(.enabled)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(value.role == .you ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                    in: .rect(cornerRadius: 10))
    }

    private func sourceCard(_ value: NativeArtifactsSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Artifact source", systemImage: "doc.richtext").fontWeight(.semibold)
                Spacer()
                Text(ChatRules.time(value.at)).foregroundStyle(.secondary)
            }.font(.system(size: 12))
            Text("\(value.tool) · \(ArtifactRules.shownPath(request.relativePath))").font(.system(size: 12, design: .monospaced))
                .lineLimit(2).textSelection(.enabled).help(request.relativePath)
            if !value.text.isEmpty && model.sourceMessageIndex == nil {
                Text(value.text).font(.system(size: 13)).textSelection(.enabled)
            }
            if !value.excerpt.isEmpty {
                Text(value.excerpt).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).lineLimit(20)
            }
            Text("Message \(value.messageID.isEmpty ? "not named" : value.messageID) · line \(value.lineNumber)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .help("Session \(value.sessionID) · tool \(value.toolUseID)")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 1.5))
        .accessibilityLabel("Exact source of \(request.title)")
    }
}
