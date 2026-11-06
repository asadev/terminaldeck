import Foundation

/// Documents for a chat attachment. The only native-facing page is our outer
/// shell; generated code lives in a separate, opaque sandboxed frame.
public enum NativeChatSealedDocument {
    public static let libraryScheme = "td-chat-library"
    public static let libraryOrigin = "td-chat-library://bundle"
    public static let maximumSourceBytes = 2_097_152
    public static let maximumBridgeBytes = 1_048_576

    public static let childPolicy = "default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net td-chat-library:; style-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net td-chat-library:; img-src data: blob:; font-src td-chat-library: data:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'"
    // A srcdoc inherits its parent's policy as well as its own. This policy
    // permits the one sandboxed frame; the child's policy denies nested frames.
    public static let outerPolicy = "default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net td-chat-library:; style-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net td-chat-library:; img-src data: blob:; font-src td-chat-library: data:; connect-src 'none'; frame-src about:; child-src about:; worker-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'"

    /// Deny all requests first, then allow only the two script/style CDNs and
    /// named bundled library assets. CSP independently denies other load types.
    public static let contentRules = #"""
    [
      {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https://cdnjs\\.cloudflare\\.com/","resource-type":["script","style-sheet"]},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^https://cdn\\.jsdelivr\\.net/","resource-type":["script","style-sheet"]},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^td-chat-library://bundle/","resource-type":["script","style-sheet","font"]},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^data:","resource-type":["image","font"]},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^blob:","resource-type":["image","font"]},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^about:blank$","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^about:srcdoc$","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}}
    ]
    """#

    public struct Colors: Equatable, Sendable {
        public let background: String
        public let foreground: String
        public let accent: String
        public let secondary: String
        public let surface: String
        public let dark: Bool
        public init(background: String, foreground: String, accent: String,
                    secondary: String, surface: String, dark: Bool) {
            self.background = background; self.foreground = foreground; self.accent = accent
            self.secondary = secondary; self.surface = surface; self.dark = dark
        }
    }

    private static let fonts: Set<String> = [
        "AMS-Regular", "Caligraphic-Bold", "Caligraphic-Regular", "Fraktur-Bold", "Fraktur-Regular",
        "Main-Bold", "Main-BoldItalic", "Main-Italic", "Main-Regular", "Math-BoldItalic", "Math-Italic",
        "SansSerif-Bold", "SansSerif-Italic", "SansSerif-Regular", "Script-Regular", "Size1-Regular",
        "Size2-Regular", "Size3-Regular", "Size4-Regular", "Typewriter-Regular",
    ]

    /// This accepts complete known paths, never an arbitrary filename beneath a
    /// bundle directory. Encoded traversal, credentials, ports and queries fail.
    public static func libraryPath(for url: URL) -> String? {
        guard url.scheme == libraryScheme, url.host == "bundle", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.percentEncodedPath == url.path else { return nil }
        let path = String(url.path.dropFirst())
        if ["mermaid.min.js", "katex.min.js", "katex.min.css", "contrib/auto-render.min.js"].contains(path) { return path }
        if path.hasPrefix("fonts/KaTeX_"), path.hasSuffix(".woff2") {
            let name = String(path.dropFirst("fonts/KaTeX_".count).dropLast(".woff2".count))
            return fonts.contains(name) ? path : nil
        }
        return nil
    }

    public static func mimeType(for path: String) -> String {
        if path.hasSuffix(".js") { return "text/javascript" }
        if path.hasSuffix(".css") { return "text/css" }
        if path.hasSuffix(".woff2") { return "font/woff2" }
        return "application/octet-stream"
    }

    public static func document(source: String, kind: String, colors: Colors, bridge: Bool) -> String {
        let child = childDocument(source: source, kind: kind, colors: colors)
        let encoded = Data(child.utf8).base64EncodedString()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(outerPolicy)">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden}iframe{display:block;border:0;width:100%;height:100%}</style></head><body>
        <iframe id="attachment" title="Chat content" sandbox="allow-scripts" allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'; display-capture 'none'; fullscreen 'none'; payment 'none'; usb 'none'; serial 'none'; hid 'none'" referrerpolicy="no-referrer"></iframe>
        <script>
        'use strict';
        const child=document.getElementById('attachment');
        const report=value=>{if(value.type==='ready'||value.type==='error'||value.type==='size'){window.__tdChatStatus=Object.assign(window.__tdChatStatus||{},value);if(value.type==='ready')window.__tdChatStatus.ready=true;if(value.type==='error')window.__tdChatStatus.failed=true;}window.webkit.messageHandlers.sealedChat.postMessage(value);};
        window.addEventListener('message',event=>{
          if(event.origin!=='null' || event.source!==child.contentWindow || !event.data || typeof event.data!=='object')return;
          const message=event.data;
          if(message.__tdChat==='size' && Number.isFinite(message.height))report({type:'size',height:message.height});
          else if(message.__tdChat==='ready')report({type:'ready'});
          else if(message.__tdChat==='error')report({type:'error'});
          else if(\(bridge ? "true" : "false") && message.jsonrpc==='2.0' && JSON.stringify(message).length<=\(maximumBridgeBytes))report({type:'rpc',value:message});
        });
        window.__tdChatDeliver=value=>child.contentWindow.postMessage(value,'*');
        child.srcdoc=new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0)));
        </script></body></html>
        """
    }

