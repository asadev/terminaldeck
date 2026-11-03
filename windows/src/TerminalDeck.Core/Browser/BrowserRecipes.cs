using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Browser;

// These six built-ins read public DOM conventions. There is no downloaded script
// or arbitrary evaluation input in the Store's page-read permission.
public static class BrowserRecipes
{
  public static readonly string[] Ids = ["page-images", "page-data", "page-links", "page-tables", "page-article", "page-feeds"];
  public static string Script(string id)
  {
    if (!Ids.Contains(id)) throw new ArgumentException("Choose an installed browser tool.");
    return "(()=>{const kind=" + JsonSerializer.Serialize(id) + ";" + """
      const hidden=e=>!e||e.closest('[data-private],[data-secret],input,textarea,select,[contenteditable],[hidden],[aria-hidden=true]');
      const clean=e=>{if(!e||hidden(e))return '';const c=e.cloneNode(true);c.querySelectorAll('script,style,noscript,input,textarea,select,[contenteditable],[data-private],[data-secret],[hidden],[aria-hidden=true]').forEach(n=>n.remove());return (c.textContent||'').replace(/\s+/g,' ').trim().slice(0,16000)};
      const all=s=>[...document.querySelectorAll(s)].filter(e=>!hidden(e)).slice(0,500);
      const url=s=>{if(typeof s!=='string'||!s.trim())return null;try{const u=new URL(s,location.href);return ['http:','https:'].includes(u.protocol)&&!u.username&&!u.password?u.href:null}catch{return null}};
      let value={};
      if(kind==='page-images'){
        value.images=all('img,picture source').map(e=>{
          const candidates=[];
          for(const attr of ['src','data-src','data-original','data-lazy-src','data-full','href']){const u=url(e.getAttribute(attr));if(u)candidates.push({url:u,source:attr})}
          if(e.currentSrc){const u=url(e.currentSrc);if(u)candidates.push({url:u,source:'currentSrc'})}
          for(const attr of ['srcset','data-srcset'])for(const item of (e.getAttribute(attr)||'').split(',')){const [src,size]=item.trim().split(/\s+/),u=url(src);if(u)candidates.push({url:u,size:size||null,source:attr})}
          return {alt:(e.getAttribute('alt')||'').slice(0,500),candidates,width:e.naturalWidth||null,height:e.naturalHeight||null}
        });value.stated=document.querySelectorAll('img').length;
      }else if(kind==='page-data'){
        value.structured=[...document.querySelectorAll('script[type="application/ld+json"]')].slice(0,50).map(e=>{try{if(e.textContent.length>50000)return {truncated:true};return JSON.parse(e.textContent)}catch{return {invalid:true}}});
        value.meta=all('meta[property^="og:"],meta[name^="twitter:"]').map(e=>({name:e.getAttribute('property')||e.name,content:(e.content||'').slice(0,4000)}));
        value.microdata=all('[itemprop]').map(e=>({name:e.getAttribute('itemprop'),value:e.getAttribute('content')||clean(e)}));
      }else if(kind==='page-links'){
        value.links=all('a[href]').map(e=>({text:clean(e).slice(0,500),url:url(e.getAttribute('href'))})).filter(e=>e.url);value.next=all('link[rel=next],a[rel=next]').map(e=>url(e.getAttribute('href'))).filter(Boolean);
      }else if(kind==='page-tables'){
        value.tables=all('table').slice(0,30).map(e=>({caption:clean(e.querySelector('caption')),rows:[...e.rows].slice(0,100).map(r=>[...r.cells].slice(0,50).map(c=>clean(c).slice(0,1000)))}));
      }else if(kind==='page-article'){
        const article=document.querySelector('article')||document.querySelector('main')||document.body;value={title:document.title,headline:clean(article.querySelector('h1')),text:clean(article),author:all('[rel=author],meta[name=author]').map(e=>e.content||clean(e)),canonical:url(document.querySelector('link[rel=canonical]')?.href||location.href)};
      }else{
        value.feeds=all('link[rel=alternate],a[href]').filter(e=>/rss|atom|feed/i.test((e.getAttribute('type')||'')+' '+(e.getAttribute('href')||''))).map(e=>({url:url(e.getAttribute('href')),title:e.getAttribute('title')||clean(e),type:e.getAttribute('type')})).filter(e=>e.url);
      }
      let json=JSON.stringify(value),truncated=false;
      // Reduce whole rows rather than return malformed cut JSON.
      while(new TextEncoder().encode(json).length>50000){const arrays=Object.values(value).filter(Array.isArray).sort((a,b)=>b.length-a.length);if(!arrays.length||!arrays[0].length){value={text:clean(document.body).slice(0,10000)};truncated=true;break}arrays[0].pop();truncated=true;json=JSON.stringify(value)}
      return {tool:kind,url:location.href,title:document.title,value,truncated,untrusted:true};
    })()
    """;
  }
  public static IReadOnlyList<McpToolSpec> Specs => [new("browser.extract", "browser_extract", McpTier.Read, JsonSerializer.SerializeToElement(new
  { type = "object", properties = new { window = new { type = "string" }, sessionId = new { type = "string" }, tool = new { type = "string", @enum = Ids } }, required = new[] { "tool" }, additionalProperties = false }))];
}

public static partial class BrowserTools
{
  public static void RegisterRecipes(McpDoor door, BrowserModel browser, Func<string, bool> installed)
  {
    door.Register("browser.extract", async (caller, args, ct) =>
    {
      var id = DeckCoreTools.Required(args, "tool");
      if (!BrowserRecipes.Ids.Contains(id) || !installed(id)) throw new McpRefusal("Install this browser tool from Store › Browser tools first.");
      var tab = Resolve(caller, args, browser)!; caller.Require("profiles", tab.ProfileId); RequireOrigin(caller, tab.Url); await caller.EnsureCurrentAsync(ct);
      var result = await browser.PerformAsync(tab.Id, BrowserPageAction.Extract, JsonSerializer.SerializeToElement(new { tool = id }), ct);
      if (result.TryGetProperty("url", out var url)) RequireOrigin(caller, url.GetString()!); await caller.EnsureCurrentAsync(ct); return result;
    });
  }
}
