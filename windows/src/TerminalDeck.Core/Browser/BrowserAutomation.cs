using System.Text.Json;

namespace TerminalDeck.Core.Browser;

// These are fixed operations with JSON-quoted selectors/values. There is no
// caller-supplied JavaScript. Reads omit form values and marked private regions.
public static class BrowserAutomation
{
  public const int LinkLimit = 150;
  public static string ReadScript(JsonElement args) => BrowserDomAutomation.Read(args);
  public static string StepScript(JsonElement args) => BrowserDomAutomation.Step(args);
  public const string HidePrivate = """
(()=>{if(window.__tdPrivateCapture)throw Error('A capture is already running');const undo=[];const ids=new WeakMap();let next=0;const collect=(root,result)=>{for(const e of root.querySelectorAll('*')){if(e.shadowRoot)collect(e.shadowRoot,result);const secret=e.matches('[data-private],[data-secret]')||e.matches('input,textarea')&&(e.type==='password'||/password|one-time-code|cc-number|cc-csc|cc-exp/i.test(e.autocomplete||'')||/card.?num|cc.?num|cvc|cvv|csc/i.test((e.name||'')+' '+e.id));if(secret)result.push(e);if(e.matches('iframe,frame')){let doc;try{doc=e.contentDocument;if(doc)collect(doc,result);else result.push(e);}catch{result.push(e);}}}};window.__tdCaptureFingerprint=()=>{const fields=[];collect(document,fields);return JSON.stringify([location.href,...fields.map(e=>{if(!ids.has(e))ids.set(e,++next);if(getComputedStyle(e).visibility!=='hidden')throw Error('A protected field became visible');const boxes=[];for(let n=e;n;){const r=n.getBoundingClientRect();boxes.push([r.x,r.y,r.width,r.height]);n=n.ownerDocument.defaultView.frameElement;}return [ids.get(e),...boxes];})]);};window.__tdPrivateCapture=undo;try{const fields=[];collect(document,fields);for(const e of fields){undo.push([e,e.style.getPropertyValue('visibility'),e.style.getPropertyPriority('visibility')]);e.style.setProperty('visibility','hidden','important');}return window.__tdCaptureFingerprint();}catch(error){for(const [e,value,priority]of undo)e.style.setProperty('visibility',value,priority);delete window.__tdPrivateCapture;delete window.__tdCaptureFingerprint;throw error;}})()
""";
  public const string CaptureFingerprint = "window.__tdCaptureFingerprint()";
  public const string RestorePrivate = """
(()=>{for(const [e,value,priority]of window.__tdPrivateCapture||[]) {if(value)e.style.setProperty('visibility',value,priority);else e.style.removeProperty('visibility');}delete window.__tdPrivateCapture;delete window.__tdCaptureFingerprint;})()
""";
}
