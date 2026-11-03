import Foundation
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend

@MainActor
enum NativeSafariRecipeScripts {
    static func run(_ view: WKWebView, recipe: NativeRPCValue, limit: Int) async throws -> NativeRPCValue {
        guard let url = view.url, let host = url.host?.lowercased(), BackendBrowserOrigin.exact(url.absoluteString) != nil,
              let origins = recipe["origins"].elements, origins.contains(where: { origin in
                  guard let allowed = origin.string else { return false }
                  if allowed == "*" { return true }
                  if allowed.hasPrefix("*.") { let bare = String(allowed.dropFirst(2)); return host == bare || host.hasSuffix("." + bare) }
                  return host == allowed
              }), recipe["grants"].elements?.allSatisfy({ $0.string == "page-read" }) == true else {
            throw NativeRPCError(code: "recipe-origin", message: "This page reader is not granted this site's host.")
        }
        let origin = BackendBrowserOrigin.exact(url.absoluteString)
        let answer = try await view.callAsyncJavaScript(script, arguments: ["recipe": recipe.foundation ?? [:], "limit": limit, "textLimit": 4_000], in: nil, contentWorld: .defaultClient)
        guard BackendBrowserOrigin.exact(view.url?.absoluteString ?? "") == origin else { throw NativeRPCError(code: "origin-changed", message: "The page moved to another site while extraction was running.") }
        var result = try NativeRPCValue.fromFoundation(answer)
        let returned: Double, onPage: Double
        if !recipe["rows"].isNullish { returned = result["rowsReturned"].number ?? 0; onPage = result["rowsOnPage"].number ?? 0 }
        else {
            let counts = result["counts"].fields?.map(\.value) ?? []
            returned = counts.compactMap { $0["returned"].number }.max() ?? 0
            onPage = counts.compactMap { $0["matched"].number }.max() ?? 0
        }
        let stated = result["stated"].number
        let trusted = stated.flatMap { $0 >= returned && $0 >= 0 ? $0 : nil }
        result = result.setting("complete", trusted.map { .bool(returned >= $0) } ?? .null)
            .setting("onPage", .number(onPage)).setting("returned", .number(returned))
            .setting("empty", .bool(returned == 0))
            .setting("emptyReason", .string(returned == 0 ? "This call collected no list or row entries. Single fields may still be present; check the loaded page and selectors before concluding that the page contains nothing." : ""))
        let note: String
        if let stated, stated < returned { note = "The stated total is smaller than the returned count. It was not believed; check the reader's total field." }
        else if let stated, stated > returned { note = "The page states \(Int(stated)) and \(Int(returned)) came back. Raise the limit or page on before treating this as complete." }
        else if onPage > returned { note = "The call's limit returned \(Int(returned)) of \(Int(onPage)) rows on this page." }
        else { note = "" }
        return result.setting("note", .string(note))
    }
    /// Closed declarative operations. Arguments enter WebKit as values; no
    /// recipe text, selector or attribute is interpolated into executable code.
    private static let script = #"""
    const D=Document.prototype,E=Element.prototype;
    const attr=(e,k)=>E.getAttribute.call(e,k)||'';
    const secret=e=>/^(password|file)$/i.test(attr(e,'type'))||/(password|one-time-code|cc-number|cc-csc)/i.test(attr(e,'autocomplete'));
    const text=e=>secret(e)?'':String(e.innerText||e.textContent||'').replace(/[ \t\u00a0]+/g,' ').trim().slice(0,textLimit);
    const abs=u=>{try{const raw=String(u||'').trim();return raw?new URL(raw,document.baseURI).href:''}catch{return ''}};
    const nodes=(scope,s)=>{if(!s)return [scope===document?document.body:scope];try{return Array.from(scope===document?D.querySelectorAll.call(document,s):E.querySelectorAll.call(scope,s))}catch{return []}};
    const number=s=>{const m=String(s).match(/-?[0-9][0-9,.\u00a0\u202f ]*/);return m?Number.parseInt(m[0].replace(/[^0-9-]/g,''),10):null};
    const candidates=e=>{const out=[],seen=new Map();let dropped=0;
      const put=(raw,width,from)=>{const url=abs(raw);if(!url)return;if(url.length>2048){dropped++;return;}
        const prior=seen.get(url);if(prior){prior.width=Math.max(prior.width,width);return;}
        if(out.length>=32){dropped++;return;}const item={url,width,from};seen.set(url,item);out.push(item);};
      put(e.currentSrc,0,'currentSrc');
      for(const key of ['src','href','poster','data-src','data-original','data-lazy','data-lazy-src','data-url','data-image','data-full','data-full-src','data-large','data-large-src','data-zoom-image','data-hi-res'])put(attr(e,key),0,key);
      for(const key of ['srcset','data-srcset','data-lazy-srcset']){const raw=attr(e,key);for(const candidate of raw.split(/,\s+|(?<=\d[wx])\s*,\s*/)){
        const match=candidate.trim().match(/^(\S+)(?:\s+(\d+(?:\.\d+)?)([wx]))?$/);if(match)put(match[1],match[3]==='w'?Number(match[2]):0,key);}}
      const natural=e.naturalWidth>0?{width:e.naturalWidth,height:e.naturalHeight}:null;
      return {candidates:out.sort((a,b)=>b.width-a.width),dropped,natural,alt:attr(e,'alt'),loading:attr(e,'loading')};};
    const data=scope=>{const jsonld=[],meta=Object.create(null),itemprop=Object.create(null);
      for(const node of nodes(scope,'script[type="application/ld+json"]')){if(jsonld.length>=20)break;const raw=String(node.textContent||'');if(raw.length>200000)continue;try{jsonld.push(JSON.parse(raw))}catch{}}
      if(scope===document)for(const node of nodes(document,'meta[property],meta[name]')){const key=attr(node,'property')||attr(node,'name'),value=attr(node,'content');if(key&&value&&!Object.hasOwn(meta,key))meta[key]=value.slice(0,2000);}
      for(const node of nodes(scope,'[itemprop]').slice(0,200)){if(secret(node))continue;const key=attr(node,'itemprop');if(key&&!Object.hasOwn(itemprop,key))itemprop[key]=(attr(node,'content')||attr(node,'datetime')||text(node)).slice(0,2000);}
      return {jsonld,meta,itemprop};};
    const counts={};
    const one=(node,field)=>{if(!node||secret(node))return null;
      switch(field.op){case 'text':return text(node);case 'attribute':return attr(node,field.attribute);
        case 'link':return abs(attr(node,'href')||attr(node,'src')||attr(node,'data-href'));case 'image':return candidates(node);
        case 'data':return data(node);case 'number':return number(text(node));default:return null;}};
    const fieldValue=(scope,field,key)=>{const found=nodes(scope,field.selector);
      if(field.op==='count')return field.selector?found.length:nodes(scope,'*').length;
      if(field.op==='data')return data(field.selector?found[0]||scope:scope);
      if(field.all){const chosen=found.slice(0,limit);if(key)counts[key]={matched:found.length,returned:chosen.length};return chosen.map(n=>one(n,field));}
      return one(found[0],field);};
    const fields={};for(const field of recipe.fields||[])fields[field.name]=fieldValue(document,field,field.name);
    const rows=[],containers=recipe.rows?nodes(document,recipe.rows.selector):[];
    for(const node of containers.slice(0,limit)){const row={};for(const field of recipe.rows.fields)row[field.name]=fieldValue(node,field,null);rows.push(row);}
    let stated=recipe.stated?fieldValue(document,recipe.stated,'stated'):null;if(typeof stated!=='number'||!Number.isFinite(stated))stated=null;
    const nextNode=recipe.next?nodes(document,recipe.next)[0]:null;
    const meaningful=v=>v!=null&&(typeof v==='string'?v.trim().length>0:typeof v==='number'?v!==0:typeof v==='object'?Object.values(v).some(meaningful):v===true);
    const empty=rows.length===0&&!meaningful(fields);
    return {url:String(location.href),title:String(document.title||''),fields,rows,rowsOnPage:containers.length,rowsReturned:rows.length,counts,stated,next:nextNode?abs(attr(nextNode,'href')||attr(nextNode,'data-href'))||null:null,empty,emptyReason:empty?'This reader returned no content. Check its selectors and the loaded page before concluding that the page contains nothing.':''};
    """#
}
