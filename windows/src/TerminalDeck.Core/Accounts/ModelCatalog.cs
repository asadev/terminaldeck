namespace TerminalDeck.Core.Accounts;

// The preloaded model list each AI shows the instant a picker opens (Asad, 30 Oct:
// "every dropdown shows real options instantly"). A live list from the signed-in
// CLI replaces it once it arrives; this list never pretends to be that check.
// Ids are the CLI's own selectable values, names are what people read.
public static class ModelCatalog
{
  private static readonly string[] ClaudeEfforts = ["low", "medium", "high", "xhigh", "max"];
  private static readonly string[] CodexEfforts = ["low", "medium", "high", "xhigh", "max"];
  private static readonly Dictionary<string, ProviderModel[]> Lists = new()
  {
    ["claude"] = [
      new("claude-opus-5-5", "Opus 5.5", 0, false, true, ClaudeEfforts),
      new("claude-fable-5-1[1m]", "Fable 5.1", 1_000_000, true, false, ClaudeEfforts),
      new("claude-sonnet-5-5", "Sonnet 5.5", 0, false, false, ClaudeEfforts),
      new("claude-haiku-5-5", "Haiku 5.5", 0, false, false, ClaudeEfforts)],
    ["codex"] = [
      new("gpt-6.1-sol", "GPT-6.1-Sol", 0, false, true, CodexEfforts),
      new("gpt-6-astra", "GPT-6-Astra", 0, false, false, CodexEfforts),
      new("gpt-6.1-terra", "GPT-6.1 Terra", 0, false, false, CodexEfforts),
      new("gpt-6-sol", "GPT-6-Sol", 0, false, false, CodexEfforts),
      new("gpt-6-luna", "GPT-6-Luna", 0, false, false, CodexEfforts),
      new("gpt-5.6-sol", "GPT-5.6-Sol", 0, false, false, CodexEfforts),
      new("gpt-5.6-terra", "GPT-5.6-Terra", 0, false, false, CodexEfforts),
      new("gpt-5.6-luna", "GPT-5.6-Luna", 0, false, false, CodexEfforts)],
    ["gemini"] = [
      new("gemini-3-pro-preview", "Gemini 3 Pro", 1_000_000, true, true),
      new("gemini-3-flash-preview", "Gemini 3 Flash", 1_000_000, true, false),
      new("gemini-2.5-pro", "Gemini 2.5 Pro", 1_000_000, true, false),
      new("gemini-2.5-flash", "Gemini 2.5 Flash", 1_000_000, true, false)],
  };
  public static IReadOnlyList<ProviderModel> For(string provider) => Lists.TryGetValue(provider, out var rows) ? rows : [];
  public static ProviderModel? Top(string provider) => For(provider).FirstOrDefault();
  // The strongest standard level. Codex "ultra" also hands work to sub-agents,
  // so it is offered but never picked for anyone.
  public static string? TopEffort(string provider) => provider switch { "claude" => "xhigh", "codex" => "max", _ => null };

  // A live list replaces the preloaded one; a saved choice the live list lacks is
  // kept visible (by its real name) instead of being silently swapped.
  public static IReadOnlyList<ProviderModel> Merge(string provider, IReadOnlyList<ProviderModel>? live, string? keep = null)
  {
    var rows = (live is { Count: > 0 } ? live : For(provider)).Where(m => !IsPlaceholder(m)).ToList();
    if (!string.IsNullOrWhiteSpace(keep) && rows.All(m => m.Id != keep))
    {
      var known = For(provider).FirstOrDefault(m => m.Id == keep);
      rows.Add(known ?? new ProviderModel(keep, ModelNames.Display(keep, For(provider)), 0));
    }
    return rows;
  }
  // "Default (recommended)" style rows name no model; people must see the model itself.
  public static bool IsPlaceholder(ProviderModel model) => model.Id is "default" or "auto" ||
    model.Name.StartsWith("Default", StringComparison.OrdinalIgnoreCase);

  public static string EffortName(string? effort) => effort switch
  {
    "low" => "Low", "medium" => "Medium", "high" => "High", "xhigh" => "Extra high", "max" => "Max", "ultra" => "Ultra",
    "minimal" => "Minimal", null or "" or "auto" => "", _ => effort
  };
  public static string Label(string provider, string? model, string? effort)
  {
    var name = string.IsNullOrWhiteSpace(model) ? "" : ModelNames.Display(model, For(provider));
    var level = EffortName(effort);
    return name.Length == 0 ? level : level.Length == 0 ? name : name + " · " + level;
  }
}
