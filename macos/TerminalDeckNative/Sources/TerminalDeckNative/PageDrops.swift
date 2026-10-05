import AppKit
import WebKit
import TerminalDeckNativeCore

/// The web view every engine page lives in (WebBridge and the island make it).
///
/// Files dragged in from Finder are taken here, with their real paths, and handed
/// to the page as `tdNative.run('drop-paths', {paths, x, y})`. WebKit still sees
/// the drag go over (so the page can show where it would land) and leave, but not
/// the drop: a page only ever gets a file's name, and an unhandled file drop would
/// try to load the file. Every other drag (text, a link) is WebKit's as usual.
@MainActor
final class PageDropWebView: WKWebView {
    /// The drag in progress carries files, and this is an engine page.
    private var takingFiles = false
    private var tookDrop = false

    private var isEnginePage: Bool {
        url.flatMap(EngineOrigin.init(url:)) != nil
    }

    private static func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        takingFiles = isEnginePage && !Self.fileURLs(sender).isEmpty
        tookDrop = false
        let operation = super.draggingEntered(sender)
        return takingFiles ? .copy : operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return takingFiles ? .copy : operation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        takingFiles = false
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        takingFiles ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard takingFiles else { return super.performDragOperation(sender) }
        takingFiles = false
        // The page hears the drag leave, and WebKit forgets it, before the paths arrive.
        super.draggingExited(sender)
        let paths = DropPayload.paths(from: Self.fileURLs(sender))
        let local = convert(sender.draggingLocation, from: nil)
        let top = isFlipped ? local.y : bounds.height - local.y
        let css = DropPayload.cssPoint(x: local.x, y: top, zoom: pageZoom)
        guard let script = DropPayload.script(paths: paths, x: css.x, y: css.y) else { return false }
        tookDrop = true
        let log = AppModel.shared.engine.log
        let count = paths.count
        evaluateJavaScript(script) { _, error in
            guard let error = error as NSError? else { return }
            if error.domain == WKErrorDomain, error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue { return }
            log.note("drop-paths (\(count)) failed: \(error.localizedDescription)")
        }
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if tookDrop {
            tookDrop = false
            return
        }
        super.concludeDragOperation(sender)
    }
}
