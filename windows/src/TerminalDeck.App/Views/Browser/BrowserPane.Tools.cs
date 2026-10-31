using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private JsonElement ReadWorkspace(BrowserTab tab, JsonElement args)
  {
    var command = args.GetProperty("command").GetString();
    return command switch
    {
      "downloads" => JsonSerializer.SerializeToElement(downloads.Where(d => d.TabId == tab.Id).Select(d => new { d.Id, d.Url, d.Path, d.State, bytes = d.Operation.BytesReceived, total = d.Operation.TotalBytesToReceive })),
      "annotations" => JsonSerializer.SerializeToElement(new { on = tab.Inspecting, markers = tab.Annotations, instruction = tab.AnnotationDraft, untrusted = true }),
      "drawing" => JsonSerializer.SerializeToElement(new { marks = tab.Drawing.Marks, path = tab.CapturePath }),
      "viewport" => JsonSerializer.SerializeToElement(new { size = tab.Viewport, phoneUserAgent = tab.PhoneAgent, zoom = tab.Zoom }),
      _ => throw new ArgumentException("Choose downloads, annotations, viewport, history or settings.")
    };
  }
  private async Task<JsonElement> ChangeWorkspaceAsync(BrowserTab tab, JsonElement args)
  {
    string Text(string key) => args.TryGetProperty(key, out var value) ? value.GetString() ?? "" : "";
    switch (Text("command"))
    {
      case "downloadStop": downloads.Single(d => d.Id == Text("id") && d.TabId == tab.Id).Operation.Cancel(); break;
      case "downloadClear": downloads.RemoveAll(d => d.TabId == tab.Id && d.Operation.State != CoreWebView2DownloadState.InProgress); break;
      case "annotationDelete":
        if (!int.TryParse(Text("id"), out var marker)) throw new ArgumentException("Choose a numbered marker.");
        tab.Annotations.RemoveAll(a => a.Number == marker); await tab.Model.CommandAsync("Runtime.evaluate", new { expression = TerminalDeck.Core.Browser.BrowserInspection.Delete(marker) }); break;
      case "annotationInstruction": tab.AnnotationDraft = Text("text"); break;
      case "annotationSend": await SendAnnotationsAsync(tab); break;
      case "annotationDiscard": tab.Annotations.Clear(); tab.AnnotationDraft = ""; await tab.Model.CommandAsync("Runtime.evaluate", new { expression = TerminalDeck.Core.Browser.BrowserInspection.Clear }); await InspectAsync(tab, false); break;
      case "draw": await DrawAsync(tab); break;
      case "drawingUndo": tab.Drawing.Undo(); tab.DrawingChanged?.Invoke(); break;
      case "drawingClear": tab.Drawing.Clear(); tab.DrawingChanged?.Invoke(); break;
      case "drawingAdd":
        if (!Enum.TryParse<TerminalDeck.Core.Browser.BrowserDrawTool>(Text("tool"), out var tool)) throw new ArgumentException("Choose Draw, Box, Arrow or Text.");
        var points = args.GetProperty("points").EnumerateArray().Select(p => new TerminalDeck.Core.Browser.BrowserDrawPoint(p.GetProperty("x").GetDouble(), p.GetProperty("y").GetDouble())).ToArray();
        tab.Drawing.Add(new(tool, points, Text("text"))); tab.DrawingChanged?.Invoke(); break;
      case "home": await ExecuteTabAsync(tab, "home"); break;
      case "shot": await ShotAsync(tab); break;
      case "landscape": tab.Viewport = tab.Viewport.Landscape(); await ApplyViewportAsync(tab); break;
      case "phoneUserAgent": tab.PhoneAgent = Text("text") == "true"; await ApplyViewportAsync(tab); break;
      default: throw new ArgumentException("Choose a listed browser workspace change.");
    }
    RefreshShellViews(); DownloadsChanged?.Invoke(); return JsonSerializer.SerializeToElement(new { done = true });
  }
}
