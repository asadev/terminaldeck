import Foundation

// MARK: - Files (task-rules.ts, attachment-rules.ts)

public enum CrmFiles {
    public static let maxUploadBytes = 25 * 1024 * 1024
    static let allowed: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "md",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
        "mp3", "m4a", "wav", "ogg", "mp4", "mov", "webm", "zip",
    ]
    static let images: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]

    public static func fileExtension(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex, n.index(after: dot) != n.endIndex else { return "" }
        return n[n.index(after: dot)...].lowercased()
    }

    /// The upload rule: a name, not empty, at most 25 MB, a known kind of file.
    public static func checkUpload(name: String, size: Int) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "The file has no name." }
        if size <= 0 { return "The file is empty." }
        if size > maxUploadBytes { return "“\(n)” is too big — the limit is 25 MB." }
        let ext = fileExtension(n)
        if ext.isEmpty { return "“\(n)” has no file extension, so its type cannot be checked." }
        if !allowed.contains(ext) { return ".\(ext) files cannot be attached to a task. Documents, images, recordings and zips can." }
        return nil
    }

    public static func isImage(mime: String?, fileName: String) -> Bool {
        if let mime, mime.lowercased().hasPrefix("image/") { return true }
        return images.contains(fileExtension(fileName))
    }

    public static func href(taskId: String, attachmentId: String, download: Bool = false) -> String {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? s }
        let base = "task-file:\(enc(taskId))/\(enc(attachmentId))"
        return download ? "\(base)?download=1" : base
    }

    public static func parseHref(_ href: String) -> (taskId: String, attachmentId: String)? {
        guard href.hasPrefix("task-file:") else { return nil }
        let path = href.dropFirst("task-file:".count).split(separator: "?", maxSplits: 1).first ?? ""
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// "1.2 MB", "340 KB".
    public static func sizeLabel(_ bytes: Double?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", bytes / (1024 * 1024)) }
        if bytes >= 1024 { return "\(Int((bytes / 1024).rounded())) KB" }
        return "\(Int(bytes)) B"
    }
}
