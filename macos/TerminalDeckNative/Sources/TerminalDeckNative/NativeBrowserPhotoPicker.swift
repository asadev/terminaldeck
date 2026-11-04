import AppKit
import PhotosUI
import UniformTypeIdentifiers

/// Browser 27 (Asad, 4 Nov: "if I … want to import some photo or something from
/// my gallery, I think that is not working"). The page's file chooser is
/// AppKit's open panel inside this app, and its own Photos corner needs a
/// Photos permission this app never asks for. So the chooser carries one
/// button, "Choose from Photos…", that opens the system's photo picker
/// (PHPicker): it runs outside the app and hands over only what the person
/// picks, so no Photos permission is needed at all.
@MainActor
final class NativeBrowserPhotosButton: NSObject {
    private weak var panel: NSOpenPanel?
    private(set) var chosen = false
    let view: NSView

    init(panel: NSOpenPanel) {
        self.panel = panel
        let button = NSButton(title: "Choose from Photos…", target: nil, action: nil)
        button.bezelStyle = .push
        button.sizeToFit()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 24, height: button.frame.height + 16))
        button.frame.origin = NSPoint(x: 12, y: 8)
        container.addSubview(button)
        view = container
        super.init()
        button.target = self
        button.action = #selector(choose)
    }

    @objc private func choose() {
        chosen = true
        panel?.cancel(nil)
    }
}

@MainActor
enum NativeBrowserPhotoPicker {
    /// The picked photos and videos as files the page can read (JPEG/H.264 where
    /// the original is HEIC/HEVC, the way Safari hands photos to websites).
    static func pick(in window: NSWindow, multiple: Bool) async -> [URL]? {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = multiple ? 0 : 1
        configuration.preferredAssetRepresentationMode = .compatible
        configuration.filter = .any(of: [.images, .videos, .livePhotos])
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = Delegate()
        picker.delegate = delegate
        let sheet = NSWindow(contentViewController: picker)
        sheet.title = "Choose from Photos"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.done = { continuation.resume() }
            window.beginSheet(sheet)
        }
        let results = delegate.results
        window.endSheet(sheet)
        sheet.orderOut(nil)
        guard !results.isEmpty else { return nil }
        let folder = Self.folder()
        var urls: [URL] = []
        for (index, result) in results.enumerated() {
            if let url = await Self.file(result.itemProvider, into: folder, index: index) { urls.append(url) }
        }
        return urls.isEmpty ? nil : urls
    }

    @MainActor private final class Delegate: NSObject, PHPickerViewControllerDelegate {
        var done: (() -> Void)?
        var results: [PHPickerResult] = []
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            self.results = results
            let finish = done
            done = nil
            finish?()
        }
    }

    /// One folder per pick under the app's own temporary folder; earlier picks
    /// older than a day are removed (a page may still be sending today's).
    private static func folder() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalDeck-Photos", isDirectory: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            let cutoff = Date().addingTimeInterval(-86_400)
            for item in old where ((try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()) < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    private static func file(_ provider: NSItemProvider, into folder: URL, index: Int) async -> URL? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        guard let type = types.first(where: { $0.conforms(to: .jpeg) }) ?? types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) })
                ?? types.first else { return nil }
        let suggested = provider.suggestedName ?? "Photo \(index + 1)"
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                let base = (suggested as NSString).deletingPathExtension
                let target = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch { continuation.resume(returning: nil) }
            }
        }
    }
}
