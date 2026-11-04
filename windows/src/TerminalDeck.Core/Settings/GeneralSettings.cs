using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Settings;

public sealed record GeneralPreferences(bool AutoNameSessions = true, bool CopyOnSelect = false, bool KeepAwake = false, AiPermissionMode? DefaultPermission = null,
  LaunchModelChoice[]? LaunchModels = null, string DefaultProvider = "claude", bool RestoreSessions = true, bool DebugSettings = false, string? TerminalShell = null);
// The app-wide model and effort every new session starts with (Settings → Coding AIs).
public sealed record LaunchModelChoice(string Provider, string Model, string? Effort);

public sealed class GeneralSettings(IStateStore<GeneralPreferences> store)
{
  public GeneralPreferences Read() => store.Load() ?? new();
  public event Action? Changed;
  public void Save(GeneralPreferences value)
  {
    if (!Sessions.TerminalShells.IsKnown(value.TerminalShell)) throw new ArgumentException("Choose a supported terminal shell.");
    store.Save(value); Changed?.Invoke();
  }
  public GeneralPreferences Patch(JsonElement patch)
  {
    if (patch.ValueKind != JsonValueKind.Object) throw new ArgumentException("Choose named General settings.");
    var next = Read();
    foreach (var field in patch.EnumerateObject())
    {
      if (field.Name == "terminalShell")
      {
        if (field.Value.ValueKind != JsonValueKind.String || !Sessions.TerminalShells.IsKnown(field.Value.GetString())) throw new ArgumentException("Choose a supported terminal shell.");
        next = next with { TerminalShell = field.Value.GetString() }; continue;
      }
      if (field.Name == "defaultProvider")
      {
        if (field.Value.ValueKind != JsonValueKind.String || field.Value.GetString() is not ("claude" or "codex" or "gemini" or "shell")) throw new ArgumentException("Choose an offered default coding AI.");
        next = next with { DefaultProvider = field.Value.GetString()! }; continue;
      }
      if (field.Name == "defaultPermission")
      {
        if (field.Value.ValueKind != JsonValueKind.String || !Enum.TryParse<AiPermissionMode>(field.Value.GetString(), true, out var chosen) || !Enum.IsDefined(chosen)) throw new ArgumentException("Choose a supported permission mode.");
        next = next with { DefaultPermission = chosen }; continue;
      }
      if (field.Name == "launchModels")
      {
        if (field.Value.ValueKind != JsonValueKind.Object) throw new ArgumentException("Choose a model and effort for each coding AI.");
        foreach (var row in field.Value.EnumerateObject())
        {
          var model = row.Value.TryGetProperty("model", out var m) ? m.GetString() ?? "" : "";
          var effort = row.Value.TryGetProperty("effort", out var e) ? e.GetString() : null;
          next = LaunchDefaults.With(next, row.Name, model, effort);
        }
        continue;
      }
      if (field.Value.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new ArgumentException("General settings use on or off.");
      var enabled = field.Value.GetBoolean();
      next = field.Name switch {
        "autoNameSessions" => next with { AutoNameSessions = enabled },
        "copyOnSelect" => next with { CopyOnSelect = enabled },
        "keepAwake" => next with { KeepAwake = enabled },
        "restoreSessions" => next with { RestoreSessions = enabled },
        "debugSettings" => next with { DebugSettings = enabled },
        _ => throw new ArgumentException("Choose a supported General setting.")
      };
    }
    Save(next); return next;
  }
  public AiPermissionMode NewChatPermission(string provider) => ChatPermissionModes.DefaultFor(provider, Read().DefaultPermission);
  public static AiPermissionMode NewChatPermission(AppDataRoot? root, string provider) =>
    root is null ? ChatPermissionModes.DefaultFor(provider) : new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings")).NewChatPermission(provider);
  public static bool ShouldAutoName(AppDataRoot? root, bool customTitle, int messages) => !customTitle && messages == 0 &&
    (root is null || new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings")).Read().AutoNameSessions);
}
