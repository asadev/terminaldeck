import CryptoKit
import Foundation
import ImageIO
import TerminalDeckNativeCore
import UniformTypeIdentifiers

/// Pictures on a paired phone (Asad, 28 Oct: "show the images of the projects, profile photos of the agents,
/// everything same as web version … so we understand everything properly, what is what"): the remote `pictures`
/// capability.
///
/// `pictures` answers what a phone needs to draw this Mac's own pictures: every project folder the device reaches,
/// with its project's name and logo (by hash); the agents and Hoot with their picture (the icon string this Mac's
/// avatar draws: `sf:<symbol>@<colour>` or `emoji:<text>`); and who works in each session the device sees (the agent
/// or lead this Mac's session list shows under the session's name). `picture` sends one logo, small, by its hash: the
/// phone keeps it by that hash, so a logo crosses once and again only when it changes.
///
/// Reads only. Before a call reaches here the host has checked the device's access for the message (a read), so a
/// Hoot-only phone is never answered. Folders are only the device's own reach; sessions only those it sees; the
/// agents directory only for the owner's own device (a guest sees the agents of its sessions alone).
public actor BackendPhonePictures {
    /// One agent's picture, as this Mac's avatar draws it.
    public struct Face: Sendable, Equatable {
        public var id: String
        public var name: String
        /// `AGTIcon.raw(icon, colour:)`: the symbol or emoji and its chosen colour.
        public var icon: String
        public var png: Data?
        public var hoot: Bool
        public init(id: String, name: String, icon: String, hoot: Bool = false, png: Data? = nil) {
            self.id = id; self.name = name; self.icon = icon; self.hoot = hoot; self.png = png
        }
        var pictureHash: String? {
            png.flatMap { $0.count <= 45_000 ? SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() : nil }
        }
        var wire: NativeRPCValue {
            var fields: [NativeRPCValue.Field] = [.init("id", .string(String(id.prefix(128)))), .init("name", .string(String(name.prefix(120)))),
                                                  .init("icon", .string(String(icon.prefix(80))))]
            if let pictureHash { fields.append(.init("picture", .string(pictureHash))) }
            if hoot { fields.append(.init("hoot", .bool(true))) }
            return .object(fields)
        }
    }
    /// What this adapter reads, as closures, so it is tested without the app.
    public struct Source: Sendable {
        /// The project registry (each project's folders, name and logo file name).
        public var projects: @Sendable () async -> [PROJProject]
        /// The app's own project-logos folder (`BackendPROJLogos.folderName` in its data).
        public var logos: URL
        /// Every agent and Hoot, as the Agents page lists them.
        public var agents: @Sendable () async -> [Face]
        /// Who works in each of these sessions: the agent or lead this Mac's session list names. Absent: nobody.
        public var sessionAgents: @Sendable ([String]) async -> [String: Face]
        /// The sessions this device sees now (the host's own visibility check).
        public var visibleSessions: @Sendable (BackendRemoteHostContext) async throws -> Set<String>
        public init(projects: @escaping @Sendable () async -> [PROJProject], logos: URL,
                    agents: @escaping @Sendable () async -> [Face],
                    sessionAgents: @escaping @Sendable ([String]) async -> [String: Face],
                    visibleSessions: @escaping @Sendable (BackendRemoteHostContext) async throws -> Set<String>) {
            self.projects = projects; self.logos = logos; self.agents = agents; self.sessionAgents = sessionAgents
            self.visibleSessions = visibleSessions
        }
    }

    public static let capability = "pictures"
    public static let messages: Set<String> = ["pictures", "picture"]
    /// The largest side a logo is sent at: a 64 pt header on a 3x phone. Smaller when the frame would be too big.
    static let sides = [192, 128, 96, 64]
    /// The base64 a `picture` frame may carry (the host's message limit is 64 KiB).
    static let pictureBudget = 60_000
    /// The whole `pictures` answer stays under the host's message limit.
    static let listBudget = 60_000
    static let maxAgents = 200
    static let maxProjects = 200

    private let source: Source
    /// A logo file's hash, kept while its size and date stay the same.
    private var hashes: [String: (size: Int, modified: Double, hash: String)] = [:]

    public init(source: Source) { self.source = source }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: Self.capability, messageTypes: Self.messages, policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Pictures on the phone stopped.") }
            return try await self.handle(message, context: context)
        }
    }

    func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        let rid = try message["rid"].requireString("request", nonempty: true)
        switch message.type {
        case "pictures": return [try await list(rid: rid, context: context)]
        case "picture": return [try await picture(rid: rid, hash: try message["picture"].requireString("picture", nonempty: true), context: context)]
        default: throw NativeRPCError.invalidArguments("Unknown picture operation.")
        }
    }

    // MARK: The list

    struct ProjectRow: Equatable {
        var folder: String
        var id: String
        var name: String
        var logo: String?
        var hash: String?
    }

    /// Each folder this device reaches, with the project that holds it (the same longest-folder rule as the Mac's
    /// own session rows). A folder no project holds is left out: the phone draws its letter tile.
    func projectRows(_ context: BackendRemoteHostContext) async -> [ProjectRow] {
        let registry = await source.projects().filter { $0.id != PROJProjects.independentID }
        var rows: [ProjectRow] = [], seen = Set<String>()
        for folder in context.reach.folders where seen.insert(folder).inserted {
            let id = PROJProjects.resolve(projectID: nil, folder: folder, projects: registry)
            guard id != PROJProjects.independentID, let project = registry.first(where: { $0.id == id }) else { continue }
            let logo = BackendPROJLogos.isSafe(project.logo) ? project.logo : nil
            rows.append(.init(folder: folder, id: project.id, name: project.name, logo: logo, hash: logo.flatMap { hash($0) }))
            if rows.count >= Self.maxProjects { break }
        }
        return rows
    }

    func list(rid: String, context: BackendRemoteHostContext) async throws -> BackendRemoteServerMessage {
        let projects = await projectRows(context)
        let visible = try await source.visibleSessions(context).sorted()
        let working = await source.sessionAgents(visible)
        let sessions: [NativeRPCValue] = visible.prefix(BackendRemoteProtocol.limits["MAX_ANNOUNCED_SESSIONS"] ?? 128).compactMap { id in
            working[id].map { face in NativeRPCValue.object([.init("id", .string(id)), .init("agent", face.wire)]) }
        }
        // The directory is the owner's: a guest is shown only who works in the sessions it sees.
        var agents: [NativeRPCValue] = []
        if context.kind == .mine { agents = Array(await source.agents().prefix(Self.maxAgents)).map(\.wire) }
        var projectValues = projects.map { row -> NativeRPCValue in
            var fields: [NativeRPCValue.Field] = [.init("folder", .string(row.folder)), .init("id", .string(row.id)),
                                                  .init("name", .string(String(row.name.prefix(120))))]
            if let hash = row.hash { fields.append(.init("picture", .string(hash))) }
            return .object(fields)
        }
        func frame() throws -> BackendRemoteServerMessage {
            try .init(.pictures, fields: [.init("rid", .string(rid)), .init("projects", .array(projectValues)),
                                          .init("agents", .array(agents)), .init("sessions", .array(sessions))])
        }
        var answer = try frame()
        while try answer.value.encodedJSON().count > Self.listBudget, !agents.isEmpty || !projectValues.isEmpty {
            if !agents.isEmpty { agents.removeLast(max(1, agents.count / 10)) } else { projectValues.removeLast(max(1, projectValues.count / 10)) }
            answer = try frame()
        }
        return answer
    }

    // MARK: One logo

    func picture(rid: String, hash: String, context: BackendRemoteHostContext) async throws -> BackendRemoteServerMessage {
        let visible = try await source.visibleSessions(context)
        var faces = Array(await source.sessionAgents(Array(visible)).values)
        if context.kind == .mine { faces += await source.agents() }
        if let face = faces.first(where: { $0.pictureHash == hash }), let png = face.png {
            return try .init(.picture, fields: [.init("rid", .string(rid)), .init("picture", .string(hash)), .init("png", .string(png.base64EncodedString()))])
        }
        // Only a logo of a project this device reaches, found by the hash this Mac gave it.
        guard let row = await projectRows(context).first(where: { $0.hash == hash }), let logo = row.logo else {
            throw NativeRPCError(code: "unavailable", message: "That picture is no longer on this Mac.")
        }
        let url = source.logos.appendingPathComponent(logo)
        guard let png = Self.thumbnail(url) else {
            throw NativeRPCError(code: "unavailable", message: "That picture could not be read on this Mac.")
        }
        return try .init(.picture, fields: [.init("rid", .string(rid)), .init("picture", .string(hash)), .init("png", .string(png))])
    }

    /// The logo as a small PNG in base64: the largest of `sides` that fits the frame.
    static func thumbnail(_ url: URL) -> String? {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        for side in sides {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: side]
            guard let small = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, small, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            let text = (data as Data).base64EncodedString()
            if text.count <= pictureBudget { return text }
        }
        return nil
    }

    /// The first 16 hex digits of the logo file's SHA-256, kept while the file's size and date stay the same.
    func hash(_ logo: String) -> String? {
        let url = source.logos.appendingPathComponent(logo)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= BackendPROJLogos.maximumSourceBytes else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        if let kept = hashes[logo], kept.size == size, kept.modified == modified { return kept.hash }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
        hashes[logo] = (size, modified, String(hash))
        return String(hash)
    }
}

