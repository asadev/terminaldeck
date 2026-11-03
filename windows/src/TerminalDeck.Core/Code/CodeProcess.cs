using System.Diagnostics;
using System.Text;

namespace TerminalDeck.Core.Code;

public sealed record CodeProcessResult(int ExitCode, string Output, string Error, bool Missing = false, bool TimedOut = false)
{
  public bool Ok => ExitCode == 0 && !Missing && !TimedOut;
}

// Files, Source control and GitHub run the person's own git/gh. This app never
// stores a credential: Git for Windows' credential helper and gh keep theirs.
public interface ICodeProcessRunner
{
  Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken ct, string? input = null);
}

public sealed class CodeProcessRunner(IReadOnlyDictionary<string, string?>? environment = null) : ICodeProcessRunner
{
  public async Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken ct, string? input = null)
  {
    var start = new ProcessStartInfo(executable)
    {
      RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input is not null, UseShellExecute = false, CreateNoWindow = true,
      WorkingDirectory = workingDirectory, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
    };
    foreach (var argument in arguments) start.ArgumentList.Add(argument);
    // Never wait on a hidden terminal prompt; a credential helper window may still appear.
    start.Environment["GIT_TERMINAL_PROMPT"] = "0";
    start.Environment["GH_PROMPT_DISABLED"] = "1";
    start.Environment["GH_NO_UPDATE_NOTIFIER"] = "1";
    start.Environment["LC_ALL"] = "C";
    // A null value removes an inherited variable (for example a real GH_TOKEN in a test copy).
    foreach (var (name, value) in environment ?? new Dictionary<string, string?>()) { if (value is null) start.Environment.Remove(name); else start.Environment[name] = value; }
    Process process;
    try { process = Process.Start(start) ?? throw new System.ComponentModel.Win32Exception(); }
    catch (System.ComponentModel.Win32Exception) { return new(-1, "", "", Missing: true); }
    using (process)
    {
      if (input is not null) { await process.StandardInput.WriteAsync(input); process.StandardInput.Close(); }
      var output = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
      var error = process.StandardError.ReadToEndAsync(CancellationToken.None);
      using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct); limit.CancelAfter(timeout);
      try { await process.WaitForExitAsync(limit.Token); }
      catch (OperationCanceledException)
      {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        ct.ThrowIfCancellationRequested();
        return new(-1, await output, await error, TimedOut: true);
      }
      return new(process.ExitCode, await output, await error);
    }
  }
}
