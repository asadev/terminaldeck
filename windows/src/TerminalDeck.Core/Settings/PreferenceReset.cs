namespace TerminalDeck.Core.Settings;

public sealed record PreferenceResetStep(string Id, Action Reset);
public sealed record PreferenceResetResult(string[] Completed, string[] Failed)
{
  public bool Complete => Failed.Length == 0;
}
public static class PreferenceReset
{
  // Explicit owner APIs only. No folder deletion, session reset, account logout,
  // hook reinstall or data-ledger rewrite can be inferred from this operation.
  public static PreferenceResetResult Run(bool confirmed, params PreferenceResetStep[] steps)
  {
    if (!confirmed) throw new InvalidOperationException("Confirm the settings reset first.");
    var done = new List<string>(); var failed = new List<string>();
    foreach (var step in steps)
      try { step.Reset(); done.Add(step.Id); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.ExternalException) { failed.Add(step.Id); }
    return new(done.ToArray(), failed.ToArray());
  }
}
