namespace TerminalDeck.Core.Accounts;

public sealed record RunningAiSession(string Id, string Title, string Kind, string Provider, string AccountId, string? Folder, string? ProjectId, bool SetIndividually);
public enum BulkSwitchAction { Switch, Already, KeptIndividual, NoAssignment }
public sealed record BulkSwitchRow(RunningAiSession Session, string? To, BulkSwitchAction Action);

// Who uses what → Switch everything now (Mac: bulk Switch sheet). Saving a default
// only affects future sessions; this moves running ones, and only after the person
// sees each one. Sessions given their own account keep it unless asked otherwise.
public static class BulkSwitch
{
  public static IReadOnlyList<BulkSwitchRow> Plan(IEnumerable<RunningAiSession> running, string provider, Func<RunningAiSession, string?> assigned, bool includeIndividual)
    => running.Where(s => s.Provider == provider).Select(s =>
    {
      var to = assigned(s);
      var action = to is null ? BulkSwitchAction.NoAssignment : to == s.AccountId ? BulkSwitchAction.Already
        : s.SetIndividually && !includeIndividual ? BulkSwitchAction.KeptIndividual : BulkSwitchAction.Switch;
      return new BulkSwitchRow(s, to, action);
    }).ToArray();
  public static string Summary(IReadOnlyList<BulkSwitchRow> rows) =>
    rows.Count == 0 ? "Nothing running for this AI." :
    rows.All(r => r.Action == BulkSwitchAction.Already) ? "All already use their assigned account." :
    rows.Count(r => r.Action == BulkSwitchAction.Switch) is var n and > 0 ? n + (n == 1 ? " session will switch." : " sessions will switch.") : "Nothing to switch.";
}

public static class AccountAssignment
{
  // Who uses what, most specific first: the project's own choice for this use,
  // then its folder default, then the whole-app default for the AI.
  public static string? Effective(AccountService accounts, TerminalDeck.Core.Projects.Project? project, string use, string provider)
  {
    var choice = project?.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Use == use && c.Provider == provider);
    if (choice?.AccountId is { Length: > 0 } chosen) return chosen;
    try { return accounts.Default(provider, project?.HomeFolder)?.Id; }
    catch (ArgumentException) { return null; }
  }
}
