using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Tasks;

public static class TaskWorkspace
{
  public static string Folder(DeckTask task) => Path.Combine(task.Folder, ".terminaldeck-workspaces", Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(task.Id)))[..16]);
  public static async ValueTask PrepareAsync(DeckTask task, CancellationToken ct)
  {
    var folder = Folder(task);
    async Task<string> Git(params string[] args)
    {
      var start = new ProcessStartInfo("git") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
      start.ArgumentList.Add("-C"); start.ArgumentList.Add(task.Folder);
      foreach (var arg in args) start.ArgumentList.Add(arg);
      using var process = Process.Start(start) ?? throw new InvalidOperationException("Git could not start.");
      var output = process.StandardOutput.ReadToEndAsync(ct); var error = process.StandardError.ReadToEndAsync(ct);
      try { await process.WaitForExitAsync(ct); }
      catch { if (!process.HasExited) process.Kill(entireProcessTree: true); throw; }
      _ = await error;
      if (process.ExitCode != 0) throw new InvalidOperationException("The task workspace could not open. Check that the project is a Git repository with a commit.");
      return (await output).Trim();
    }
    if (Directory.Exists(folder))
    {
      var prefix = await Git("-C", folder, "rev-parse", "--show-prefix");
      var source = await Git("rev-parse", "--path-format=absolute", "--git-common-dir");
      var target = await Git("-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir");
      if (prefix.Length != 0 || !Projects.ProjectPaths.Equal(source, target)) throw new InvalidOperationException("The task workspace path is occupied by another folder.");
      return;
    }
    await Git("rev-parse", "--verify", "HEAD");
    Directory.CreateDirectory(Path.GetDirectoryName(folder)!);
    await Git("worktree", "add", "-b", "deck-task/" + Path.GetFileName(folder), folder, "HEAD");
  }
}
