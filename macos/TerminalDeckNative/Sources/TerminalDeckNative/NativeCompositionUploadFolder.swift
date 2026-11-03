import Foundation
import TerminalDeckBackend

extension NativeCompositionProduction {
    /// A separate app data folder must also keep received files out of the person's Downloads.
    var uploadFolder: URL {
        let primary = BackendCompositionSuppliers.primaryDataDirectory(home: configuration.homeDirectory)
        if configuration.dataDirectory.standardizedFileURL.resolvingSymlinksInPath() != primary.standardizedFileURL.resolvingSymlinksInPath() {
            return configuration.dataDirectory.appendingPathComponent("uploads", isDirectory: true)
        }
        return BackendUploadDestination.uploadsFolder(home: configuration.homeDirectory, appName: configuration.appName)
    }
}
