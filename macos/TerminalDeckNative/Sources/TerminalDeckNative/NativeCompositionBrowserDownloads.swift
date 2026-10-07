import Foundation
import WebKit
import TerminalDeckBackend

/// A presentation seam allows the native graph to replace the old ledger
/// owner without changing the existing pure download row type.
@MainActor
protocol NativeCompositionBrowserDownloadsPresentation: AnyObject {
    var items: [NativeBrowserDownloads.Item] { get }
    var badge: (label: String, tone: String)? { get }
    var runningCount: Int { get }
    var overallFraction: Double? { get }
    var message: String { get }
    func backendRow(_ id: UUID) -> BackendBrowserDownloadRow?
    func adopt(_ download: WKDownload, webView: WKWebView)
    func cancel(_ id: UUID)
    func clearFinished()
    func open(_ id: UUID)
    func reveal(_ id: UUID)
    func openDownloadsFolder()
}

extension NativeSafariDownloads: NativeCompositionBrowserDownloadsPresentation { }
extension NativeBrowserDownloads: NativeCompositionBrowserDownloadsPresentation {
    var message: String { "" }
    func backendRow(_ id: UUID) -> BackendBrowserDownloadRow? { nil }
    func adopt(_ download: WKDownload, webView: WKWebView) { adopt(download) }
}
