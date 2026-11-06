import AppKit
import SwiftUI
import TerminalDeckNativeCore
import WebKit

private struct NativeChatVisualHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 480 }
extension EnvironmentValues {
    var nativeChatVisualMaximumHeight: CGFloat {
        get { self[NativeChatVisualHeightKey.self] }
        set { self[NativeChatVisualHeightKey.self] = newValue }
    }
}

/// Every generated attachment gets an ephemeral browser and an opaque sandbox.
/// Source controls remain native, so even broken content keeps working controls.
@MainActor
struct NativeChatSealedWeb: View {
    let source: String
    let kind: String
    var bridge: ((NativeRPCValue) async -> NativeRPCValue)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nativeChatVisualMaximumHeight) private var chatMaximumHeight
    @State private var showCode = false
    @State private var height: CGFloat = 160
    @State private var loading = true
    @State private var failed = false
    @State private var copied = false

    private var maximumHeight: CGFloat {
        max(44, chatMaximumHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text((kind == "mcp-app" || kind == "mcpApp") ? "App" : (kind == "math-inline" || kind == "math") ? "Math" : kind == "mermaid" ? "Diagram" : kind == "svg" ? "Drawing" : "Visual").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(showCode ? "Preview" : "Code") { showCode.toggle() }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel(showCode ? "Show rendered content" : "Show content source")
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(source, forType: .string)
                }
                .buttonStyle(.borderless).font(.caption)
                .accessibilityLabel("Copy content source")
            }
            if source.utf8.count > NativeChatSealedDocument.maximumSourceBytes {
                Text("This content is too large to draw. Copy its source to inspect it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ZStack(alignment: .topLeading) {
                    NativeChatSealedBrowser(source: source, kind: kind, dark: colorScheme == .dark,
                                            bridge: bridge, height: $height, loading: $loading, failed: $failed)
                        .frame(height: min(maximumHeight, max(44, height)))
                        .opacity(showCode ? 0 : 1)
                        .accessibilityHidden(showCode)
                    if loading && !showCode {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Drawing content…").font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                }
                // Keeping the sealed browser alive preserves interactive state
                // when somebody briefly checks the source.
                .frame(height: showCode ? 0 : nil)
                .clipped()
            }
            if showCode {
                ScrollView([.horizontal, .vertical]) {
                    Text(source).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(minHeight: 60, maxHeight: 300)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            if failed && !showCode {
                Text("This content could not be drawn. Use Code to view its source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: source) { _, _ in copied = false }
    }
}

@MainActor
private struct NativeChatSealedBrowser: NSViewRepresentable {
    let source: String
    let kind: String
    let dark: Bool
    let bridge: ((NativeRPCValue) async -> NativeRPCValue)?
    @Binding var height: CGFloat
    @Binding var loading: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        config.setURLSchemeHandler(ChatLibraryHandler(), forURLScheme: NativeChatSealedDocument.libraryScheme)
        config.userContentController.add(context.coordinator, name: "sealedChat")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.isInspectable = false
        context.coordinator.webView = view
        context.coordinator.begin()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let changed = source != context.coordinator.parent.source || kind != context.coordinator.parent.kind
            || dark != context.coordinator.parent.dark || (bridge == nil) != (context.coordinator.parent.bridge == nil)
        context.coordinator.parent = self
        if changed { context.coordinator.begin() }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "sealedChat")
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: NativeChatSealedBrowser
        weak var webView: WKWebView?
        private var generation = UUID()
        private var documentTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var rpcTasks: [UUID: Task<Void, Never>] = [:]
        private var allowInitialPage = false
        private var allowInitialFrame = false
        private var rules: WKContentRuleList?

        init(_ parent: NativeChatSealedBrowser) { self.parent = parent }

        func cancel() {
            generation = UUID()
            documentTask?.cancel(); timeoutTask?.cancel()
            for task in rpcTasks.values { task.cancel() }
            rpcTasks.removeAll()
        }

        func begin() {
            cancel()
            let current = generation
            documentTask = Task { [weak self] in
                guard let self, let view = webView else { return }
                parent.loading = true; parent.failed = false
                do {
                    // Fail closed: no document loads if the additional network
                    // filter could not be installed.
                    if rules == nil {
                        rules = try await WKContentRuleListStore.default().compileContentRuleList(
                            forIdentifier: "td-chat-sealed-v1", encodedContentRuleList: NativeChatSealedDocument.contentRules)
                    }
                    guard generation == current, !Task.isCancelled, let rules else { return }
                    view.configuration.userContentController.removeAllContentRuleLists()
                    view.configuration.userContentController.add(rules)
                    allowInitialPage = true; allowInitialFrame = true
                    let document = NativeChatSealedDocument.document(source: parent.source, kind: parent.kind,
                                                                     colors: colors(), bridge: parent.bridge != nil)
                    view.loadHTMLString(document, baseURL: nil)
                    timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(15))
                        guard let self, !Task.isCancelled, generation == current, parent.loading else { return }
                        parent.loading = false; parent.failed = true
                    }
                } catch {
                    guard generation == current else { return }
                    parent.loading = false; parent.failed = true
                }
            }
        }

        private func colors() -> NativeChatSealedDocument.Colors {
            let appearance = NSAppearance(named: parent.dark ? .darkAqua : .aqua)
            func css(_ color: NSColor) -> String {
                var result = ""
                appearance?.performAsCurrentDrawingAppearance {
                    let rgb = color.usingColorSpace(.sRGB) ?? .black
                    result = String(format: "rgba(%d,%d,%d,%.3f)", Int(rgb.redComponent * 255),
                                    Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255), rgb.alphaComponent)
                }
                return result
            }
            return .init(background: css(.textBackgroundColor), foreground: css(.labelColor),
                         accent: css(.controlAccentColor), secondary: css(.secondaryLabelColor),
                         surface: css(.controlBackgroundColor), dark: parent.dark)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // WebKit exposes handlers to subframes too. Generated code may call
            // one directly, so checking the frame is essential even with srcdoc.
            guard message.frameInfo.isMainFrame,
                  let value = try? NativeRPCValue.fromFoundation(message.body) else { return }
            switch value["type"].string {
            case "size":
                if let size = value["height"].number {
                    parent.height = CGFloat(min(2000, max(44, size)))
                }
            case "ready": parent.loading = false; timeoutTask?.cancel()
            case "error": parent.failed = true; parent.loading = false; timeoutTask?.cancel()
            case "rpc":
                guard let bridge = parent.bridge, rpcTasks.count < 8 else { return }
                let request = value["value"]
                if request["method"].string == "ui/notifications/size-changed", let size = request["params"]["height"].number {
                    parent.height = CGFloat(min(2000, max(44, size)))
                }
                guard request["jsonrpc"].string == "2.0", request.fields != nil,
                      let bytes = try? request.encodedJSON(), bytes.count <= NativeChatSealedDocument.maximumBridgeBytes else { return }
                let current = generation
                let id = UUID()
                rpcTasks[id] = Task { [weak self] in
                    let reply = await bridge(request)
                    guard let self, generation == current, !Task.isCancelled else { return }
                    rpcTasks[id] = nil
                    // Initialize may produce both its response and the initial
                    // tool notifications. They are separate JSON-RPC messages.
                    let messages = reply.elements ?? [reply]
                    for item in messages where item.fields != nil {
                        guard let data = try? item.encodedJSON(), data.count <= NativeChatSealedDocument.maximumBridgeBytes else { continue }
                        let encoded = data.base64EncodedString()
                        let script = "window.__tdChatDeliver(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0)))))"
                        _ = try? await webView?.evaluateJavaScript(script)
                    }
                }
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let address = navigationAction.request.url?.absoluteString
            // Math paragraphs contain only our escaped Markdown and bundled KaTeX.
            // A tap may open an original Markdown link, just as native text does;
            // the sealed page itself still never navigates. Generated visuals and
            // MCP App HTML do not receive this path.
            if parent.kind == "math-inline", navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url, ChatMarkdown.linkURLs(parent.source).contains(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel); return
            }
            if navigationAction.targetFrame?.isMainFrame == true, allowInitialPage,
               navigationAction.navigationType == .other, address == "about:blank" {
                allowInitialPage = false; decisionHandler(.allow)
            } else if navigationAction.targetFrame?.isMainFrame == false, allowInitialFrame,
                      navigationAction.navigationType == .other, address == "about:srcdoc" {
                allowInitialFrame = false; decisionHandler(.allow)
            } else { decisionHandler(.cancel) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.failed = true; parent.loading = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.failed = true; parent.loading = false
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.failed = true; parent.loading = false
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}

/// No filesystem URL is ever handed to WebKit. The scheme exposes only the
/// bundled, pinned rendering libraries, and nothing beside them.
@MainActor
private final class ChatLibraryHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let path = NativeChatSealedDocument.libraryPath(for: url),
              let root = Bundle.module.resourceURL?.appendingPathComponent("ChatLibraries", isDirectory: true).resolvingSymlinksInPath() else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": NativeChatSealedDocument.mimeType(for: path),
                "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
              ]) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
