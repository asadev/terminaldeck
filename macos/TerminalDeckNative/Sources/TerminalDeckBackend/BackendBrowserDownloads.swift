import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendBrowserDownloadDestination: Sendable, Equatable {
    public var machineId: String
    public var machineName: String
    public var folder: String
    public init(machineId: String = "", machineName: String = "", folder: String = "") {
        self.machineId = machineId; self.machineName = machineName; self.folder = folder
    }
    public var wireValue: NativeRPCValue { .object([
        .init("machineId", .string(machineId)), .init("machineName", .string(machineName)), .init("folder", .string(folder))
    ]) }
    public static func read(_ value: NativeRPCValue) throws -> Self {
        _ = try value.requireObject("download destination")
        func text(_ key: String) throws -> String {
            value[key].isNullish ? "" : try value[key].requireString(key)
        }
        let result = try Self(machineId: text("machineId"), machineName: text("machineName"), folder: text("folder"))
        guard ![result.machineId, result.machineName, result.folder].contains(where: {
            $0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }) else { throw NativeRPCError.invalidArguments("A download destination cannot contain control characters.") }
        if result.machineId.isEmpty, !result.folder.isEmpty { _ = try BackendBrowserDownloadsStorage.validPath(result.folder) }
        return result
    }
}

/// Obtained from the app's live tab/session binding, never from tool arguments.
/// Stored binding metadata is still reauthorized against current live grants.
public struct BackendBrowserDownloadBinding: Sendable, Equatable {
    public let tabID: String
    public let profileID: String
    public let sessionID: String?
    public let machineID: String
    public let origin: URL?
    public init(tabID: String, profileID: String, sessionID: String? = nil, machineID: String = "", origin: URL? = nil) {
        self.tabID = tabID; self.profileID = profileID; self.sessionID = sessionID; self.machineID = machineID; self.origin = origin
    }
    public var wireValue: NativeRPCValue { .object([
        .init("tabID", .string(tabID)), .init("profileID", .string(profileID)),
        .init("sessionID", sessionID.map(NativeRPCValue.string) ?? .null),
        .init("machineID", .string(machineID)), .init("origin", origin.map { .string($0.absoluteString) } ?? .null)
    ]) }
    static func read(_ raw: NativeRPCValue) -> Self? {
        guard let tab = raw["tabID"].string, let profile = raw["profileID"].string, !tab.isEmpty, !profile.isEmpty else { return nil }
        return Self(tabID: tab, profileID: profile, sessionID: raw["sessionID"].string, machineID: raw["machineID"].string ?? "",
                    origin: raw["origin"].string.flatMap(URL.init(string:)))
    }
}

public struct BackendBrowserDownloadRow: Sendable, Equatable {
    public enum State: String, Sendable { case downloading, delivering, done, cancelled, failed }
    public var id: String
    public var name: String
    public var url: String
    public var bytes: Int64
    public var received: Int64
    public var state: State
    public var path: String
    public var onMachine: String
    public var onMachineName: String
    public var message: String
    public var startedAt: Double
    public var digest: String
    public var binding: BackendBrowserDownloadBinding?
    public var wireValue: NativeRPCValue { .object([
        .init("id", .string(id)), .init("name", .string(name)), .init("url", .string(url)),
        .init("bytes", .number(Double(bytes))), .init("received", .number(Double(received))),
        .init("state", .string(state.rawValue)), .init("path", .string(path)),
        .init("onMachine", .string(onMachine)), .init("onMachineName", .string(onMachineName)),
        .init("message", .string(message)), .init("startedAt", .number(startedAt)), .init("digest", .string(digest)),
        .init("binding", binding?.wireValue ?? .null)
    ]) }
    static func read(_ raw: NativeRPCValue, closedMessage: String) -> Self? {
        guard let id = raw["id"].string, !id.isEmpty else { return nil }
        let state = State(rawValue: raw["state"].string ?? "") ?? .failed
        let moving = state == .downloading || state == .delivering
        func count(_ key: String) -> Int64 {
            let value = max(0, raw[key].number ?? 0)
            return value >= Double(Int64.max) ? Int64.max : Int64(value)
        }
        return Self(id: id, name: raw["name"].string ?? "", url: raw["url"].string ?? "",
                    bytes: count("bytes"), received: count("received"), state: moving ? .failed : state,
                    path: raw["path"].string ?? "", onMachine: raw["onMachine"].string ?? "",
                    onMachineName: raw["onMachineName"].string ?? "", message: moving ? closedMessage : raw["message"].string ?? "",
                    startedAt: max(0, raw["startedAt"].number ?? 0), digest: raw["digest"].string ?? "", binding: BackendBrowserDownloadBinding.read(raw["binding"]))
    }
}

