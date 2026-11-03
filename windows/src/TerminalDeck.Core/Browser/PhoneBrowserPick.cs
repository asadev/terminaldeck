using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Browser;

public static class PhoneBrowserPick
{
  public static string Script(JsonElement message)
  {
    double Number(string key) => message.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number) ? Math.Clamp(number, 0, 1000000) : throw new PhoneRefusal("bad-message", "Pick coordinates must be finite numbers.");
    var up = message.TryGetProperty("up", out var level) && level.TryGetInt32(out var amount) ? Math.Clamp(amount, 0, 30) : 0;
    var config = JsonSerializer.Serialize(new { x = Number("x"), y = Number("y"), up });
    return "(()=>{" + BrowserDomAutomation.DomHelpers + "const cfg=" + config + ";" + """
      let doc=document,cx=cfg.x-scrollX,cy=cfg.y-scrollY;
      let e=doc.elementFromPoint(cx,cy);const seen=new Set();
      while(e&&!seen.has(e)){seen.add(e);let inner=null;if(e.shadowRoot)inner=e.shadowRoot.elementFromPoint(cx,cy);if(inner&&inner!==e){e=inner;continue;}
        if(e.matches('iframe,frame')){try{const next=e.contentDocument;if(next){const box=e.getBoundingClientRect();cx-=box.left+e.clientLeft;cy-=box.top+e.clientTop;doc=next;e=doc.elementFromPoint(cx,cy);continue;}}catch{}}
        break;
      }
      if(!e)return {found:false};
      let maxUp=0;for(let n=parent(e);n&&maxUp<30;n=parent(n))maxUp++;
      let depth=0;while(depth<cfg.up&&parent(e)){e=parent(e);depth++;}
      if(ancestry(e,n=>n.matches('[data-private],[data-secret]')))return {found:false};
      const box=e.getBoundingClientRect();let gx=box.x,gy=box.y,owner=e.ownerDocument;
      for(let i=0;i<30;i++){let frame;try{frame=owner.defaultView.frameElement}catch{}if(!frame)break;const r=frame.getBoundingClientRect();gx+=r.x+frame.clientLeft;gy+=r.y+frame.clientTop;owner=frame.ownerDocument;}
      gx+=scrollX;gy+=scrollY;
      let label='',source='';if(e.getAttribute('aria-label')){label=e.getAttribute('aria-label');source='aria-label';}
      else if(e.labels&&e.labels.length){label=[...e.labels].map(safeText).join(' ');source='label';}
      else if(e.getAttribute('title')){label=e.getAttribute('title');source='title';}
      else if(e.getAttribute('alt')){label=e.getAttribute('alt');source='alt';}
      else if(!e.matches('input,textarea,select,[contenteditable]')){label=safeText(e);source='text';}
      return {found:true,tag:e.tagName.toLowerCase(),selector:ref(e).slice(0,2000),label:label.trim().replace(/\s+/g,' ').slice(0,200),labelSource:source,rect:{x:gx,y:gy,w:box.width,h:box.height},depth,maxUp};
      })()
      """;
  }
}
