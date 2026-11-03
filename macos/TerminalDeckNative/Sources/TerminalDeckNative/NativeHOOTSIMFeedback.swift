import AppKit
import ImageIO
import Observation
import TerminalDeckNativeCore

/// Capture cards reuse Hoot's existing structured chat and its existing MCP tool.
/// No second queue, conversation, image parser, or session launcher.
@MainActor enum NativeHOOTSIMFeedback {
    typealias Invoke = @MainActor (String, [Any?]) async throws -> Any
    static let targetID = "hoot"
    static let maximumImages = ChatAttachmentLimits.count
    static let maximumImageBytes = ChatAttachmentLimits.payloadBytes

    static func attachments(images: [Data]) throws -> [NativeRPCValue] { try attachments(images) }

    static func attachments(_ images: [Data]) throws -> [NativeRPCValue] {
        guard !images.isEmpty, images.count <= 64 else {
            throw NativeRPCError.invalidArguments("Keep this draft and send up to 64 screens at once.")
        }
        let payload: [Data]
        if images.count > maximumImages {
            let groupSize = (images.count + maximumImages - 1) / maximumImages
            payload = try stride(from: 0, to: images.count, by: groupSize).map { start in
                try contactSheet(Array(images[start..<min(images.count, start + groupSize)]), firstNumber: start + 1)
            }
        } else { payload = images }
        return try payload.map { png in
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  CGImageSourceGetType(source) as String? == "public.png",
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw NativeRPCError.invalidArguments("The picture could not be read. Keep this draft and take the picture again.")
            }
            let content = try boundedImage(png, source: source)
            return .object([.init("type", .string("image")), .init("source", .object([
                .init("type", .string("base64")), .init("media_type", .string(content.media)),
                .init("data", .string(content.data.base64EncodedString()))]))])
        }
    }

    /// A numbered picture of every screen keeps long recordings inside the same
    /// four-attachment door; the message keeps all original paths and spoken words.
    static func contactSheet(_ images: [Data], firstNumber: Int = 1) throws -> Data {
        guard !images.isEmpty, images.count <= 64 else { throw NativeRPCError.invalidArguments("Choose one to 64 pictures.") }
        let decoded = try images.map { bytes -> CGImage in
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NativeRPCError.invalidArguments("A screen picture could not be read. Nothing was sent.")
            }
            return image
        }
        let columns = min(2, decoded.count), rows = (decoded.count + columns - 1) / columns
        let cellWidth = 512, cellHeight = 768, labelHeight = 28
        let width = columns * cellWidth, height = rows * (cellHeight + labelHeight)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NativeRPCError.invalidArguments("The screen pictures could not be prepared. Nothing was sent.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, image) in decoded.enumerated() {
            let x = (index % columns) * cellWidth, y = height - (index / columns + 1) * (cellHeight + labelHeight)
            let scale = min(CGFloat(cellWidth - 16) / CGFloat(image.width), CGFloat(cellHeight - 16) / CGFloat(image.height))
            let imageWidth = CGFloat(image.width) * scale, imageHeight = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(x: CGFloat(x) + (CGFloat(cellWidth) - imageWidth) / 2,
                y: CGFloat(y) + CGFloat(labelHeight) + (CGFloat(cellHeight) - imageHeight) / 2,
                width: imageWidth, height: imageHeight))
            ("Screen \(firstNumber + index)" as NSString).draw(at: NSPoint(x: CGFloat(x + 12), y: CGFloat(y + 6)),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
        }
        guard let sheet = context.makeImage(), let png = NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:]) else {
            throw NativeRPCError.invalidArguments("The screen pictures could not be prepared. Nothing was sent.")
        }
        return png
    }

    static func copy(_ images: [Data]) throws {
        guard !images.isEmpty else { throw NativeRPCError.invalidArguments("Mark something first.") }
        let bytes = images.count == 1 ? images[0] : try contactSheet(images)
        guard let image = NSImage(data: bytes) else { throw NativeRPCError.invalidArguments("The picture could not be copied.") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Only native file picks/captured paths call this helper; the MCP chat door takes bytes.
    static func attachment(url: URL) throws -> NativeRPCValue {
        guard url.isFileURL else { throw NativeRPCError.invalidArguments("Choose a local picture or PDF.") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= ChatAttachmentLimits.inputBytes else { throw NativeRPCError.invalidArguments("Choose a smaller picture or PDF.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if url.pathExtension.lowercased() == "pdf" {
            guard data.count <= maximumImageBytes, data.starts(with: Data("%PDF-".utf8)) else {
                throw NativeRPCError.invalidArguments("Use a PDF smaller than 500 KB.")
            }
            return .object([.init("type", .string("document")), .init("source", .object([
                .init("type", .string("base64")), .init("media_type", .string("application/pdf")),
                .init("data", .string(data.base64EncodedString()))]))])
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NativeRPCError.invalidArguments("The picture could not be read.")
        }
        return try attachments([png])[0]
    }

    /// Only the copy sent to Hoot is resized; the saved PNG and all feedback stay intact.
    /// Text keeps the original path, size, markers, and words for the coordinator.
    private static func boundedImage(_ png: Data, source: CGImageSource) throws -> (data: Data, media: String) {
        if png.count <= maximumImageBytes { return (png, "image/png") }
        for edge in [1600, 1280, 1024, 768, 512] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: thumbnail)
            for quality in [0.85, 0.65, 0.45] {
                if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                   data.count <= maximumImageBytes { return (data, "image/jpeg") }
            }
        }
        throw NativeRPCError.invalidArguments("The picture could not be prepared for Hoot. Keep this draft and send a smaller snip.")
    }

    static func send(_ message: String, images: [Data], source: NativeRPCValue = .object([])) async throws {
        try await send(message, attachments: attachments(images), source: source)
    }

    static func send(_ message: String, attachments: [NativeRPCValue], source: NativeRPCValue = .object([]),
                     invoke: Invoke? = nil) async throws {
        _ = try source.requireObject("capture source")
        let context = NativeRPCValue.object([.init("source", source)])
        let arguments: [Any?] = [message, attachments.map { $0.foundation ?? NSNull() }, context.foundation ?? NSNull()]
        if let invoke { _ = try await invoke("hoot:chat:say", arguments) }
        else {
            let receipt = try await EngineBridge.shared.invoke("hoot:chat:say", arguments)
            rememberPreview(receipt: receipt, message: message, attachments: attachments, source: source)
            NativeHootModel.shared.refresh()
        }
    }

    /// Device rows/toolbars capture through the very same device engine as the phone
    /// panel. No device is booted, no watcher is started, and no recording is created.
    /// A phone panel supplies its ticket; ordinary device rows omit it.
    static func sendScreenToHoot(deviceId: String, ticket: UIGSessionSimulatorTicket? = nil,
                                 source: NativeRPCValue = .object([]), invoke: Invoke? = nil) async throws {
        guard !deviceId.isEmpty else { throw NativeRPCError.invalidArguments("Choose a running device first.") }
        _ = try source.requireObject("capture source")
        let call: Invoke = invoke ?? { channel, arguments in try await EngineBridge.shared.invoke(channel, arguments) }
        // Hoot may always use simulators and phones (Asad, 12 Oct): no setting is read before a capture any more.
        if let ticket {
            guard ticket.deviceID == deviceId else { throw NativeRPCError.invalidArguments("The attached device changed. Nothing was sent.") }
            try await validate(ticket, invoke: call)
        }
        let captured: Any
        if let ticket {
            captured = try await call("session-simulator:device",
                [ticket.arguments, "devices:freeze", [deviceId]])
        } else {
            captured = try await call("devices:freeze", [deviceId])
        }
        let snapshot = try NativeRPCValue.fromFoundation(captured)
        let prefix = "data:image/png;base64,"
        guard let dataURL = snapshot["image"].string, dataURL.hasPrefix(prefix),
              let png = Data(base64Encoded: String(dataURL.dropFirst(prefix.count))) else {
            throw NativeRPCError.invalidArguments("The screen picture could not be read. Nothing was sent.")
        }
        guard !snapshot["tree"].isNullish, snapshot["treeError"].string?.isEmpty != false else {
            throw NativeRPCError(code: "unavailable", message: "The screen’s elements could not be read. Nothing was sent.")
        }
        let blocks = try attachments(images: [png])
        if let ticket { try await validate(ticket, invoke: call) }
        var captureSource = source.setting("kind", .string("device")).setting("deviceId", .string(deviceId))
            .setting("noteCount", .number(0))
        if captureSource["title"].isNullish {
            captureSource = captureSource.setting("title", snapshot["where"]["name"].isNullish ? .string("Device screen") : snapshot["where"]["name"])
        }
        if let ticket { captureSource = captureSource.setting("sessionId", .string(ticket.sessionID)) }
        let message = "Screen from " + (captureSource["title"].string ?? "device")
            + "\nAccessibility tree:\n" + snapshot["tree"].compact
        if let ticket {
            let receipt = try await call("session-simulator:send-hoot", [ticket.arguments, message,
                blocks.map { $0.foundation ?? NSNull() }, captureSource.foundation ?? NSNull()])
            if invoke == nil {
                rememberPreview(receipt: receipt, message: message, attachments: blocks, source: captureSource)
                NativeHootModel.shared.refresh()
            }
        } else {
            try await send(message, attachments: blocks, source: captureSource, invoke: invoke)
        }
    }

    private static func validate(_ ticket: UIGSessionSimulatorTicket, invoke: Invoke) async throws {
        _ = try await invoke("session-simulator:validate", [ticket.arguments])
    }

    /// Only already-submitted image bytes can produce a transcript preview. A
    /// source path is descriptive metadata, never permission to open a Mac file.
    static func rememberPreview(receipt: Any, message: String, attachments: [NativeRPCValue], source: NativeRPCValue) {
        guard let snapshot = try? NativeRPCValue.fromFoundation(receipt),
              let conversation = snapshot["conversationId"].string,
              let events = try? (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:)) else { return }
        guard let expectedSource = try? NativeRPCValue.fromFoundation(source.foundation ?? NSNull()) else { return }
        let matching = events.filter { event in
            let receivedSource = try? NativeRPCValue.fromFoundation(event.record.value["context"]["source"].foundation ?? NSNull())
            return event.conversationID == conversation && event.record.kind == .user &&
                event.record.value["text"].string == message && receivedSource == expectedSource
        }
        // Ambiguous history gets the honest generic attachment card.
        guard matching.count == 1, let row = HootChatProjection.rows(matching).first,
              let block = attachments.first(where: { $0["type"].string == "image" }),
              let encoded = block["source"]["data"].string,
              let bytes = Data(base64Encoded: encoded), bytes.count <= maximumImageBytes,
              let image = previewImage(bytes) else { return }
        NativeHOOTSIMPreviewCache.shared.put(image, conversation: conversation, rowID: row.id)
    }

    static func previewImage(_ bytes: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }

    static func preview(conversation: String, rowID: String) -> NSImage? {
        NativeHOOTSIMPreviewCache.shared.image(conversation: conversation, rowID: rowID)
    }

    static func retainPreviews(conversation: String, rowIDs: Set<String>) {
        NativeHOOTSIMPreviewCache.shared.retain(conversation: conversation, rowIDs: rowIDs)
    }
}

/// Bounded transient display state only: twenty small thumbnails, no transcript,
/// file paths, provider state, persisted bytes, engine, or background work.
@MainActor @Observable private final class NativeHOOTSIMPreviewCache {
    static let shared = NativeHOOTSIMPreviewCache()
    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    func image(conversation: String, rowID: String) -> NSImage? { images[conversation + "|" + rowID] }
    func put(_ image: NSImage, conversation: String, rowID: String) {
        let key = conversation + "|" + rowID
        order.removeAll { $0 == key }; order.append(key); images[key] = image
        while order.count > 20 { images.removeValue(forKey: order.removeFirst()) }
    }
    func retain(conversation: String, rowIDs: Set<String>) {
        let wanted = Set(rowIDs.map { conversation + "|" + $0 })
        images = images.filter { wanted.contains($0.key) }
        order.removeAll { !wanted.contains($0) }
    }
}
