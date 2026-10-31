using System.Diagnostics;
using System.Text;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Usage;

namespace TerminalDeck.Platform.Windows.Usage;

/// Asks one Claude login for its plan limits with Claude Code's own get_usage control request
/// (Mac `BackendUsageProbe`): a hidden `claude -p` in stream-json mode under that login's own
/// folder, at most 15 seconds, its whole process tree ended afterwards. No session is touched,
/// no message is sent and nothing is typed into any terminal.
public sealed class WindowsClaudeUsageProbe(AppDataRoot root, string toolsDirectory, Func<string, AccountProfile?> profile) : IUsageProbe
{
  public async ValueTask<UsageProbeOutcome> RunAsync(UsageAccount account, CancellationToken cancellationToken)
  {
    var started = UsageFormat.Now();
    UsageProbeOutcome Done(string kind, string detail, bool spawned = false) => new(kind, detail, [], spawned, UsageFormat.Now() - started);
    if (account.Provider != "claude" || account.Id is not { } id || profile(id) is not { } login || login.Provider != "claude")
      return Done("unreadable", "The session's Claude login has not been established, so another account will not be probed.");
    if (login.Authentication == AccountAuthentication.ApiKey) return Done("no-limits", UsageService.ApiUsageNote);
    ProcessLaunch launch;
    try
    {
      var planner = new WindowsProviderLaunchPlanner(root, toolsDirectory);
      var home = planner.AccountHome("claude", login.HomeId);
      var plan = planner.Plan(new(new(Guid.NewGuid().ToString(), "claude", home, "Account usage", login.Id, login.HomeId), "usage", SessionState.Starting), false);
      launch = planner.Resolve("claude", ClaudeUsageConversation.Arguments, plan.Environment, home);
    }
    catch (Exception ex) when (ex is IOException or ArgumentException or InvalidOperationException or UnauthorizedAccessException)
    { return Done("no-binary", "Claude Code is not runnable on this computer, so its usage cannot be read."); }

    var start = new ProcessStartInfo(launch.Executable)
    {
      WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
      RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8
    };
    foreach (var argument in launch.Arguments) start.ArgumentList.Add(argument);
    start.Environment.Clear(); foreach (var (name, value) in launch.Environment) start.Environment[name] = value;
    Process? process;
    try { process = Process.Start(start); }
    catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException or InvalidOperationException) { return Done("no-binary", "Claude Code could not be started here, so its usage could not be read."); }
    if (process is null) return Done("no-binary", "Claude Code could not be started here, so its usage could not be read.");
    using var owned = process;
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    deadline.CancelAfter(TimeSpan.FromSeconds(ClaudeUsageConversation.TimeoutSeconds));
    var talk = new ClaudeUsageConversation();
    try
    {
      // Error output is drained and dropped, never kept.
      _ = process.StandardError.BaseStream.CopyToAsync(Stream.Null, deadline.Token);
      await process.StandardInput.WriteLineAsync(ClaudeUsageConversation.Initialize().AsMemory(), deadline.Token);
      await process.StandardInput.FlushAsync(deadline.Token);
      long seen = 0;
      while (!talk.Finished && await process.StandardOutput.ReadLineAsync(deadline.Token) is { } line)
      {
        seen += line.Length;
        if (seen > 4 * 1024 * 1024) { talk.Finish(null, "The usage control response exceeded its read budget."); break; }
        if (talk.Feed(line) is { } next) { await process.StandardInput.WriteLineAsync(next.AsMemory(), deadline.Token); await process.StandardInput.FlushAsync(deadline.Token); }
      }
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { talk.Finish(null, null); }
    catch (OperationCanceledException) { return Done("unreadable", "The usage request was cancelled.", true); }
    catch (IOException) { talk.Finish(null, "The usage control request could not be delivered."); }
    finally
    {
      try { process.StandardInput.Close(); } catch (IOException) { }
      try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
    }
    return ClaudeUsageConversation.Interpret(account, talk.Usage, talk.Error ?? (talk.Usage is null && !talk.Finished ? "Claude Code did not answer within 15 seconds." : null), started, UsageFormat.Now());
  }
}
