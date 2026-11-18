using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Settings;

public sealed record GeneralPreferences(bool AutoNameSessions = true, bool CopyOnSelect = false, bool KeepAwake = false, AiPermissionMode? DefaultPermission = null,
  LaunchModelChoice[]? LaunchModels = null, string DefaultProvider = "claude", bool RestoreSessions = true, bool DebugSettings = false, string? TerminalShell = null,
  string WhenOpens = "new-session", LaunchPermissionChoice[]? LaunchPermissions = null);
// The app-wide model and effort every new session starts with (Settings → Coding AIs).
public sealed record LaunchModelChoice(string Provider, string Model, string? Effort);
public sealed record LaunchPermissionChoice(string Provider, AiPermissionMode PermissionMode);

public static class LaunchPermissions
{
  public static AiPermissionMode For(string provider, GeneralPreferences? preferences)
  {
    // Shell/custom terminal callers had an Ask fallback before per-AI overrides.
    // A corrupt explicit override still refuses instead of broadening access.
    if (provider is not ("claude" or "codex" or "gemini") && preferences?.LaunchPermissions?.Any(row => row.Provider == provider) != true)
      return ChatPermissionModes.DefaultFor(provider, preferences?.DefaultPermission);
    RequireProvider(provider);
    var saved = preferences?.LaunchPermissions?.Where(row => row.Provider == provider).ToArray() ?? [];
    if (saved.Length > 1) throw new ArgumentException("Choose one default permission mode per coding AI.");
    if (saved.FirstOrDefault() is { } choice)
    {
      ChatPermissionModes.Validate(provider, choice.PermissionMode);
      return choice.PermissionMode;
    }
    // Keep the old global preference's provider fallback for existing settings files.
    return ChatPermissionModes.DefaultFor(provider, preferences?.DefaultPermission);
  }
  public static GeneralPreferences With(GeneralPreferences preferences, string provider, AiPermissionMode? mode)
  {
    RequireProvider(provider);
    if (mode is { } chosen) ChatPermissionModes.Validate(provider, chosen);
    var rows = (preferences.LaunchPermissions ?? []).Where(row => row.Provider != provider);
    return preferences with { LaunchPermissions = (mode is { } permission ? rows.Append(new LaunchPermissionChoice(provider, permission)) : rows).OrderBy(row => row.Provider).ToArray() };
  }
  internal static void Validate(GeneralPreferences preferences)
  {
    var rows = preferences.LaunchPermissions ?? [];
    if (rows.Select(row => row.Provider).Distinct().Count() != rows.Length) throw new ArgumentException("Choose one default permission mode per coding AI.");
    foreach (var row in rows) { RequireProvider(row.Provider); ChatPermissionModes.Validate(row.Provider, row.PermissionMode); }
  }
  public static AiPermissionMode? Parse(JsonElement value)
  {
    if (value.ValueKind == JsonValueKind.Null) return null;
    if (value.ValueKind != JsonValueKind.String || !Enum.TryParse<AiPermissionMode>(value.GetString(), true, out var chosen) || !Enum.IsDefined(chosen))
      throw new ArgumentException("Choose a supported permission mode.");
    return chosen;
  }
  private static void RequireProvider(string provider)
  { if (provider is not ("claude" or "codex" or "gemini")) throw new ArgumentException("Choose Claude Code, Codex or Gemini."); }
}

public sealed class GeneralSettings(IStateStore<GeneralPreferences> store)
{
  public GeneralPreferences Read() => store.Load() ?? new();
  public event Action? Changed;
  public void Save(GeneralPreferences value)
  {
    if (!Sessions.TerminalShells.IsKnown(value.TerminalShell)) throw new ArgumentException("Choose a supported terminal shell.");
    LaunchPermissions.Validate(value);
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
      // "When Terminal Deck opens": the New session page (default) or where he left off.
      if (field.Name == "whenOpens")
      {
        if (field.Value.ValueKind != JsonValueKind.String || field.Value.GetString() is not { } opens || !Sessions.OpensOn.OnWindows.Contains(opens)) throw new ArgumentException("Choose New session or Where I left off.");
        next = next with { WhenOpens = opens }; continue;
      }
      if (field.Name == "defaultPermission")
      {
        if (field.Value.ValueKind != JsonValueKind.String || !Enum.TryParse<AiPermissionMode>(field.Value.GetString(), true, out var chosen) || !Enum.IsDefined(chosen)) throw new ArgumentException("Choose a supported permission mode.");
        next = next with { DefaultPermission = chosen }; continue;
      }
      if (field.Name == "launchPermissions")
      {
        if (field.Value.ValueKind != JsonValueKind.Object) throw new ArgumentException("Choose a permission mode for each coding AI.");
        foreach (var row in field.Value.EnumerateObject()) next = LaunchPermissions.With(next, row.Name, LaunchPermissions.Parse(row.Value));
        continue;
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
  public AiPermissionMode NewChatPermission(string provider) => LaunchPermissions.For(provider, Read());
  public static AiPermissionMode NewChatPermission(AppDataRoot? root, string provider) =>
    root is null ? LaunchPermissions.For(provider, null) : new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings")).NewChatPermission(provider);
  public static bool ShouldAutoName(AppDataRoot? root, bool customTitle, int messages) => !customTitle && messages == 0 &&
    (root is null || new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings")).Read().AutoNameSessions);
}
