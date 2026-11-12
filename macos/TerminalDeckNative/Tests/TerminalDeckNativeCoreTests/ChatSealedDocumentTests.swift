import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class ChatSealedDocumentTests: XCTestCase {
    private let colors = NativeChatSealedDocument.Colors(background: "rgb(255,255,255)", foreground: "rgb(0,0,0)",
                                                        accent: "rgb(0,100,220)", secondary: "rgb(100,100,100)",
                                                        surface: "rgb(240,240,240)", dark: false)

    func testKnownBundledScriptsStylesAndFontsAreReadable() throws {
        for path in ["mermaid.min.js", "katex.min.js", "katex.min.css", "contrib/auto-render.min.js",
                     "fonts/KaTeX_Main-Regular.woff2", "fonts/KaTeX_Size4-Regular.woff2"] {
            let url = try XCTUnwrap(URL(string: "td-chat-library://bundle/" + path))
            XCTAssertEqual(NativeChatSealedDocument.libraryPath(for: url), path)
        }
        XCTAssertEqual(NativeChatSealedDocument.mimeType(for: "katex.min.js"), "text/javascript")
        XCTAssertEqual(NativeChatSealedDocument.mimeType(for: "katex.min.css"), "text/css")
        XCTAssertEqual(NativeChatSealedDocument.mimeType(for: "fonts/KaTeX_Main-Regular.woff2"), "font/woff2")
    }

    func testLibraryEndpointRejectsTraversalCredentialsPortsAndUnknownFiles() throws {
        let addresses = [
            "file:///etc/passwd", "https://bundle/katex.min.js", "td-chat-library://other/katex.min.js",
            "td-chat-library://user@bundle/katex.min.js", "td-chat-library://bundle:80/katex.min.js",
            "td-chat-library://bundle/../katex.min.js", "td-chat-library://bundle/%2e%2e/katex.min.js",
            "td-chat-library://bundle/fonts/../katex.min.js", "td-chat-library://bundle/contrib%2fauto-render.min.js",
            "td-chat-library://bundle/katex.min.js?file=/etc/passwd", "td-chat-library://bundle/katex.min.js#fragment",
            "td-chat-library://bundle/unknown.js", "td-chat-library://bundle/fonts/KaTeX_Unknown.woff2",
            "td-chat-library://bundle/katex-LICENSE.txt",
        ]
        for address in addresses {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertNil(NativeChatSealedDocument.libraryPath(for: url), address)
        }
    }

    func testPoliciesDenyConnectionsFilesNestedFramesWorkersAndForms() {
        for policy in [NativeChatSealedDocument.childPolicy, NativeChatSealedDocument.outerPolicy] {
            let directives = policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            for directive in ["default-src 'none'", "connect-src 'none'", "worker-src 'none'", "object-src 'none'",
                              "base-uri 'none'", "form-action 'none'", "media-src 'none'"] {
                XCTAssertTrue(directives.contains(directive), directive)
            }
            XCTAssertFalse(policy.contains("file:"))
            XCTAssertFalse(policy.contains("https:;"))
            XCTAssertFalse(policy.contains("unsafe-eval"))
        }
        XCTAssertTrue(NativeChatSealedDocument.childPolicy.contains("frame-src 'none'"))
        XCTAssertTrue(NativeChatSealedDocument.childPolicy.contains("img-src data: blob:"))
        XCTAssertTrue(NativeChatSealedDocument.childPolicy.contains("font-src td-chat-library: data:"))
    }

    func testContentRulesAllowOnlyScriptAndStyleLoadsFromExactCDNHosts() throws {
        let bytes = Data(NativeChatSealedDocument.contentRules.utf8)
        let rules = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        XCTAssertEqual((rules.first?["action"] as? [String: String])?["type"], "block")
        let triggers = rules.compactMap { $0["trigger"] as? [String: Any] }.filter {
            ($0["url-filter"] as? String)?.hasPrefix("^https:") == true
        }
        XCTAssertEqual(triggers.count, 2)
        let expressions = try triggers.map { trigger in
            XCTAssertEqual(trigger["resource-type"] as? [String], ["script", "style-sheet"])
            return try NSRegularExpression(pattern: XCTUnwrap(trigger["url-filter"] as? String))
        }
        func accepts(_ url: String) -> Bool {
            expressions.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        XCTAssertTrue(accepts("https://cdnjs.cloudflare.com/ajax/libs/chart.js/4/chart.min.js"))
        XCTAssertTrue(accepts("https://cdn.jsdelivr.net/npm/example/index.css"))
        for denied in ["http://cdn.jsdelivr.net/a.js", "https://cdn.jsdelivr.net.evil.test/a.js",
                       "https://cdn.jsdelivr.net@evil.test/a.js", "https://evil.test/a.js",
                       "https://cdnjs.cloudflare.com:443/a.js"] {
            XCTAssertFalse(accepts(denied), denied)
        }
    }

    func testHostileMarkupNeverAppearsInTrustedOuterDocument() throws {
        let hostile = "</script></iframe><script>window.webkit.messageHandlers.sealedChat.postMessage({type:'rpc'})</script>"
        let document = NativeChatSealedDocument.document(source: hostile, kind: "visual", colors: colors, bridge: false)
        XCTAssertFalse(document.contains(hostile))
        XCTAssertTrue(document.contains("sandbox=\"allow-scripts\""))
        XCTAssertFalse(document.contains("allow-same-origin"))
        XCTAssertFalse(document.contains("allow-top-navigation"))
        XCTAssertFalse(document.contains("allow-popups"))
        XCTAssertTrue(document.contains("event.source!==child.contentWindow"))
        XCTAssertTrue(document.contains("event.origin!=='null'"))
        XCTAssertTrue(document.contains("else if(false && message.jsonrpc"))
        XCTAssertTrue(document.contains("clipboard-read 'none'"))
        XCTAssertTrue(document.contains("camera 'none'"))
    }

    func testUntrustedHTMLFollowsImmutableChildPolicy() throws {
        let hostile = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src *\"><script>fetch('https://evil.test')</script>"
        let child = NativeChatSealedDocument.childDocument(source: hostile, kind: "visual", colors: colors)
        let sealed = try XCTUnwrap(child.range(of: NativeChatSealedDocument.childPolicy))
        let inserted = try XCTUnwrap(child.range(of: hostile))
        XCTAssertLessThan(sealed.lowerBound, inserted.lowerBound)
    }

    func testSVGIsDecodedOnlyAsAnImage() {
        let hostile = "<svg xmlns='http://www.w3.org/2000/svg' onload=\"fetch('https://evil.test')\"><script>alert(1)</script></svg>"
        let child = NativeChatSealedDocument.childDocument(source: hostile, kind: "svg", colors: colors)
        XCTAssertFalse(child.contains(hostile))
        XCTAssertTrue(child.contains("new Image()"))
        XCTAssertTrue(child.contains("data:image/svg+xml;base64,"))
        XCTAssertFalse(child.contains("innerHTML"))
    }

    func testMermaidLoadsOfflineWithStrictSecurityAndTextSource() {
        let child = NativeChatSealedDocument.childDocument(source: "graph TD; A-->B", kind: "mermaid", colors: colors)
        XCTAssertTrue(child.contains("td-chat-library://bundle/mermaid.min.js"))
        XCTAssertTrue(child.contains("securityLevel:'strict'"))
        XCTAssertTrue(child.contains("diagram.textContent=source"))
        XCTAssertTrue(child.contains("ResizeObserver"))
        XCTAssertFalse(child.contains("https://cdn.jsdelivr.net/npm/mermaid"))
    }

    func testMathUsesOfflineKaTeXWithoutTrustedHTMLCommands() {
        for kind in ["math", "math-inline"] {
            let child = NativeChatSealedDocument.childDocument(source: "$\\frac{a}{b}$", kind: kind, colors: colors)
            XCTAssertTrue(child.contains("td-chat-library://bundle/katex.min.js"))
            XCTAssertTrue(child.contains("td-chat-library://bundle/katex.min.css"))
            XCTAssertTrue(child.contains("trust:false"))
            XCTAssertTrue(child.contains("throwOnError:true"))
        }
        let inline = NativeChatSealedDocument.childDocument(source: "<strong>Cost</strong> $x^2$", kind: "math-inline", colors: colors)
        XCTAssertTrue(inline.contains("content.innerHTML=source"))
        XCTAssertTrue(inline.contains("contrib/auto-render.min.js"))
    }

    func testThemeTokensCannotInjectStylesheetMarkup() {
        let hostile = NativeChatSealedDocument.Colors(background: "</style><script>alert(1)</script>", foreground: "red;display:none",
                                                     accent: "rgb(1,2,3)", secondary: "rgb(4,5,6)", surface: "rgb(7,8,9)", dark: true)
        let child = NativeChatSealedDocument.childDocument(source: "", kind: "svg", colors: hostile)
        XCTAssertFalse(child.contains("</style><script>alert(1)</script>"))
        XCTAssertFalse(child.contains("red;display:none"))
        XCTAssertTrue(child.contains("color-scheme:dark"))
        XCTAssertTrue(child.contains("--accent:rgb(1,2,3)"))
        XCTAssertTrue(child.contains("--color-background-primary:var(--background)"))
    }

    // Release check, 6 Nov: a chart box kept its starting height in a background window, because the size was only
    // reported on a painted frame. It is measured with timers and DOM changes now.
    func testSizeIsMeasuredWithoutWaitingForAPaintedFrame() {
        let child = NativeChatSealedDocument.childDocument(source: "<canvas></canvas>", kind: "visual", colors: colors)
        XCTAssertFalse(child.contains("requestAnimationFrame"), "an off-screen view paints no frame, so a frame-timed report never comes")
        XCTAssertTrue(child.contains("new MutationObserver(size)"))
        XCTAssertTrue(child.contains("window.addEventListener('load',size)"))
        XCTAssertTrue(child.contains("setTimeout(size,delay)"))
    }

    // Release check, 6 Nov: Claude drew chart text in dark grey on the dark card. The drawing gets the theme as
    // variables, its colour scheme matches the app, and the instruction tells the AI to use them.
    func testDrawingsGetTheThemeVariablesTheInstructionNames() {
        let dark = NativeChatSealedDocument.Colors(background: "rgb(30,30,30)", foreground: "rgb(240,240,240)", accent: "rgb(1,2,3)",
                                                   secondary: "rgb(150,150,150)", surface: "rgb(40,40,40)", dark: true)
        let child = NativeChatSealedDocument.childDocument(source: "", kind: "visual", colors: dark)
        for token in ["--text:rgb(240,240,240)", "--muted:rgb(150,150,150)", "--accent:rgb(1,2,3)", "--background:rgb(30,30,30)", "color-scheme:dark"] {
            XCTAssertTrue(child.contains(token), token)
        }
        XCTAssertTrue(NativeChatSealedDocument.document(source: "", kind: "visual", colors: dark, bridge: false).contains(":root{color-scheme:dark}"))
        for name in ["var(--text)", "var(--muted)", "var(--accent)", "var(--background)", "currentColor"] {
            XCTAssertTrue(ChatMarkdown.instruction.contains(name), name)
        }
    }
}
