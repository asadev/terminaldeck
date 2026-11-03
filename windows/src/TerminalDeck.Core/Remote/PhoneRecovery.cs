namespace TerminalDeck.Core.Remote;

// Connection retry is distinct from repeating an AI turn. A new welcome owns
// a new identity; cached snapshots and confirmations belong to the old one.
public static class PhoneRecovery
{
  public static object Describe(string? connectionId, bool connected) => new
  {
    version = 1, state = connected ? "connected" : "reconnecting", connectionId,
    retryConnection = true, replayPending = false, clearLiveOnDisconnect = true,
    retry = false, switchAccount = false, options = false, host = "computer",
    signInHint = "Sign in on this computer, then send your message again."
  };
}
