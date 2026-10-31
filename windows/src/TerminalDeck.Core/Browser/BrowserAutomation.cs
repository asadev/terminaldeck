using System.Text.Json;

namespace TerminalDeck.Core.Browser;

// These are fixed operations with JSON-quoted selectors/values. There is no
// caller-supplied JavaScript. Reads omit form values and marked private regions.
public static class BrowserAutomation
{
  public const int LinkLimit = 150;
  public static string ReadScript(JsonElement args)
  {
    var selector = args.TryGetProperty("selector", out var choice) ? choice.GetString() : "body";
    var limit = args.TryGetProperty("textChars", out var count) ? Math.Clamp(count.GetInt32(), 1, 30000) : 12000;
    // Every match of the selector, plus the web links inside it (CAPTEST rerun S1:
    // headlines came back without their addresses). Hidden and private regions stay out.
    return "(()=>{const roots=[...document.querySelectorAll(" + JsonSerializer.Serialize(selector) + ")].slice(0,500);if(!roots.length)return {found:false,url:location.href};" +
      "const hidden=p=>!p||p.closest('script,style,noscript,input,textarea,select,[contenteditable],[hidden],[aria-hidden=true],[data-private],[data-secret]')||!p.getClientRects().length;" +
      "let text='';const links=[];const seen=new Set();for(const root of roots){const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);while(walker.nextNode()&&text.length<" + limit + "){const n=walker.currentNode,p=n.parentElement;if(hidden(p))continue;text+=n.textContent+' ';}" +
      "for(const a of root.matches('a[href]')?[root]:root.querySelectorAll('a[href]')){if(links.length>=" + LinkLimit + ")break;const href=a.href,label=a.textContent.trim().slice(0,200);if(hidden(a)||!/^https?:/i.test(href)||seen.has(href+'\\n'+label))continue;seen.add(href+'\\n'+label);links.push({text:label,href});}}" +
      "return {found:true,untrusted:true,source:{kind:'webpage',origin:location.origin},url:location.href,title:document.title,matches:roots.length,text:text.slice(0," + limit + "),links,formValuesOmitted:true};})()";
  }
  public static string StepScript(JsonElement args)
  {
    var verb = args.GetProperty("verb").GetString(); var selector = args.GetProperty("selector").GetString();
    if (selector is null || selector.Length > 2000) throw new ArgumentException("Choose a short element selector.");
    var value = args.TryGetProperty("value", out var text) ? text.GetString() ?? "" : "";
    if (value.Length > 16000) throw new ArgumentException("This entry is too large.");
    var operation = verb switch
    {
      "click" => "e.click()",
      "type" => "if(!(e instanceof HTMLInputElement||e instanceof HTMLTextAreaElement)||e.type==='password'||e.matches('[autocomplete*=password],[autocomplete*=cc-],[data-private],[data-secret]'))throw Error('This field needs the person');const setter=Object.getOwnPropertyDescriptor(e instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype,'value').set;setter.call(e," + JsonSerializer.Serialize(value) + ");e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}))",
      "select" => "if(!(e instanceof HTMLSelectElement))throw Error('Choose a selection field');e.value=" + JsonSerializer.Serialize(value) + ";e.dispatchEvent(new Event('change',{bubbles:true}))",
      "check" => "if(!(e instanceof HTMLInputElement)||!['checkbox','radio'].includes(e.type))throw Error('Choose a checkbox');if(e.checked!==" + (value is "false" or "0" ? "false" : "true") + ")e.click()",
      "submit" => "const form=e instanceof HTMLFormElement?e:e.form;if(!form)throw Error('Choose a form');form.requestSubmit()",
      "press" => "e.focus()",
      _ => throw new ArgumentException("Choose a listed browser step.")
    };
    return "(()=>{const e=document.querySelector(" + JsonSerializer.Serialize(selector) + ");if(!e||!e.getClientRects().length)throw Error('The element is not visible');if(e.closest('[data-private],[data-secret]'))throw Error('This region needs the person');e.scrollIntoView({block:'center'});" + operation + ";return {done:true,url:location.href};})()";
  }
  public const string HidePrivate = """
(()=>{if(window.__tdPrivateCapture)throw Error('A capture is already running');const undo=[];const ids=new WeakMap();let next=0;const collect=(root,result)=>{for(const e of root.querySelectorAll('*')){if(e.shadowRoot)collect(e.shadowRoot,result);const secret=e.matches('[data-private],[data-secret]')||e.matches('input,textarea')&&(e.type==='password'||/password|one-time-code|cc-number|cc-csc|cc-exp/i.test(e.autocomplete||'')||/card.?num|cc.?num|cvc|cvv|csc/i.test((e.name||'')+' '+e.id));if(secret)result.push(e);if(e.matches('iframe,frame')){let doc;try{doc=e.contentDocument;if(doc)collect(doc,result);else result.push(e);}catch{result.push(e);}}}};window.__tdCaptureFingerprint=()=>{const fields=[];collect(document,fields);return JSON.stringify([location.href,...fields.map(e=>{if(!ids.has(e))ids.set(e,++next);if(getComputedStyle(e).visibility!=='hidden')throw Error('A protected field became visible');const boxes=[];for(let n=e;n;){const r=n.getBoundingClientRect();boxes.push([r.x,r.y,r.width,r.height]);n=n.ownerDocument.defaultView.frameElement;}return [ids.get(e),...boxes];})]);};window.__tdPrivateCapture=undo;try{const fields=[];collect(document,fields);for(const e of fields){undo.push([e,e.style.getPropertyValue('visibility'),e.style.getPropertyPriority('visibility')]);e.style.setProperty('visibility','hidden','important');}return window.__tdCaptureFingerprint();}catch(error){for(const [e,value,priority]of undo)e.style.setProperty('visibility',value,priority);delete window.__tdPrivateCapture;delete window.__tdCaptureFingerprint;throw error;}})()
""";
  public const string CaptureFingerprint = "window.__tdCaptureFingerprint()";
  public const string RestorePrivate = """
(()=>{for(const [e,value,priority]of window.__tdPrivateCapture||[]) {if(value)e.style.setProperty('visibility',value,priority);else e.style.removeProperty('visibility');}delete window.__tdPrivateCapture;delete window.__tdCaptureFingerprint;})()
""";
}
