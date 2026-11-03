namespace TerminalDeck.Core.Accounts;

public sealed record SignInReadinessCheck(string Id, string Description, string State);
public sealed record ProviderSignInReadiness(string Provider, string Name, int Accounts, int SignedIn, SignInReadinessCheck[] Checks);
public sealed record SignInReadinessReport(DateTimeOffset CheckedAt, ProviderSignInReadiness[] Providers, string Note);

public static class SignInReadiness
{
  // Saved status is descriptive only. No model reply or approval is claimed
  // until a person explicitly runs those checks after signing in.
  public static SignInReadinessReport Read(IEnumerable<AccountProfile> accounts)
  {
    var rows = accounts.ToArray();
    var providers = new[] { ("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini") }.Select(provider =>
    {
      var matching = rows.Where(a => a.Provider == provider.Item1).ToArray();
      var signedIn = matching.Count(a => a.SignedIn);
      var waiting = signedIn == 0 ? "Waiting for your sign-in" : "Waiting for verification";
      return new ProviderSignInReadiness(provider.Item1, provider.Item2, matching.Length, signedIn,
      [
        new("reply", "Send one message and receive one reply from this AI.", waiting),
        new("models", "Read this account’s live model list, including 1M choices where offered.", waiting),
        new("switch", "Switch to a second signed-in account for this AI and continue the same conversation.", matching.Count(a => a.SignedIn) < 2 ? "Waiting for two signed-in accounts" : "Waiting for verification"),
        new("approval", "Ask for an action, answer its approval request, and confirm the result reaches the AI.", waiting)
      ]);
    }).ToArray();
    return new(DateTimeOffset.UtcNow, providers, "This is a sign-in readiness checklist. No message, account switch or approval check runs when you open it.");
  }
}
