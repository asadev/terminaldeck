using System.Diagnostics;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskWorkspaceTests
{
  [Fact] public async Task OwnWorkspaceIsASeparateReusableBranchAndDoesNotChangeTheSource()
  {
    var root = Path.Combine(Path.GetTempPath(), "deck-workspace-test-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
    async Task Git(params string[] args)
    {
      var start = new ProcessStartInfo("git") { WorkingDirectory = root, RedirectStandardOutput = true, RedirectStandardError = true };
      foreach (var arg in args) start.ArgumentList.Add(arg);
      using var process = Process.Start(start)!; var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
      await process.WaitForExitAsync(); await output; Assert.True(process.ExitCode == 0, await error);
    }
    try
    {
      await Git("init"); await Git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Fixture");
      var fixture = new TaskFixture(); var task = fixture.Create() with { Folder = root };
      await TaskWorkspace.PrepareAsync(task, CancellationToken.None); await TaskWorkspace.PrepareAsync(task, CancellationToken.None);
      var copy = TaskWorkspace.Folder(task); Assert.True(File.Exists(Path.Combine(copy, ".git")));
      File.WriteAllText(Path.Combine(copy, "only-in-workspace.txt"), "Task output");
      Assert.False(File.Exists(Path.Combine(root, "only-in-workspace.txt")));
    }
    finally
    {
      // Git writes its object files read-only; Windows refuses to delete those until the flag is cleared.
      foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
      Directory.Delete(root, recursive: true);
    }
  }
}