    public static func childDocument(source: String, kind: String, colors: Colors) -> String {
        let encoded = Data((kind == "math-inline" ? ChatMarkdown.mathInlineHTML(source) : source).utf8).base64EncodedString()
        let styles = """
        :root{color-scheme:\(colors.dark ? "dark" : "light");--background:\(safeColor(colors.background));--foreground:\(safeColor(colors.foreground));--accent:\(safeColor(colors.accent));--secondary:\(safeColor(colors.secondary));--surface:\(safeColor(colors.surface));--color-background-primary:var(--background);--color-text-primary:var(--foreground);--color-text-secondary:var(--secondary);--color-accent:var(--accent)}
        html{overflow:auto;background:var(--background);color:var(--foreground)}body{margin:0;padding:8px;box-sizing:border-box;font:14px -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}*,*:before,*:after{box-sizing:border-box}img,svg{max-width:100%}pre{white-space:pre-wrap}a{color:var(--accent)}#td-content{display:flow-root}#td-error{color:var(--secondary);padding:12px}.katex-display{overflow-x:auto;overflow-y:hidden}
        """
        var libraries = ""
        var content = "<div id=\"td-content\"></div>"
        var render = ""
        switch kind {
        case "svg":
            render = "const image=new Image();image.alt='SVG drawing';image.src='data:image/svg+xml;base64,'+source64;content.append(image);await image.decode();"
        case "mermaid":
            libraries = "<script src=\"\(libraryOrigin)/mermaid.min.js\"></script>"
            render = """
            if(!window.mermaid)throw Error('Diagram library unavailable');
            mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'\(colors.dark ? "dark" : "default")',suppressErrorRendering:true});
            const diagram=document.createElement('pre');diagram.className='mermaid';diagram.textContent=source;content.append(diagram);
            await mermaid.run({nodes:[diagram]});
            """
        case "math", "math-inline":
            libraries = "<link rel=\"stylesheet\" href=\"\(libraryOrigin)/katex.min.css\"><script src=\"\(libraryOrigin)/katex.min.js\"></script>"
            if kind == "math-inline" {
                libraries += "<script src=\"\(libraryOrigin)/contrib/auto-render.min.js\"></script>"
                // The caller serializes the maintained Markdown AST into safe inline
                // HTML, preserving dollar delimiters for KaTeX. This remains in
                // the same opaque sandbox as every other generated attachment.
                render = #"content.innerHTML=source;renderMathInElement(content,{delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}],throwOnError:true,trust:false,strict:'error'});"#
            } else {
                render = "katex.render(source,content,{displayMode:true,throwOnError:true,trust:false,strict:'error'});"
            }
        default:
            // User HTML is never interpolated into the outer document or script.
            // The CSP is parsed first and cannot be loosened by later metadata.
            content = "<div id=\"td-content\">\(source)</div>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(childPolicy)"><meta name="referrer" content="no-referrer"><style>\(styles)</style>
        <script>
        'use strict';
        const tdReport=value=>parent.postMessage(value,'*');
        window.addEventListener('error',()=>tdReport({__tdChat:'error'}),true);
        window.addEventListener('unhandledrejection',()=>tdReport({__tdChat:'error'}));
        </script>\(libraries)</head><body>\(content)
        <script>
        (async()=>{
          const source64='\(encoded)';
          const source=new TextDecoder().decode(Uint8Array.from(atob(source64),c=>c.charCodeAt(0)));
          const content=document.getElementById('td-content');
          let pending=false;
          const size=()=>{if(pending)return;pending=true;requestAnimationFrame(()=>{pending=false;tdReport({__tdChat:'size',height:Math.ceil(Math.max(content.scrollHeight,content.getBoundingClientRect().height)+16)});});};
          try{\(render)
            new ResizeObserver(size).observe(content);
            window.addEventListener('resize',size);
            if(document.fonts)document.fonts.ready.then(size);
            document.addEventListener('load',size,true);
            size();tdReport({__tdChat:'ready'});
          }catch(error){
            const failure=document.createElement('div');failure.id='td-error';failure.textContent='This content could not be drawn. Use Code to view its source.';content.replaceChildren(failure);
            size();tdReport({__tdChat:'error'});
          }
        })();
        </script></body></html>
        """
    }

    // Color tokens come from NSColor, but keeping this boundary closed also
    // prevents future callers accidentally inserting markup into the stylesheet.
    private static func safeColor(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "#0123456789abcdefABCDEF.,()% rgbahsl")
        guard !value.isEmpty, value.count <= 80, value.unicodeScalars.allSatisfy(allowed.contains) else { return "CanvasText" }
        return value
    }
}
