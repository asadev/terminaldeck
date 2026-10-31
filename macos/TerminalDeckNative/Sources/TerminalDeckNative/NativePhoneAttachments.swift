import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Files a phone attaches to an agent chat or to Hoot (phone round, 31 Oct, `chats.files`): normally the paths its own
/// uploads landed at, checked again here (`BackendUploadDestination.attachable`: inside the uploads folder or a folder
/// the device reaches). Pictures and PDFs the AI takes go
/// as attachments, made the way this Mac's own composer makes them; any other file is named in the message by its
/// path, so the AI can open it with its own tools.
enum NativePhoneAttachments {
    struct Resolved { var attachments: [NativeRPCValue]; var text: String }

    static func resolve(_ paths: [String], text: String, provider: String, deviceID: String, uploads: URL,
                        trust: BackendRemoteTrustStore) async throws -> Resolved {
        let approved = await trust.isApproved(deviceID)
        let limits = ChatAttachmentLimits(provider: provider)
        var attachments: [NativeRPCValue] = [], named: [String] = []
        for path in paths {
            guard let url = await BackendUploadDestination.attachable(path, approved: approved, uploads: uploads,
                                                                     reaches: { await trust.canReachFolder(deviceID, folder: $0) }) else {
                throw NativeRPCError(code: "unauthorized", message: "\((path as NSString).lastPathComponent) is not in this Mac's uploads folder or a folder this phone may use. Attach it again.")
            }
            let ext = url.pathExtension.lowercased()
            // A phone's photo is often HEIC: decoded and re-encoded like any picture (the composer's own conversion).
            let picture = limits.images && ["heic", "heif", "tif", "tiff", "bmp"].contains(ext)
            if limits.extensions.contains(ext) || picture, attachments.count < ChatAttachmentLimits.count,
               let block = try? await MainActor.run(body: { try NativeHOOTSIMFeedback.attachment(url: url) }) {
                attachments.append(block)
            } else {
                named.append(url.path)
            }
        }
        var message = text
        if !named.isEmpty {
            let lines = named.map { "- " + $0 }.joined(separator: "\n")
            message += (message.isEmpty ? "" : "\n\n") + "Attached from my phone (on this Mac):\n" + lines
        }
        return Resolved(attachments: attachments, text: message)
    }
}
