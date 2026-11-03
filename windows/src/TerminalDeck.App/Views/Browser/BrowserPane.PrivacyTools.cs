using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Browser;
namespace TerminalDeck.App.Views;
public sealed partial class BrowserPane
{
  public void RegisterPrivacyTools(McpDoor door)
  {
    door.Register("browser.privacy", async (context, args, ct) =>
    {
      if (!context.Grant.OwnerApplication && !ReferenceEquals(context.Grant.Scope, McpCallerScopes.Everything)) throw new McpRefusal("Browser sign-in management is for the person and Hoot. Use this session's browser tools or ask the person to open Browser settings.");
      context.Require("settings", "browser");
      var profile = args.GetProperty("profile").GetString()!; _ = Core.Read().Profiles.Single(p => p.Id == profile); context.Require("profiles", profile);
      string? Text(string key) => args.TryGetProperty(key, out var value) ? value.GetString() : null;
      var action = Text("action"); await context.EnsureCurrentAsync(ct);
      if (action == "list") return JsonSerializer.SerializeToElement(new { preferences = Privacy.Read(), passwords = Privacy.Logins(profile), cookies = await BrowserCookieCountAsync(profile) });
      switch (action)
      {
        case "preferences": context.Require("settings", "workspace"); await SetBrowserPrivacyAsync(Privacy.Read() with { PersistSignIns = args.TryGetProperty("persistSignIns", out var keep) ? keep.GetBoolean() : Privacy.Read().PersistSignIns, SavePasswords = args.TryGetProperty("savePasswords", out var save) ? save.GetBoolean() : Privacy.Read().SavePasswords }); break;
        case "cookies-clear": await ClearBrowserSignInsAsync(profile); break;
        case "cookies-import":
          var file = Path.GetFullPath(Text("file") ?? throw new ArgumentException("Choose an exported JSON file.")); context.Require("files", file);
          if (new FileInfo(file).Length > 2 * 1024 * 1024) throw new ArgumentException("Import up to 2 MB of cookies.");
          var text = await BrowserPrivacy.ReadCookieFileAsync(file, ct); await context.EnsureCurrentAsync(ct); await ImportBrowserCookiesAsync(profile, text); break;
        case "password-save": await Privacy.SaveLoginAsync(profile, Text("site")!, Text("username") ?? "", Text("password")!, ct); break;
        case "password-copy": await CopyBrowserPasswordAsync(profile, Text("id")!); break;
        case "password-fill":
          if (selected is null) throw new InvalidOperationException("Select a browser tab first.");
          context.Require("profiles", selected.Profile.Id); var url = new Uri(selected.View.CoreWebView2.Source).GetLeftPart(UriPartial.Authority); context.Require("origins", url);
          await FillBrowserPasswordAsync(profile, Text("id")!); break;
        case "password-forget": await Privacy.ForgetAsync(profile, Text("id"), ct); break;
        default: throw new ArgumentException("Choose a supported browser privacy action.");
      }
      await context.EnsureCurrentAsync(ct); return JsonSerializer.SerializeToElement(new { done = true });
    });
  }
}
