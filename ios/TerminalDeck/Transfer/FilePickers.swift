/**
 * The two pickers, and why they are these two.
 *
 * **This file is a design constraint, not a set of preferences.** Both
 * controllers here run **out of process**: the user browses their library or
 * their files inside a system UI that this app cannot see, and what comes back is
 * a copy of exactly the one item they chose. Because the app never reads the
 * library itself, there is:
 *
 *  - no `NSPhotoLibraryUsageDescription` in `Support/Info.plist`,
 *  - no permission prompt in front of anybody,
 *  - nothing extra for App Review to weigh.
 *
 * The alternative — `UIImagePickerController` with `.photoLibrary`, or anything
 * touching `PHPhotoLibrary` / `PHAsset` — requires the usage string, shows the
 * prompt, and turns a file-send button into a privacy question. Even
 * `PHPickerConfiguration(photoLibrary:)` crosses that line, which is why the
 * plain `PHPickerConfiguration()` initialiser is used below and must stay.
 *
 * Do not "improve" this by reaching for the Photos framework. The whole feature
 * was specified around not needing an approval.
 *
 * ## What comes back
 *
 * A `PickedFile` holding a URL in this app's own temporary directory. Both paths
 * copy — `loadFileRepresentation` hands over a URL that is only valid inside its
 * closure, and `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)`
 * with `asCopy: true` puts a copy in `tmp` rather than a security-scoped
 * reference into somebody's iCloud Drive. `FileUpload` deletes the copy when the
 * transfer ends, however it ends.
 */

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where the copies go, so they can be reasoned about and cleaned up in one place.
private func stagingDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A local copy of `source`, under a name that cannot collide with another pick.
private func stage(_ source: URL, named name: String) throws -> URL {
    // The UUID is a *directory* rather than a filename prefix, so the file keeps
    // the name the picker gave it — that name is what gets suggested to the Mac,
    // and `IMG_4823-9F2C1A.HEIC` is not the name of anybody's photo.
    let dir = try stagingDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let destination = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
}

private func sizeOf(_ url: URL) -> Int? {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return values?.fileSize
}

/// Turn a staged URL into the thing `FileUpload` takes, or nil if it is unusable.
private func describe(_ url: URL) -> PickedFile? {
    guard let size = sizeOf(url), size > 0 else { return nil }
    return PickedFile(url: url, name: url.lastPathComponent, size: size, temporary: true)
}

/* ---------------------------------------------------------------- photos -- */

/**
 * `PHPickerViewController`, wrapped for SwiftUI.
 *
 * `selectionLimit = 1` because the desktop takes one file at a time and a picker
 * that let someone choose eight would be offering something the protocol refuses.
 *
 * `preferredAssetRepresentationMode = .current` asks for the asset **as it is on
 * disk** rather than transcoded. Two reasons, and the second is the load-bearing
 * one: a HEIC stays a HEIC and a HEVC video is not re-encoded on the phone, which
 * for a 200 MB clip is the difference between sending it and watching a spinner;
 * and the file this app hashes is then the file the picker gave it, byte for
 * byte, which is what makes the digest check at the far end mean anything.
 */
struct PhotoPicker: UIViewControllerRepresentable {
    /// Nil when the user cancelled, or when the item could not be read.
    let onPicked: (PickedFile?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // The no-argument initialiser. See the header: taking a `photoLibrary`
        // here is what would make this app require photo-library permission.
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: (PickedFile?) -> Void
        /// Answered exactly once. `loadFileRepresentation` can call back on an
        /// error path after the sheet has already dismissed, and a second answer
        /// would start a second upload.
        private var answered = false

        init(onPicked: @escaping (PickedFile?) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                answer(nil)
                return
            }

            // The asset's own type, not a guess. With `.current` above, this is
            // the identifier of the file as it exists in the library — HEIC for a
            // photo taken on this phone, QuickTime for a video.
            let identifier = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            let suggested = provider.suggestedName

            provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
                // The URL is valid only inside this closure and the closure is
                // not on the main thread, so the copy happens here and the answer
                // is hopped over afterwards.
                let staged: URL? = url.flatMap { source in
                    // `suggestedName` usually has no extension, and the temporary
                    // URL usually does. Prefer whichever actually names the file.
                    let name: String
                    if source.pathExtension.isEmpty, let suggested {
                        let ext = UTType(identifier)?.preferredFilenameExtension ?? "dat"
                        name = "\(suggested).\(ext)"
                    } else {
                        name = source.lastPathComponent
                    }
                    return try? stage(source, named: name)
                }
                Task { @MainActor in
                    self?.answer(staged.flatMap(describe))
                }
            }
        }

        @MainActor
        private func answer(_ file: PickedFile?) {
            guard !answered else { return }
            answered = true
            onPicked(file)
        }
    }
}

/* ----------------------------------------------------------------- files -- */

/**
 * `UIDocumentPickerViewController`, wrapped for SwiftUI.
 *
 * `asCopy: true` is the whole reason this needs no entitlement and no
 * security-scoped bookmark dance: the system copies the chosen item into this
 * app's container and hands over a plain URL. The alternative — opening in place
 * — would mean `startAccessingSecurityScopedResource`, a coordinated read, and a
 * file that can be edited or deleted by another app halfway through a transfer.
 *
 * `.item` rather than a list of types, because "send this file to my Mac" has no
 * business having opinions about what a file is.
 */
struct DocumentPicker: UIViewControllerRepresentable {
    let onPicked: (PickedFile?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPicked: (PickedFile?) -> Void

        init(onPicked: @escaping (PickedFile?) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let source = urls.first else {
                onPicked(nil)
                return
            }
            // Staged even though `asCopy` already copied. The system's copy lives
            // in a location it may reclaim, and staging puts every outgoing file
            // under one directory with one owner — `FileUpload` — so a cancelled
            // transfer cleans up the same way a finished one does.
            let staged = try? stage(source, named: source.lastPathComponent)
            try? FileManager.default.removeItem(at: source)
            onPicked(staged.flatMap(describe))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPicked(nil)
        }
    }
}
