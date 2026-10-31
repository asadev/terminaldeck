namespace TerminalDeck.Core.Accounts;

public sealed class SignInCancelledException() : InvalidOperationException("Sign-in cancelled. Your conversation and draft are kept.");

public enum AccountSignInState { Starting, Waiting, Succeeded, Failed, Cancelled }

// The CLI's own status is the authority. An exit code or a line resembling
// "success" alone must never mark an account as signed in.
public sealed class AccountSignInFlow
{
  private readonly SemaphoreSlim gate = new(1);
  private readonly TaskCompletionSource<bool> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public AccountSignInState State { get; private set; } = AccountSignInState.Starting;
  public string Message { get; private set; } = "Opening this AI’s sign-in…";
  public Task<bool> Completion => completion.Task;
  public event Action? Changed;
  public void Started() { if (State == AccountSignInState.Starting) Set(AccountSignInState.Waiting, "Follow the steps in this terminal and your browser. This sheet closes when the AI confirms your login."); }
  public async Task CheckAsync(Func<CancellationToken, Task<bool>> verify, bool exited, CancellationToken ct = default, int? exitCode = null)
  {
    await gate.WaitAsync(ct);
    try
    {
      if (completion.Task.IsCompleted) return;
      if (exited && exitCode is not null and not 0) { Fail("Sign-in did not finish. Try again and approve it in your browser."); return; }
      try
      {
        var signedIn = await verify(ct);
        if (completion.Task.IsCompleted) return;
        if (signedIn) { Set(AccountSignInState.Succeeded, "Signed in"); completion.TrySetResult(true); }
        else if (exited) Fail("Sign-in did not finish. Try again and approve it in your browser.");
      }
      catch (OperationCanceledException) when (ct.IsCancellationRequested) { Cancel(); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException)
      { if (exited) Fail("The AI could not confirm your login. Try signing in again."); }
    }
    finally { gate.Release(); }
  }
  public void Fail(string message) { if (!completion.Task.IsCompleted) { Set(AccountSignInState.Failed, message); completion.TrySetResult(false); } }
  public void Cancel() { if (!completion.Task.IsCompleted) { Set(AccountSignInState.Cancelled, "Sign-in cancelled. Your conversation and draft are kept."); completion.TrySetResult(false); } }
  private void Set(AccountSignInState state, string message) { State = state; Message = message; Changed?.Invoke(); }
}