extension BackendPhonePictures {
    /// What keeps `pictures` serving: the adapter and its place on the endpoint. The endpoint's feature holds the
    /// adapter weakly (as every phone feature does), so whoever installs it keeps this for as long as it serves, and
    /// dropping it ends the service. 28 Oct, install #7: the composition kept only the endpoint's lease, the adapter was
    /// freed as start-up returned, and every phone request was answered "Pictures on the phone stopped."
    public final class Installation: Sendable {
        public let pictures: BackendPhonePictures
        private let lease: NativeRPCSubscription
        init(pictures: BackendPhonePictures, lease: NativeRPCSubscription) {
            self.pictures = pictures
            self.lease = lease
        }
        /// Takes `pictures` off the endpoint.
        public func stop() async { await lease.cancelAndWait() }
    }

    /// Puts `pictures` on the endpoint (before any phone connects); keep what this returns.
    public static func install(on endpoint: BackendRemoteHost, source: Source,
                               ownerID: String = "native.phone-pictures") async throws -> Installation {
        let pictures = BackendPhonePictures(source: source)
        let lease = try await endpoint.installFeatures(ownerID: ownerID, features: [await pictures.feature()], connectionClosed: { _ in })
        return Installation(pictures: pictures, lease: lease)
    }
}

extension BackendRemoteProtocol {
    /// `pictures {rid}` and `picture {rid, picture}` (the logo's hash from a `pictures` answer).
    static func parsePictures(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        switch r.type {
        case "pictures":
            return r.base.setting("rid", .string(try r.id("rid", reason: "pictures without a request id")))
        case "picture":
            let hash = try r.text("picture", reason: "picture without a picture id", bytes: 64)
            guard hash.range(of: #"^[0-9a-f]{8,64}$"#, options: .regularExpression) != nil else { throw r.bad("picture with an unusable picture id") }
            return r.base.setting("rid", .string(try r.id("rid", reason: "picture without a request id"))).setting("picture", .string(hash))
        default:
            return nil
        }
    }
}
