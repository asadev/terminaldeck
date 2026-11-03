namespace TerminalDeck.Core.Browser;

public sealed record BrowserStartPage(string Url)
{
  public static string Validate(string value)
  {
    value = value.Trim();
    if (value.Length == 0) return "";
    if (value.Length > 2048 || !Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.UserInfo.Length != 0)
      throw new ArgumentException("Enter an http or https address without a username or password, or leave it empty.");
    return uri.AbsoluteUri;
  }
}

// ui.workspace already classifies reads freely and changes through the caller's permission flow.
public sealed class BrowserStartPageSettings(TerminalDeck.Core.Storage.IStateStore<BrowserStartPage> store, BrowserModel? browser = null)
{
  public string Read() => browser is null ? BrowserStartPage.Validate(store.Load()?.Url ?? "") : browser.Read().StartUrl == "about:blank" ? "" : browser.Read().StartUrl;
  public void Save(string value) => store.Save(new(BrowserStartPage.Validate(value)));

  public void Register(TerminalDeck.Core.Mcp.McpDoor door) => door.Compose("ui.workspace", previous => async (context, args, ct) =>
  {
    context.Require("settings", "workspace");
    var changing = args.TryGetProperty("browserStartUrl", out var url);
    var remaining = args.EnumerateObject().Where(p => p.Name != "browserStartUrl").ToDictionary(p => p.Name, p => p.Value.Clone());
    string? value = null;
    if (changing)
    {
      if (url.ValueKind != System.Text.Json.JsonValueKind.String) throw new ArgumentException("Enter a start page address, or an empty string.");
      value = BrowserStartPage.Validate(url.GetString()!);
    }
    var state = previous is null ? System.Text.Json.JsonSerializer.SerializeToElement(new { }) :
      await previous(context, System.Text.Json.JsonSerializer.SerializeToElement(remaining), ct);
    if (value is not null)
    {
      await context.EnsureCurrentAsync(ct);
      if (browser is null) Save(value); else await browser.SetStartUrlAsync(value.Length == 0 ? "about:blank" : value, ct);
    }
    var result = state.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
    result["browserStartUrl"] = System.Text.Json.JsonSerializer.SerializeToElement(Read());
    return System.Text.Json.JsonSerializer.SerializeToElement(result);
  });
}
