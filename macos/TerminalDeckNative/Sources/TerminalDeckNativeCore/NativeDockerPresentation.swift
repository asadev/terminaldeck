import Foundation

/// UI projections only. Engine models and wire payloads belong to DKE.
public enum NativeDockerSection: String, CaseIterable, Identifiable, Sendable {
    case containers, images, volumes, networks, projects
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .projects: "Compose projects"
        }
    }
    public var singular: String {
        switch self {
        case .containers: "container"
        case .images: "image"
        case .volumes: "volume"
        case .networks: "network"
        case .projects: "compose project"
        }
    }
    public var symbol: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack"
        case .volumes: "externaldrive"
        case .networks: "point.3.connected.trianglepath.dotted"
        case .projects: "square.stack.3d.up"
        }
    }
}

public struct NativeDockerFact: Identifiable, Equatable, Sendable {
    public let label: String
    public let value: String
    public var id: String { label }
    public init(label: String, value: String) { self.label = label; self.value = value }
}

public struct NativeDockerItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let state: String
    public let running: Bool?
    public let facts: [NativeDockerFact]
    public let members: [NativeDockerItem]
    public var confirmationName: String { facts.first { $0.label == "Confirmation name" }?.value ?? name }
    public init(id: String, name: String, subtitle: String = "", state: String = "", running: Bool? = nil,
                facts: [NativeDockerFact] = [], members: [NativeDockerItem] = []) {
        self.id = id; self.name = name; self.subtitle = subtitle; self.state = state
        self.running = running; self.facts = facts; self.members = members
    }
}

public struct NativeDockerUsage: Equatable, Sendable {
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public init(cpuPercent: Double?, memoryBytes: UInt64?, memoryLimitBytes: UInt64?) {
        self.cpuPercent = cpuPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.memoryBytes = memoryBytes; self.memoryLimitBytes = memoryLimitBytes
    }
}

public struct NativeDockerLogLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let stream: String
    public init(id: UUID = UUID(), text: String, stream: String) {
        self.id = id; self.text = text; self.stream = stream
    }
}

/// A visible log pane is bounded by bytes and rows, including a single oversized chunk.
/// Its input must already be masked by the Engine's secret handling.
public struct NativeDockerLogBuffer: Sendable {
    public private(set) var lines: [NativeDockerLogLine] = []
    public private(set) var droppedLines = 0
    public private(set) var byteCount = 0
    public let maximumLines: Int
    public let maximumBytes: Int
    private var openLines: [String: UUID] = [:]
    // An incomplete CR may be the first half of CRLF. Hold it outside the
    // displayed payload until the next scalar decides whether it is content.
    private var pendingCarriageReturns: Set<UUID> = []
    public init(maximumLines: Int = 2_000, maximumBytes: Int = 512 * 1_024) {
        self.maximumLines = max(1, maximumLines); self.maximumBytes = max(1, maximumBytes)
    }
    public mutating func append(_ text: String, stream: String) {
        guard !text.isEmpty else { return }
        // Keep the newest part, without allocating an unbounded array of lines.
        let tail = Self.boundedChunkTail(text, maximumBytes: maximumBytes, maximumLines: maximumLines)
        if tail != text {
            droppedLines += 1
            if let id = openLines.removeValue(forKey: stream) { pendingCarriageReturns.remove(id) }
        }
        // Split scalars: Swift treats CRLF as one Character, so Character.split
        // would miss its newline. Strip its carriage return only once completed.
        let pieces = tail.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, piece) in pieces.enumerated() {
            let complete = offset < pieces.count - 1
            // The empty suffix after a final newline is not another displayed row.
            if piece.isEmpty, !complete { continue }
            if let id = openLines[stream], let index = lines.firstIndex(where: { $0.id == id }) {
                let previous = lines.remove(at: index)
                let pendingCR = pendingCarriageReturns.remove(id) != nil ? "\r" : ""
                var joined = previous.text + pendingCR + String(String.UnicodeScalarView(piece))
                if joined.hasSuffix("\r") {
                    joined.removeLast()
                    if !complete { pendingCarriageReturns.insert(id) }
                }
                let clipped = Self.completeUTF8Tail(joined, maximumBytes: maximumBytes)
                if clipped != joined { droppedLines += 1 }
                // A continued row contains the most recently received bytes;
                // keep it after older rows so eviction retains recent output.
                lines.append(NativeDockerLogLine(id: id, text: clipped, stream: stream))
                byteCount += clipped.utf8.count - previous.text.utf8.count
            } else if !piece.isEmpty || complete {
                var text = String(String.UnicodeScalarView(piece))
                let pendingCR = !complete && text.hasSuffix("\r")
                if text.hasSuffix("\r") { text.removeLast() }
                let row = NativeDockerLogLine(text: text, stream: stream)
                lines.append(row); byteCount += row.text.utf8.count; openLines[stream] = row.id
                if pendingCR { pendingCarriageReturns.insert(row.id) }
            }
            if complete { openLines[stream] = nil }
        }
        // Scan discarded rows once, then shift the array once. Repeated
        // removeFirst() made a burst of complete or blank rows quadratic.
        var evictionCount = 0
        var retainedBytes = byteCount
        while evictionCount < lines.count,
              lines.count - evictionCount > maximumLines || retainedBytes > maximumBytes {
            let removed = lines[evictionCount]
            retainedBytes -= removed.text.utf8.count
            if openLines[removed.stream] == removed.id { openLines[removed.stream] = nil }
            pendingCarriageReturns.remove(removed.id)
            evictionCount += 1
        }
        if evictionCount > 0 {
            lines.removeFirst(evictionCount)
            byteCount = retainedBytes
            droppedLines += evictionCount
        }
    }
    public mutating func clear() {
        lines = []; byteCount = 0; droppedLines = 0
        openLines = [:]; pendingCarriageReturns = []
    }

    private static func completeUTF8Tail(_ text: String, maximumBytes: Int) -> String {
        var bytes = text.utf8.suffix(maximumBytes)
        // A UTF-8 continuation byte cannot begin a scalar. Drop the partial scalar.
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes = bytes.dropFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Scan backwards only as far as the displayed budget permits. Newlines and
    /// a final pending CR do not count as content. Empty rows cannot create a
    /// large temporary array before eviction; each chunk has at most maximumLines rows.
    private static func boundedChunkTail(_ text: String, maximumBytes: Int, maximumLines: Int) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.endIndex
        var bytes = 0
        var breaks = 0
        var nextWasNewline = false
        while start > scalars.startIndex {
            let previous = scalars.index(before: start)
            let scalar = scalars[previous]
            if scalar == "\n" {
                if start != scalars.endIndex {
                    breaks += 1
                    if breaks >= maximumLines { break }
                }
                nextWasNewline = true
            } else {
                let width = scalar == "\r" && (nextWasNewline || start == scalars.endIndex) ? 0
                    : scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4
                guard bytes + width <= maximumBytes else { break }
                bytes += width; nextWasNewline = false
            }
            start = previous
        }
        return String(scalars[start...])
    }
}

/// Reject stale stream callbacks after a tab, selection, server or visibility change.
public struct NativeDockerStreamGeneration: Sendable {
    private var current = UUID()
    public init() {}
    public var token: UUID { current }
    @discardableResult public mutating func invalidate() -> UUID { current = UUID(); return current }
    public func accepts(_ token: UUID) -> Bool { current == token }
}
