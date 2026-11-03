namespace TerminalDeck.Core.Accounts;

public static class ModelEfforts
{
  // Prefer each model's protocol capabilities. Older CLIs omit those fields;
  // these are the levels the installed CLIs accept (claude --effort: low, medium,
  // high, xhigh, max; Codex model_reasoning_effort the same set).
  public static IReadOnlyList<string> For(string provider, ProviderModel? model) => provider == "gemini" ? [] :
    model?.Efforts is { Length: > 0 } offered ? offered : ["low", "medium", "high", "xhigh", "max"];
}
