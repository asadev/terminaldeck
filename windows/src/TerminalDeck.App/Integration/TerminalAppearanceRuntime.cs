using System.Text.Json;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private TerminalAppearanceService? terminalAppearance;
  public TerminalAppearanceService TerminalAppearance => terminalAppearance ??= new(new JsonStateStore<TerminalAppearanceState>(Root, "terminal-appearance"), () => General.Read().CopyOnSelect);
  private void InitializeTerminalAppearanceTools()
  {
    Door.Register("terminal.appearance.read", (context, args, ct) =>
    {
      context.Require("settings", "workspace");
      return ValueTask.FromResult(args.TryGetProperty("export", out var id) ? JsonSerializer.SerializeToElement(new { json = TerminalAppearance.Export(id.GetString()!) }) : JsonSerializer.SerializeToElement(new { preferences = TerminalAppearance.Preferences(), palettes = TerminalAppearance.Palettes(), light = TerminalAppearance.Read(false), dark = TerminalAppearance.Read(true) }));
    });
    Door.Register("terminal.appearance.set", async (context, args, ct) =>
    {
      context.Require("settings", "workspace"); await context.EnsureCurrentAsync(ct);
      if (args.TryGetProperty("reset", out var reset) && reset.GetBoolean()) TerminalAppearance.Reset();
      else TerminalAppearance.Set(args.TryGetProperty("scheme", out var id) ? id.GetString() : null, args.TryGetProperty("fontFamily", out var family) ? family.GetString() : null, args.TryGetProperty("fontSize", out var size) ? size.GetInt32() : null);
      return JsonSerializer.SerializeToElement(TerminalAppearance.Preferences());
    });
    Door.Register("terminal.palette.change", async (context, args, ct) =>
    {
      context.Require("settings", "workspace"); await context.EnsureCurrentAsync(ct);
      switch (args.GetProperty("action").GetString())
      {
        case "copy": return JsonSerializer.SerializeToElement(TerminalAppearance.Copy(args.GetProperty("id").GetString()!));
        case "import": return JsonSerializer.SerializeToElement(TerminalAppearance.Import(args.GetProperty("json").GetString()!));
        case "edit": TerminalAppearance.Edit(args.GetProperty("id").GetString()!, args.GetProperty("name").GetString()!, JsonSerializer.Deserialize<Dictionary<string, string>>(args.GetProperty("colors"))!); break;
        case "remove": TerminalAppearance.Remove(args.GetProperty("id").GetString()!); break;
        default: throw new ArgumentException("Choose copy, import, edit or remove.");
      }
      return JsonSerializer.SerializeToElement(TerminalAppearance.Preferences());
    });
  }
}
