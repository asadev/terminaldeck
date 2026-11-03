using System.Text.Json;

namespace TerminalDeck.Core.Browser;

// Fixed DOM operations. Selectors and text are JSON data, never executable caller JavaScript.
public static class BrowserDomAutomation
{
  internal static string DomHelpers => Helpers;
  private const string Helpers = """
    const parent=e=>e.parentElement||(e.getRootNode&&e.getRootNode().host)||(()=>{try{return e.ownerDocument.defaultView.frameElement}catch{return null}})();
    const ancestry=(e,test)=>{for(let n=e;n;n=parent(n))if(test(n))return true;return false;};
    const hidden=e=>!e||ancestry(e,n=>n.matches('script,style,noscript,input[type=password],[hidden],[aria-hidden=true],[data-private],[data-secret]')||!n.getClientRects().length||n.ownerDocument.defaultView.getComputedStyle(n).visibility==='hidden');
    const privateText=e=>!e||ancestry(e,n=>n.matches('script,style,noscript,input,textarea,select,[contenteditable],[hidden],[aria-hidden=true],[data-private],[data-secret]'));
    const regions=root=>{const result=[root];for(let i=0;i<result.length&&result.length<256;i++)for(const e of result[i].querySelectorAll('*')){if(e.shadowRoot)result.push(e.shadowRoot);if(e.matches('iframe,frame'))try{if(e.contentDocument)result.push(e.contentDocument)}catch{}}return result;};
    const query=(root,selector)=>regions(root).flatMap(r=>[...r.querySelectorAll(selector)]);
    const role=e=>e.getAttribute('role')||({BUTTON:'button',A:'link',SELECT:'combobox',TEXTAREA:'textbox'}[e.tagName])||(e.tagName==='INPUT'?(['checkbox','radio'].includes(e.type)?e.type:'textbox'):'');
    const safeText=e=>{let text='';for(const r of regions(e)){const walker=r.ownerDocument?r.ownerDocument.createTreeWalker(r,NodeFilter.SHOW_TEXT):r.createTreeWalker(r,NodeFilter.SHOW_TEXT);while(walker.nextNode()&&text.length<400){const n=walker.currentNode;if(!privateText(n.parentElement)&&!hidden(n.parentElement))text+=n.textContent+' ';}}return text;};
    const name=e=>(e.getAttribute('aria-label')||e.getAttribute('alt')||e.getAttribute('title')||(e.labels&&[...e.labels].map(safeText).join(' '))||(!e.matches('input,textarea,select,[contenteditable]')?safeText(e):'')||'').trim().replace(/\s+/g,' ').slice(0,200);
    const choose=(root,selector)=>{
      if(!selector)return [root];
      const path=selector.split(' >>> ');if(path.length>1){let scope=root;for(let i=0;i<path.length-1;i++){const e=choose(scope,path[i])[0];if(!e)return [];scope=e.shadowRoot;try{scope=scope||e.contentDocument}catch{}if(!scope)return [];}return choose(scope,path[path.length-1]);}
      if(selector.startsWith('text=')){let value=selector.slice(5);try{value=JSON.parse(value)}catch{}const candidates=query(root,'*').filter(e=>!hidden(e)&&!privateText(e)&&name(e).includes(value));return candidates.filter(e=>!candidates.some(c=>c!==e&&e.contains(c)));}
      if(selector.startsWith('role=')){const m=/^role=([a-zA-Z-]+)(?:\[name=(.*)\])?$/.exec(selector);if(!m)throw Error('Choose role=button[name="Name"]');let value=m[2];if(value){try{value=JSON.parse(value)}catch{}}return query(root,'*').filter(e=>!hidden(e)&&role(e)===m[1]&&(!value||name(e)===value));}
      return query(root,selector);
    };
    const ref=e=>{const root=e.getRootNode();let local;if(e.id)local='#'+CSS.escape(e.id);else{const p=[];for(let n=e;n&&n.nodeType===1&&p.length<12;n=n.parentElement){let at=1;for(let s=n.previousElementSibling;s;s=s.previousElementSibling)if(s.tagName===n.tagName)at++;p.unshift(n.tagName.toLowerCase()+':nth-of-type('+at+')');}local=p.join(' > ');}if(root.host)return ref(root.host)+' >>> '+local;try{const frame=e.ownerDocument.defaultView.frameElement;if(frame)return ref(frame)+' >>> '+local}catch{}return local;};
    """;
  private static int Number(JsonElement a, string key, int fallback, int min, int max) => a.TryGetProperty(key, out var n) && n.TryGetInt32(out var value) ? Math.Clamp(value, min, max) : fallback;
  private static string? Text(JsonElement a, string key) => a.TryGetProperty(key, out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
  public static string Read(JsonElement args)
  {
    var selector = Text(args, "within") ?? Text(args, "selector") ?? "body";
    if (selector.Length > 2000) throw new ArgumentException("Choose a short selector.");
    var config = JsonSerializer.Serialize(new { selector, offset = Number(args, "offset", 0, 0, 5000), limit = Number(args, "limit", 100, 1, 200), textChars = Number(args, "textChars", 12000, 1, 30000) });
    return "(()=>{" + Helpers + "const cfg=" + config + ";const roots=choose(document,cfg.selector).filter(e=>!hidden(e)).slice(0,500);if(!roots.length)return {found:false,url:location.href};" + """
      let text='';const links=[];const seen=new Set();const nodes=[];const unique=new Set();const textNodes=new WeakSet();
      for(const root of roots){
        if(!privateText(root)){for(const region of regions(root)){const owner=region.ownerDocument||region;const walker=owner.createTreeWalker(region,NodeFilter.SHOW_TEXT);while(walker.nextNode()&&text.length<cfg.textChars){const n=walker.currentNode;if(textNodes.has(n)||privateText(n.parentElement)||hidden(n.parentElement))continue;textNodes.add(n);text+=n.textContent+' ';}}}
        for(const e of [root,...query(root,'a[href],button,input,select,textarea,[contenteditable],[role],[tabindex]')]){
          if(unique.has(e)||hidden(e))continue;unique.add(e);
          if(e.matches('a[href]')&&/^https?:/i.test(e.href)&&links.length<150&&!seen.has(e.href+'\n'+name(e))){seen.add(e.href+'\n'+name(e));const href=e.href,label=name(e);links.push({text:label,href});}
          if(e.matches('a[href],button,input,select,textarea,[contenteditable],[role],[tabindex]'))nodes.push(e);
        }
      }
      const elements=nodes.slice(cfg.offset,cfg.offset+cfg.limit).map((e,i)=>({index:cfg.offset+i,selector:ref(e),tag:e.tagName.toLowerCase(),role:role(e),name:name(e),disabled:!!e.disabled||e.getAttribute('aria-disabled')==='true',
        ...(['checkbox','radio'].includes(e.type)?{checked:!!e.checked}:e.hasAttribute('aria-checked')?{checked:e.getAttribute('aria-checked')==='true'}:{}),
        ...(e.hasAttribute('aria-expanded')?{expanded:e.getAttribute('aria-expanded')==='true'}:{}),...(e.hasAttribute('aria-selected')?{selected:e.getAttribute('aria-selected')==='true'}:{})}));
      return {found:true,untrusted:true,source:{kind:'webpage',origin:location.origin},url:location.href,title:document.title,matches:roots.length,text:text.slice(0,cfg.textChars),links,elements,offset:cfg.offset,totalElements:nodes.length,nextOffset:cfg.offset+elements.length<nodes.length?cfg.offset+elements.length:null,formValuesOmitted:true};
      })()
      """;
  }
  public static string Step(JsonElement args)
  {
    var verb = Text(args, "verb") ?? ""; var selector = Text(args, "selector") ?? throw new ArgumentException("Choose an element selector.");
    if (selector.Length > 2000) throw new ArgumentException("Choose a short element selector.");
    var value = Text(args, "value") ?? "";
    if (value.Length > 16000) throw new ArgumentException("This entry is too large.");
    var operation = verb switch
    {
      "click" => "e.click()",
      "type" => "if(!(e.tagName==='INPUT'||e.tagName==='TEXTAREA')||e.type==='password'||e.type==='file'||e.matches('[autocomplete*=password],[autocomplete*=cc-],[data-private],[data-secret]'))throw Error('This field needs the person');const setter=Object.getOwnPropertyDescriptor(e.tagName==='TEXTAREA'?e.ownerDocument.defaultView.HTMLTextAreaElement.prototype:e.ownerDocument.defaultView.HTMLInputElement.prototype,'value').set;setter.call(e," + JsonSerializer.Serialize(value) + ");e.dispatchEvent(new e.ownerDocument.defaultView.Event('input',{bubbles:true}));e.dispatchEvent(new e.ownerDocument.defaultView.Event('change',{bubbles:true}))",
      "select" => "if(!(e.tagName==='SELECT'))throw Error('Choose a selection field');e.value=" + JsonSerializer.Serialize(value) + ";e.dispatchEvent(new e.ownerDocument.defaultView.Event('change',{bubbles:true}))",
      "check" => "if(!(e.tagName==='INPUT')||!['checkbox','radio'].includes(e.type))throw Error('Choose a checkbox');if(e.checked!==" + (value is "false" or "0" ? "false" : "true") + ")e.click()",
      "submit" => "const form=e.tagName==='FORM'?e:e.form;if(!form)throw Error('Choose a form');form.requestSubmit()",
      "press" => "e.focus()",
      _ => throw new ArgumentException("Choose click, type, select, check, press or submit.")
    };
    var config = JsonSerializer.Serialize(new { selector, nth = Number(args, "nth", 0, 0, 5000), within = Text(args, "within") });
    return "(()=>{" + Helpers + "const cfg=" + config + ";const scope=cfg.within?choose(document,cfg.within)[0]:document;if(!scope)throw Error('The scope is not on the page');const e=choose(scope,cfg.selector)[cfg.nth];if(!e||hidden(e))throw Error('The element is not visible');if(ancestry(e,n=>n.matches('[data-private],[data-secret]')))throw Error('This region needs the person');e.scrollIntoView({block:'center'});" + """
      const box=e.getBoundingClientRect();const doc=e.ownerDocument,view=doc.defaultView;let cover=doc.elementFromPoint(Math.max(0,Math.min(view.innerWidth-1,box.left+box.width/2)),Math.max(0,Math.min(view.innerHeight-1,box.top+box.height/2)));while(cover&&cover.shadowRoot){const inner=cover.shadowRoot.elementFromPoint(box.left+box.width/2,box.top+box.height/2);if(!inner||inner===cover)break;cover=inner;}
      if(cover&&cover!==e&&!e.contains(cover)&&!cover.contains(e))throw Error('Covered by '+cover.tagName.toLowerCase()+' '+name(cover)+' ('+ref(cover)+')');
      """ + operation + ";return {done:true,url:location.href};})()";
  }
}
