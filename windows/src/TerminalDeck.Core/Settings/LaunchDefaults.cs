using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Settings;

// Every new session, chat, agent or hand without its own choice starts on the
// strongest model and level (Asad, 30 Oct: Claude Opus 5.5 · Extra high; the other
// AIs their top model and highest level). People still change it per session.
public static class LaunchDefaults
{
  public static (string Model, string? Effort) For(string provider, GeneralPreferences? preferences)
  {
    var saved = preferences?.LaunchModels?.FirstOrDefault(c => c.Provider == provider);
    var model = saved?.Model is { Length: > 0 } chosen ? chosen : ModelCatalog.Top(provider)?.Id ?? "";
    var effort = provider == "gemini" ? null : saved?.Effort is { Length: > 0 } level && level != "auto" ? level : ModelCatalog.TopEffort(provider);
    return (model, effort);
  }
  public static (string Model, string? Effort) For(string provider, AppDataRoot? root) =>
    For(provider, root is null ? null : new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings")).Read());
  public static GeneralPreferences With(GeneralPreferences preferences, string provider, string model, string? effort)
  {
    if (provider is not ("claude" or "codex" or "gemini")) throw new ArgumentException("Choose Claude Code, Codex or Gemini.");
    if (string.IsNullOrWhiteSpace(model) || model.Length > 128 || model.Any(char.IsControl) || model.Any(char.IsWhiteSpace)) throw new ArgumentException("Choose a model.");
    if (provider == "gemini") effort = null;
    else if (effort is not ("low" or "medium" or "high" or "xhigh" or "max")) throw new ArgumentException("Choose Low, Medium, High, Extra high or Max.");
    var rows = (preferences.LaunchModels ?? []).Where(c => c.Provider != provider).Append(new LaunchModelChoice(provider, model.Trim(), effort)).OrderBy(c => c.Provider).ToArray();
    return preferences with { LaunchModels = rows };
  }
  // Fills only what is empty: a person's own choice always wins.
  public static TerminalDeck.Core.Chats.ChatOptions Fill(string provider, TerminalDeck.Core.Chats.ChatOptions options, AppDataRoot? root)
  {
    if (provider is not ("claude" or "codex" or "gemini")) return options;
    var (model, effort) = For(provider, root);
    return options with
    {
      Model = options.Model.Length > 0 ? options.Model : model,
      Effort = options.Effort is { Length: > 0 } and not "auto" || effort is null ? options.Effort : effort
    };
  }
}