public struct BackendBrowserDownloadsView: Sendable {
    public let destination: BackendBrowserDownloadDestination
    public let defaultFolder: String
    public let items: [BackendBrowserDownloadRow]
    /// Optional extension to the old wire contract; a disk failure is visible.
    public let persistenceMessage: String
    public var wireValue: NativeRPCValue { .object([
        .init("destination", destination.wireValue), .init("defaultFolder", .string(defaultFolder)),
        .init("items", .array(items.map(\.wireValue))), .init("persistenceMessage", .string(persistenceMessage))
    ]) }
}

public struct BackendBrowserDownloadsAccess: Sendable {
    public enum Operation: String, Sendable { case restore, list, inspect, start, receive, cancel, clear, open, reveal, destination, folder, deliver }
    public let operation: Operation
    public let tier: BackendMCPTier
    public let row: BackendBrowserDownloadRow?
    public let binding: BackendBrowserDownloadBinding?
    public let destination: BackendBrowserDownloadDestination?
    public init(_ operation: Operation, tier: BackendMCPTier, row: BackendBrowserDownloadRow? = nil,
                binding: BackendBrowserDownloadBinding? = nil, destination: BackendBrowserDownloadDestination? = nil) {
        self.operation = operation; self.tier = tier; self.row = row; self.binding = binding ?? row?.binding; self.destination = destination
    }
}

public struct BackendBrowserDownloadOperationReply: Sendable {
    public let ok: Bool
    public let message: String
    public init(ok: Bool, message: String = "") { self.ok = ok; self.message = message }
    public var wireValue: NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message))]) }
}

public struct BackendBrowserDownloadDelivery: Sendable {
    public let downloadID: String
    public let source: URL
    public let destination: BackendBrowserDownloadDestination
    public let digest: String
    public let binding: BackendBrowserDownloadBinding?
    public let cancellation: BackendMCPCancellation
    /// Read the actual completed inode through its retained parent descriptor.
    /// The supplied transport must use this instead of reopening source.path.
    public let openSource: @Sendable () throws -> FileHandle
}

public enum BackendBrowserDownloadDeliveryOutcome: Sendable {
    /// The injected transport must confirm actual remote placement before this.
    case delivered(path: String)
    case failed(message: String)
}

public struct BackendBrowserDownloadsDependencies: Sendable {
    public typealias Authorization = @Sendable (NativeRPCContext, BackendBrowserDownloadsAccess) async throws -> Void
    public let authorize: Authorization
    public let open: @Sendable (URL) async throws -> BackendBrowserDownloadOperationReply
    public let reveal: @Sendable (URL) async throws -> BackendBrowserDownloadOperationReply
    public let chooseFolder: @Sendable (URL) async throws -> String
    public let deliver: (@Sendable (BackendBrowserDownloadDelivery) async throws -> BackendBrowserDownloadDeliveryOutcome)?
    public init(authorize: @escaping Authorization,
                open: @escaping @Sendable (URL) async throws -> BackendBrowserDownloadOperationReply,
                reveal: @escaping @Sendable (URL) async throws -> BackendBrowserDownloadOperationReply,
                chooseFolder: @escaping @Sendable (URL) async throws -> String,
                deliver: (@Sendable (BackendBrowserDownloadDelivery) async throws -> BackendBrowserDownloadDeliveryOutcome)? = nil) {
        self.authorize = authorize; self.open = open; self.reveal = reveal; self.chooseFolder = chooseFolder; self.deliver = deliver
    }
}

