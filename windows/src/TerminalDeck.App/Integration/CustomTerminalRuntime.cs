using System.Text.Json;
using TerminalDeck.Core.Sessions;
using TerminalDeck.App.Views.Agents;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private CustomTerminalProviders? customProviders;
  public CustomTerminalProviders CustomProviders => customProviders ??= TerminalDeck.Platform.Windows.WindowsCustomTerminalProviders.Open(Root);
  private void InitializeCustomTerminalProviders()
  {
    InitializeChatBranches();
    NewSessionPicker.TerminalProviders = CustomProviders;
    NewSessionPicker.CustomTerminalStart = async (provider, folder, project) =>
    {
      var row = await StartCustomTerminalAsync(provider, folder);
      Projects.BindSession(row.Definition.Id, project); await RefreshSessionsAsync();
    };
    Door.Register("terminal.providers", async (context, args, ct) =>
    {
      context.Require("settings", "coding-ais"); await context.EnsureCurrentAsync(ct);
      string Text(string key, string fallback = "") => args.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? fallback : fallback;
      bool Flag(string key, bool fallback) => args.TryGetProperty(key, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : fallback;
      switch (Text("action"))
      {
        case "list": return JsonSerializer.SerializeToElement(CustomProviders.List().Select(p => new { p.Id, p.Name, p.Executable, argumentCount = p.Arguments.Length, environmentNames = p.Environment.Keys, p.Enabled, p.InheritEnvironment, presentation = "terminal" }));
        case "save":
          var environment = args.TryGetProperty("environment", out var env) ? env.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString() ?? "", StringComparer.OrdinalIgnoreCase) : new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
          var arguments = args.TryGetProperty("arguments", out var a) ? a.EnumerateArray().Select(v => v.GetString() ?? "").ToArray() : [];
          CustomProviders.Save(new(Text("id"), Text("name"), Text("executable"), arguments, environment, Flag("enabled", true), Flag("inheritEnvironment", true))); break;
        case "remove": CustomProviders.Remove(Text("id")); break;
        case "start":
          var folder = Path.GetFullPath(Text("cwd")); context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
          var row = await StartCustomTerminalAsync(Text("id"), folder, Text("title"), ct); context.NoteSessionStarted(row.Definition.Id); return JsonSerializer.SerializeToElement(new { sessionId = row.Definition.Id, provider = row.Definition.Provider, status = row.State.ToString() });
        default: throw new ArgumentException("Choose list, save, remove or start.");
      }
      return JsonSerializer.SerializeToElement(new { saved = true });
    });
  }
  public async Task<SessionRecord> StartCustomTerminalAsync(string provider, string folder, string? title = null, CancellationToken ct = default)
  {
    var specification = CustomProviders.Require(provider);
    if (!Directory.Exists(folder)) throw new ArgumentException("Choose an existing folder for the custom CLI.");
    var row = (await Keeper.CreateAsync(new(Guid.NewGuid().ToString(), provider, folder, string.IsNullOrWhiteSpace(title) ? specification.Name : title), ct)).Session ?? throw new IOException("The custom terminal did not start.");
    await RefreshSessionsAsync(); return row;
  }
}
