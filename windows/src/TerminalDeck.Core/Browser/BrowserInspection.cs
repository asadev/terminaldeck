using System.Text.Json;

namespace TerminalDeck.Core.Browser;

// The picker reports context only. Page messages cannot request app operations.
public static class BrowserInspection
{
  public const string Start = """
(()=>{window.__tdInspectOn=true;if(window.__tdInspect)return;const box=document.createElement('div');box.id='td-inspect-highlight';box.style.cssText='position:fixed;pointer-events:none;z-index:2147483647;border:2px solid Highlight;background:transparent;display:none';document.documentElement.append(box);const selector=e=>{if(e.id)return '#'+CSS.escape(e.id);const parts=[];for(let n=e;n&&n.nodeType===1&&parts.length<7;n=n.parentElement){let p=n.localName;const siblings=n.parentElement?[...n.parentElement.children].filter(x=>x.localName===n.localName):[];if(siblings.length>1)p+=':nth-of-type('+(siblings.indexOf(n)+1)+')';parts.unshift(p);}return parts.join(' > ')};const move=e=>{if(!window.__tdInspectOn)return;const r=e.target.getBoundingClientRect();Object.assign(box.style,{display:'block',left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'});};const click=e=>{if(!window.__tdInspectOn)return;e.preventDefault();e.stopImmediatePropagation();const target=e.target;if(!(target instanceof Element)||target.closest('[data-private],[data-secret],input[type=password]'))return;window.chrome.webview.postMessage({kind:'td-inspect',selector:selector(target),description:(target.localName+' '+(target.getAttribute('aria-label')||'')).slice(0,500)});};document.addEventListener('pointermove',move,true);document.addEventListener('click',click,true);window.__tdInspect={box,move,click};})();
""";
  public const string Stop = """
(()=>{window.__tdInspectOn=false;const i=window.__tdInspect;if(i){document.removeEventListener('pointermove',i.move,true);document.removeEventListener('click',i.click,true);i.box.remove();delete window.__tdInspect;}})();
""";
  public static string Mark(string selector, int number) =>
    "(()=>{const e=document.querySelector(" + JsonSerializer.Serialize(selector) + ");if(!e)return;const r=e.getBoundingClientRect();const m=document.createElement('div');m.dataset.tdAnnotation=" + JsonSerializer.Serialize(number.ToString(System.Globalization.CultureInfo.InvariantCulture)) + ";m.textContent=m.dataset.tdAnnotation;m.style.cssText='position:absolute;z-index:2147483646;pointer-events:none;border-radius:50%;padding:3px 7px;background:Highlight;color:HighlightText;font:600 13px system-ui';m.style.left=(r.left+scrollX)+'px';m.style.top=(r.top+scrollY)+'px';document.documentElement.append(m);})()";
  public static string Select(string selector, int number) =>
    "(()=>{document.querySelector(" + JsonSerializer.Serialize(selector) + ")?.scrollIntoView({block:'center'});for(const m of document.querySelectorAll('[data-td-annotation]')){const selected=m.dataset.tdAnnotation===" + JsonSerializer.Serialize(number.ToString(System.Globalization.CultureInfo.InvariantCulture)) + ";m.style.background=selected?'Highlight':'Canvas';m.style.color=selected?'HighlightText':'CanvasText';}})()";
  public static string Delete(int number) => "document.querySelector('[data-td-annotation=\"" + number.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\"]')?.remove()";
  public const string Clear = "document.querySelectorAll('[data-td-annotation]').forEach(e=>e.remove())";
}
