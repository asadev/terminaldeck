import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Files

    /// Files from any door (Attach file, a drop, a paste, the comment box's clip): each
    /// checked with the upload rule first, then copied in. Returns what was attached.
    @discardableResult
    func upload(_ urls: [URL]) async -> [TaskAttachment] {
        guard bundleState == .ready else {
            error = "Still loading this task — try the file again in a moment."
            return []
        }
        shown.insert(.attachments)
        var done: [TaskAttachment] = []
        for url in urls {
            let name = url.lastPathComponent
            // #327: a file the rule refuses (too big, wrong type) is refused before it is read into memory.
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, let refusal = CrmFiles.checkUpload(name: name, size: size) {
                error = refusal
                continue
            }
            let data = (try? Data(contentsOf: url)) ?? Data()
            if let refusal = CrmFiles.checkUpload(name: name, size: data.count) {
                error = refusal
                continue
            }
            let pendingRow = PendingUpload(fileName: name, sizeBytes: data.count)
            pending.append(pendingRow)
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let result = await call("uploadTaskFile", [taskId, ["name": name, "type": type, "bytes": data] as [String: Any]])
            pending.removeAll { $0.id == pendingRow.id }
            switch result {
            case .failure(let problem):
                error = "Upload “\(name)”: \(problem.message)"
            case .success(let r):
                if let a = CrmDecode.attachment(r["attachment"]) {
                    attachments = (attachments ?? []) + [a]
                    done.append(a)
                }
            }
        }
        return done
    }

    /// "Upload from device": the Mac's own file chooser, in the engine, checks and copies each file.
    func chooseFromDevice() async -> [TaskAttachment] {
        guard bundleState == .ready else {
            error = "Still loading this task — try the file again in a moment."
            return []
        }
        switch await call("chooseTaskFiles", [taskId]) {
        case .failure(let problem):
            error = "Upload: \(problem.message)"
            return []
        case .success(let r):
            let added = (r["attachments"] as? [Any] ?? []).compactMap(CrmDecode.attachment)
            if !added.isEmpty {
                shown.insert(.attachments)
                attachments = (attachments ?? []) + added
            }
            let errors = TasksJSON.strings(r["errors"])
            if !errors.isEmpty { error = errors.joined(separator: " ") }
            return added
        }
    }

    func detach(_ attachment: TaskAttachment) {
        let before = attachments
        attachments?.removeAll { $0.id == attachment.id }
        Task {
            if !(await write("detachTaskAttachment", [attachment.id], label: "Removing \(q(attachment.fileName))")) { attachments = before }
        }
    }

    func attachDocument(id documentId: String, fileName: String) {
        Task {
            switch await call("attachExistingDocument", [taskId, documentId]) {
            case .failure(let problem): error = "Attaching \(q(fileName)): \(problem.message)"
            case .success: await loadBundle()
            }
        }
    }

    func openFile(_ attachmentId: String) {
        Task { _ = await call("openTaskFile", [taskId, attachmentId]) }
    }

}
