using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Code;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly SemaphoreSlim phoneGithubGate = new(1, 1);
  private CancellationTokenSource? phoneGithubStop;
  private Task? phoneGithubTask;
  private JsonObject? phoneGithubPending;
  private string? phoneGithubFailure;
  private JsonObject? PhoneGithubPending() => Volatile.Read(ref phoneGithubPending)?.DeepClone() as JsonObject;
  private Dictionary<string, string?> PhoneGithubEnvironment() => GitHubClient.IsRealCopy(Root.DirectoryPath, AppContext.BaseDirectory, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))
    ? [] : new() { ["GH_CONFIG_DIR"] = Path.Combine(Root.DirectoryPath, "github"), ["GH_TOKEN"] = null, ["GITHUB_TOKEN"] = null };
  private async ValueTask PhoneGithubChangeAsync(string type, CancellationToken ct)
  {
    if (type == "github.read") return;
    await phoneGithubGate.WaitAsync(ct);
    try
    {
      if (type is "github.cancel" or "github.disconnect")
      {
        phoneGithubStop?.Cancel();
        if (phoneGithubTask is not null) await phoneGithubTask.WaitAsync(ct);
        Volatile.Write(ref phoneGithubPending, null);
        if (type == "github.disconnect")
        {
          var current = await CopyGitHub.AuthAsync(ct);
          if (current.Source == "environment") throw new InvalidOperationException("GitHub is supplied by this computer's environment. Remove it there to disconnect.");
          var result = await new CodeProcessRunner(PhoneGithubEnvironment()).RunAsync("gh", ["auth", "logout", "--hostname", "github.com"], Root.DirectoryPath, TimeSpan.FromSeconds(20), ct, "Y\n");
          if (!result.Ok) throw new IOException("GitHub could not sign out. Check its sign-in on this computer.");
        }
        return;
      }
      if (phoneGithubTask is { IsCompleted: false }) return;
      phoneGithubStop?.Dispose(); phoneGithubStop = new(); phoneGithubStop.CancelAfter(TimeSpan.FromMinutes(15));
      var codeReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      phoneGithubFailure = null;
      phoneGithubTask = RunPhoneGithubAsync(phoneGithubStop.Token, codeReady);
      // A bounded wait returns the device code without waiting for the person
      // to complete GitHub's page. Cancel affects only this owned process.
      await Task.WhenAny(codeReady.Task, phoneGithubTask, Task.Delay(2000, ct)); ct.ThrowIfCancellationRequested();
    }
    finally { phoneGithubGate.Release(); }
  }
  private async Task RunPhoneGithubAsync(CancellationToken ct, TaskCompletionSource ready)
  {
    var start = new ProcessStartInfo("gh") { RedirectStandardError = true, RedirectStandardOutput = true, RedirectStandardInput = true,
      UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Root.DirectoryPath };
    foreach (var arg in new[] { "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web", "--skip-ssh-key" }) start.ArgumentList.Add(arg);
    foreach (var (key, value) in PhoneGithubEnvironment()) { if (value is null) start.Environment.Remove(key); else start.Environment[key] = value; }
    start.Environment["GH_PROMPT_DISABLED"] = "1"; start.Environment["GH_NO_UPDATE_NOTIFIER"] = "1";
    try
    {
      using var process = Process.Start(start) ?? throw new IOException("GitHub CLI could not start.");
      using var cancellation = ct.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { } });
      async Task Read(StreamReader reader)
      {
        var chars = new char[1024]; var tail = "";
        while (await reader.ReadAsync(chars.AsMemory(), ct) is var read && read > 0)
        {
          tail += new string(chars, 0, read); if (tail.Length > 8192) tail = tail[^8192..];
          var code = Regex.Match(tail, @"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b");
          if (!code.Success) continue;
          Volatile.Write(ref phoneGithubPending, new JsonObject { ["userCode"] = code.Value, ["verificationUri"] = "https://github.com/login/device", ["expiresAt"] = DateTimeOffset.UtcNow.AddMinutes(15).ToUnixTimeMilliseconds() });
          ready.TrySetResult();
          // gh's web flow asks for Return after printing the code.
          try { await process.StandardInput.WriteLineAsync(); await process.StandardInput.FlushAsync(); } catch (IOException) { }
        }
      }
      await Task.WhenAll(Read(process.StandardError), Read(process.StandardOutput), process.WaitForExitAsync(ct));
      if (process.ExitCode != 0) phoneGithubFailure = "GitHub sign-in did not finish. Try again.";
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { phoneGithubFailure = "GitHub sign-in cancelled."; }
    catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception or InvalidOperationException) { phoneGithubFailure = "GitHub CLI sign-in is unavailable. Install or repair GitHub CLI on this computer."; }
    finally { Volatile.Write(ref phoneGithubPending, null); ready.TrySetResult(); Changed?.Invoke(); }
  }
}