/// The Mac's authoritative downloads ledger. The WebKit adapter supplies real
/// transport events; this actor owns naming, state, integrity and destinations.
public actor BackendBrowserDownloads {
    public static let maximumRows = 100
    public static let eventChannel = "browser:downloads"
    public struct TransportTicket: Sendable {
        public let id: String
        public let stagingURL: URL
        public let plannedURL: URL
        fileprivate let nonce: UUID
    }
    private struct Active: Sendable {
        let nonce: UUID
        let context: NativeRPCContext
        let destination: BackendBrowserDownloadDestination
        let reservation: BackendBrowserDownloadsStorage.Reservation
        let cancel: @Sendable () async -> Void
    }
    private struct Subscriber: Sendable {
        let context: NativeRPCContext
        let continuation: AsyncThrowingStream<BackendBrowserDownloadsView, any Error>.Continuation
    }
    private let root: URL
    private let defaultFolder: URL
    private let applicationName: String
    private let dependencies: BackendBrowserDownloadsDependencies
    private var loaded = false
    private var loading = false
    private var rows: [BackendBrowserDownloadRow] = []
    private var destination = BackendBrowserDownloadDestination()
    private var active: [String: Active] = [:]
    private var landed: [String: BackendBrowserDownloadsStorage.LandedFile] = [:]
    private var reserved: [String: Set<String>] = [:]
    private var deliveries: [String: (cancellation: BackendMCPCancellation, task: Task<Void, Never>)] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var persistenceMessage = ""

    /// Explicit roots and inert construction. This does not read app data,
    /// Downloads, credentials, live WKWebViews or global process state.
    public init(dataRoot: URL, defaultFolder: URL, applicationName: String, dependencies: BackendBrowserDownloadsDependencies) throws {
        guard dataRoot.isFileURL, defaultFolder.isFileURL, !applicationName.isEmpty else { throw NativeRPCError.invalidArguments("Downloads need explicit file roots and the app's name.") }
        root = try BackendBrowserDownloadsStorage.validPath(dataRoot.path)
        self.defaultFolder = try BackendBrowserDownloadsStorage.validPath(defaultFolder.path)
        self.applicationName = applicationName; self.dependencies = dependencies
    }

    public func restore(context: NativeRPCContext) async throws {
        try await authorize(context, .init(.restore, tier: .read))
        guard !loaded else { return }
        guard !loading else { throw NativeRPCError(code: "download-loading", message: "Download history is already loading.") }
        loading = true; defer { loading = false }
        do {
            if let bytes = try BackendBrowserDownloadsStorage.readLedger(root: root) {
                let raw = try NativeRPCValue.parseJSON(bytes, maximumBytes: 4 * 1024 * 1024)
                destination = (try? .read(raw["destination"])) ?? .init()
                var seen = Set<String>()
                rows = (raw["items"].elements ?? []).compactMap {
                    BackendBrowserDownloadRow.read($0, closedMessage: "\(applicationName) closed while this was moving.")
                }.filter { seen.insert($0.id).inserted }
                rows = Array(rows.prefix(Self.maximumRows))
            }
        } catch { persistenceMessage = "Download history could not be restored: \(error.localizedDescription)" }
        loaded = true
        await publish()
    }

    public func view(context: NativeRPCContext) async throws -> BackendBrowserDownloadsView {
        try requireLoaded()
        try await authorize(context, .init(.list, tier: .read, destination: destination))
        var visible: [BackendBrowserDownloadRow] = []
        for row in rows {
            do { try await authorize(context, .init(.inspect, tier: .read, row: row)); visible.append(row) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        // Destination paths are themselves private state. List authorization
        // must cover them, and inspect additionally gates each row's binding.
        return .init(destination: destination, defaultFolder: defaultFolder.path, items: visible, persistenceMessage: persistenceMessage)
    }

    public func updates(context: NativeRPCContext) async throws -> AsyncThrowingStream<BackendBrowserDownloadsView, any Error> {
        let initial = try await view(context: context)
        let id = UUID()
        let pair = AsyncThrowingStream<BackendBrowserDownloadsView, any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        subscribers[id] = .init(context: context, continuation: pair.continuation)
        pair.continuation.yield(initial)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return pair.stream
    }
    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    public func row(_ id: String, context: NativeRPCContext) async throws -> BackendBrowserDownloadRow {
        try requireLoaded()
        guard let row = rows.first(where: { $0.id == id }) else { throw NativeRPCError(code: "download-missing", message: "That download is not in the list any more.") }
        try await authorize(context, .init(.inspect, tier: .read, row: row))
        return row
    }

    public func setDestination(_ next: BackendBrowserDownloadDestination, context: NativeRPCContext) async throws -> BackendBrowserDownloadsView {
        try requireLoaded()
        let next = try BackendBrowserDownloadDestination.read(next.wireValue)
        try await authorize(context, .init(.destination, tier: .alter, destination: next))
        if !next.machineId.isEmpty, dependencies.deliver == nil {
            throw NativeRPCError(code: "download-delivery-unavailable", message: "The native app has no supplied file delivery transport for another machine.")
        }
        if next.machineId.isEmpty {
            let dir = try BackendBrowserDownloadsStorage.directory(next.folder.isEmpty ? defaultFolder : URL(fileURLWithPath: next.folder), create: true)
            Darwin.close(dir)
        }
        destination = next; save(); await publish()
        return try await view(context: context)
    }

    public func chooseFolder(context: NativeRPCContext, attended: Bool) async throws -> String {
        try requireLoaded()
        guard attended else { throw NativeRPCError(code: "not-permitted-unattended", message: "The folder chooser needs a person at this Mac. Name the folder instead.") }
        try await authorize(context, .init(.folder, tier: .alter, destination: destination))
        let current = destination.machineId.isEmpty && !destination.folder.isEmpty ? URL(fileURLWithPath: destination.folder) : defaultFolder
        let chosen = try await dependencies.chooseFolder(current)
        try Task.checkCancellation()
        if !chosen.isEmpty { _ = try BackendBrowserDownloadsStorage.validPath(chosen) }
        return chosen
    }

    public func openDownloadsFolder(context: NativeRPCContext) async throws -> BackendBrowserDownloadOperationReply {
        try requireLoaded()
        try await authorize(context, .init(.open, tier: .act, destination: destination))
        let folder = destination.machineId.isEmpty && !destination.folder.isEmpty ? URL(fileURLWithPath: destination.folder) : defaultFolder
        let fd = try BackendBrowserDownloadsStorage.directory(folder, create: false); Darwin.close(fd)
        return try await dependencies.open(folder)
    }

    /// Only a trusted live-tab adapter may mint this transport capability. The
    /// nonce and staging URL never appear in tool/channel responses or events.
    public func begin(context: NativeRPCContext, binding: BackendBrowserDownloadBinding, suggested: String, source: URL?,
                      expected: Int64, cancel: @escaping @Sendable () async -> Void) async throws -> TransportTicket {
        try requireLoaded()
        guard !binding.tabID.isEmpty, !binding.profileID.isEmpty else { throw NativeRPCError.invalidArguments("A download needs its real tab and browser profile binding.") }
        let id = "dl-" + UUID().uuidString.lowercased()
        let bound = destination
        let folder = bound.machineId.isEmpty && !bound.folder.isEmpty ? URL(fileURLWithPath: bound.folder) : defaultFolder
        var row = BackendBrowserDownloadRow(id: id, name: BrowserDownloadNaming.name(suggested), url: source?.absoluteString ?? "",
                    bytes: max(0, expected), received: 0, state: .downloading, path: "", onMachine: "", onMachineName: "",
                    message: "", startedAt: Date().timeIntervalSince1970 * 1000, digest: "", binding: binding)
        try await authorize(context, .init(.start, tier: .act, row: row, destination: bound))
        do {
            let held = try BackendBrowserDownloadsStorage.Reservation(folder: folder, suggested: suggested, taken: reserved[folder.path] ?? [])
            reserved[folder.path, default: []].insert(held.finalName)
            let nonce = UUID()
            active[id] = Active(nonce: nonce, context: context, destination: bound, reservation: held, cancel: cancel)
            // A final path is not advertised before it contains a complete file.
            rows.insert(row, at: 0); trim(); save(); await publish()
            return TransportTicket(id: id, stagingURL: held.stageURL, plannedURL: folder.appendingPathComponent(held.finalName), nonce: nonce)
        } catch {
            row.state = .failed; row.message = "That folder could not be written to: \(error.localizedDescription)"
            rows.insert(row, at: 0); trim(); save(); await publish(); await cancel(); throw error
        }
    }

    /// WebKit reports download redirects before or after choosing a destination.
    /// A live-tab adapter supplies identity; the proposed URL is checked against
    /// exact-origin/profile and destination grants before WebKit follows it.
    public func authorizeRedirect(context: NativeRPCContext, binding: BackendBrowserDownloadBinding, url: URL) async throws {
        try requireLoaded()
        let proposed = BackendBrowserDownloadRow(id: "", name: "", url: url.absoluteString, bytes: 0, received: 0,
            state: .downloading, path: "", onMachine: "", onMachineName: "", message: "", startedAt: 0, digest: "", binding: binding)
        try await authorize(context, .init(.receive, tier: .act, row: proposed, destination: destination))
    }

    public func progress(_ ticket: TransportTicket, received: Int64, expected: Int64) async throws {
        let held = try await receive(ticket)
        guard active[ticket.id]?.nonce == held.nonce else { return }
        patch(ticket.id) { $0.received = max(0, received); $0.bytes = max(0, expected) }
        await publish()
    }

    public func finish(_ ticket: TransportTicket) async throws {
        let held = try await receive(ticket)
        guard active[ticket.id]?.nonce == held.nonce else { return }
        do {
            let receipt = try held.reservation.commit(taken: reserved[held.reservation.folder.path] ?? [])
            reserved[receipt.folder.path, default: []].insert(receipt.name)
            active[ticket.id] = nil; landed[ticket.id] = receipt
            patch(ticket.id) {
                $0.path = receipt.url.path; $0.name = receipt.name; $0.received = receipt.size
                if $0.bytes == 0 { $0.bytes = receipt.size }
                $0.state = held.destination.machineId.isEmpty ? .done : .delivering
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.sealAndDeliver(ticket.id, receipt: receipt, held: held)
            }
            deliveries[ticket.id] = (BackendMCPCancellation(), task)
            save(); await publish()
        } catch {
            active[ticket.id] = nil
            patch(ticket.id) { $0.state = .failed; $0.message = error.localizedDescription; $0.path = held.reservation.stageURL.path }
            // A failed final placement retains the private payload for recovery.
            save(); await publish(); throw error
        }
    }

    public func fail(_ ticket: TransportTicket, message: String, cancelled: Bool = false) async {
        guard let held = active[ticket.id], held.nonce == ticket.nonce else { return }
        active[ticket.id] = nil; held.reservation.cleanup()
        patch(ticket.id) { $0.state = cancelled ? .cancelled : .failed; $0.message = cancelled ? "Stopped." : message; $0.path = "" }
        save(); await publish()
    }

    public func cancel(_ id: String, context: NativeRPCContext) async throws -> BackendBrowserDownloadsView {
        let row = try await row(id, context: context)
        try await authorize(context, .init(.cancel, tier: .act, row: row))
        if let held = active.removeValue(forKey: id) {
            // Wait for the real transport's cancellation before removing its
            // staging entry, so WebKit cannot leave a fresh file behind it.
            await held.cancel(); held.reservation.cleanup()
            patch(id) { $0.state = .cancelled; $0.message = "Stopped." }
            save(); await publish()
        } else if let delivery = deliveries[id], row.state == .delivering {
            delivery.cancellation.cancel(); delivery.task.cancel()
            patch(id) { $0.state = .cancelled; $0.message = "Delivery stopped. The local file was kept." }
            save(); await publish()
        }
        return try await view(context: context)
    }

    public func clear(context: NativeRPCContext) async throws -> BackendBrowserDownloadsView {
        try requireLoaded()
        try await authorize(context, .init(.clear, tier: .alter))
        let visible = try await view(context: context)
        let ids = Set(visible.items.filter { $0.state != .downloading && $0.state != .delivering }.map(\.id))
        rows.removeAll { ids.contains($0.id) }
        for id in ids { landed[id] = nil }
        save(); await publish()
        return try await view(context: context)
    }

    public func open(_ id: String, context: NativeRPCContext) async throws -> BackendBrowserDownloadOperationReply {
        let selected = try await row(id, context: context)
        let file = try localFile(selected)
        let tier: BackendMCPTier = Self.opensAsData(path: selected.path, executable: file.executable) ? .act : .alter
        try await authorize(context, .init(.open, tier: tier, row: selected))
        try verifyLocalFile(selected, receipt: file.receipt)
        let afterConsent = try localFile(selected)
        if tier == .act, !Self.opensAsData(path: selected.path, executable: afterConsent.executable) {
            try await authorize(context, .init(.open, tier: .alter, row: selected))
            try verifyLocalFile(selected, receipt: afterConsent.receipt)
        }
        return try await dependencies.open(file.receipt.url)
    }

    public func reveal(_ id: String, context: NativeRPCContext) async throws -> BackendBrowserDownloadOperationReply {
        let selected = try await row(id, context: context)
        let file = try localFile(selected)
        try await authorize(context, .init(.reveal, tier: .act, row: selected))
        try verifyLocalFile(selected, receipt: file.receipt)
        return try await dependencies.reveal(file.receipt.url)
    }

    public func opensAsData(_ selected: BackendBrowserDownloadRow, context: NativeRPCContext) async throws -> Bool {
        try await authorize(context, .init(.inspect, tier: .read, row: selected))
        guard let file = try? localFile(selected) else { return false }
        return Self.opensAsData(path: selected.path, executable: file.executable)
    }

    public static func opensAsData(path: String, executable: Bool) -> Bool {
        let extensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "ico", "avif",
            "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "opus", "mp4", "m4v", "mov", "webm", "mkv", "avi",
            "pdf", "txt", "md", "rtf", "csv", "tsv", "json", "xml", "yaml", "yml", "log", "epub",
            "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key",
            "ttf", "otf", "woff", "woff2", "zip", "gz", "tgz", "bz2", "xz", "tar", "7z", "rar"
        ]
        return !executable && extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func localFile(_ row: BackendBrowserDownloadRow) throws -> (receipt: BackendBrowserDownloadsStorage.LandedFile, executable: Bool) {
        guard row.onMachine.isEmpty else { throw NativeRPCError(code: "download-remote", message: "That file is on \(row.onMachineName.isEmpty ? "another machine" : row.onMachineName).") }
        guard row.state != .downloading, row.state != .delivering, !row.path.isEmpty else {
            throw NativeRPCError(code: "download-unfinished", message: "Wait for this download to finish before opening or showing it.")
        }
        let current = try BackendBrowserDownloadsStorage.readableFile(URL(fileURLWithPath: row.path))
        if let original = landed[row.id] { try verifyLocalFile(row, receipt: original) }
        return current
    }

    private func verifyLocalFile(_ row: BackendBrowserDownloadRow, receipt: BackendBrowserDownloadsStorage.LandedFile) throws {
        let fd = try receipt.open(); Darwin.close(fd)
        let current = try BackendBrowserDownloadsStorage.readableFile(URL(fileURLWithPath: row.path)).receipt
        guard current.device == receipt.device, current.inode == receipt.inode, current.url.path == receipt.url.path,
              rows.first(where: { $0.id == row.id })?.path == row.path else {
            throw NativeRPCError(code: "download-changed", message: "The downloaded file changed while permission was being checked.")
        }
    }

    private func receive(_ ticket: TransportTicket) async throws -> Active {
        guard let held = active[ticket.id], held.nonce == ticket.nonce, let row = rows.first(where: { $0.id == ticket.id }) else {
            throw NativeRPCError(code: "download-ended", message: "This download is no longer active.")
        }
        do { try await authorize(held.context, .init(.receive, tier: .act, row: row, destination: held.destination)); return held }
        catch {
            guard active[ticket.id]?.nonce == held.nonce else { throw error }
            active[ticket.id] = nil
            patch(ticket.id) { $0.state = .failed; $0.message = "The browser or file destination grant was revoked." }
            await held.cancel(); held.reservation.cleanup(); save(); await publish(); throw error
        }
    }

    private func sealAndDeliver(_ id: String, receipt: BackendBrowserDownloadsStorage.LandedFile, held: Active) async {
        let hashing = Task.detached(priority: .utility) { try receipt.digest() }
        let digest = (try? await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }) ?? ""
        if rows.contains(where: { $0.id == id }) { patch(id) { $0.digest = digest }; save(); await publish() }
        guard !held.destination.machineId.isEmpty else { deliveries[id] = nil; return }
        guard let row = rows.first(where: { $0.id == id }), row.state == .delivering,
              let transport = dependencies.deliver, let transfer = deliveries[id], !transfer.cancellation.isCancelled else { deliveries[id] = nil; return }
        defer { deliveries[id] = nil }
        do {
            try await authorize(held.context, .init(.deliver, tier: .alter, row: row, destination: held.destination))
            try Task.checkCancellation()
            let outcome = try await transport(.init(downloadID: id, source: receipt.url, destination: held.destination,
                                                   digest: digest, binding: row.binding, cancellation: transfer.cancellation,
                                                   openSource: { FileHandle(fileDescriptor: try receipt.open(), closeOnDealloc: true) }))
            try Task.checkCancellation()
            guard !transfer.cancellation.isCancelled else { throw CancellationError() }
            switch outcome {
            case .failed(let message): throw NativeRPCError(code: "download-delivery", message: message)
            case .delivered(let remotePath):
                guard !remotePath.isEmpty, !remotePath.contains("\0") else { throw NativeRPCError(code: "download-delivery", message: "That machine did not say where it put the file.") }
                // Recheck grants after transfer and before the only deletion.
                try await authorize(held.context, .init(.deliver, tier: .alter, row: row, destination: held.destination))
                try Task.checkCancellation()
                var leftBehind = ""
                do { try receipt.removeOwnedCopy() } catch { leftBehind = "A copy is still on this machine, at \(receipt.url.path)." }
                patch(id) { $0.state = .done; $0.path = remotePath; $0.onMachine = held.destination.machineId; $0.onMachineName = held.destination.machineName; $0.message = leftBehind }
                landed[id] = nil
            }
        } catch {
            if rows.first(where: { $0.id == id })?.state != .cancelled {
                patch(id) { $0.state = .failed; $0.message = error.localizedDescription; $0.path = receipt.url.path; $0.onMachine = ""; $0.onMachineName = "" }
            }
        }
        save(); await publish()
    }

    private func authorize(_ context: NativeRPCContext, _ request: BackendBrowserDownloadsAccess) async throws {
        try Task.checkCancellation(); try await dependencies.authorize(context, request); try Task.checkCancellation()
    }
    private func requireLoaded() throws { guard loaded else { throw NativeRPCError(code: "download-not-started", message: "Restore download history explicitly before opening the browser.") } }
    private func trim() {
        // Active transports are never evicted: their only visible row must
        // survive even when more than 100 downloads start at once.
        let moving = rows.filter { $0.state == .downloading || $0.state == .delivering }.count
        var completed = 0
        rows = rows.filter { row in
            if row.state == .downloading || row.state == .delivering { return true }
            completed += 1; return completed <= max(0, Self.maximumRows - moving)
        }
        let kept = Set(rows.map(\.id))
        landed = landed.filter { kept.contains($0.key) }
    }
    private func patch(_ id: String, _ change: (inout BackendBrowserDownloadRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }; change(&rows[index])
    }
    private func save() {
        guard loaded else { return }
        do {
            let raw = NativeRPCValue.object([.init("version", .number(1)), .init("destination", destination.wireValue), .init("items", .array(rows.map(\.wireValue)))])
            try BackendBrowserDownloadsStorage.writeLedger(raw.encodedJSON(pretty: true), root: root)
            persistenceMessage = ""
        } catch { persistenceMessage = "Download history could not be saved: \(error.localizedDescription)" }
    }
    private func publish() async {
        for (id, subscriber) in subscribers {
            do {
                let current = try await view(context: subscriber.context)
                guard subscribers[id] != nil else { continue }
                if case .dropped = subscriber.continuation.yield(current) {
                    subscriber.continuation.finish(throwing: NativeRPCError(code: "download-event-overflow", message: "Read the current downloads list and reconnect its event stream.")); subscribers[id] = nil
                }
            } catch { subscriber.continuation.finish(throwing: error); subscribers[id] = nil }
        }
    }
}
