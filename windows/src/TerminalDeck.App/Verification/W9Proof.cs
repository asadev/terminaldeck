using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Receiver;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Verification;

// One opt-in, isolated main-app walk. No installation, provider sign-in, or
// production connection is required to observe the integrated pages.
internal static class W9Proof
{
  public static async Task RunAsync(ShellWindow window, string directory)
  {
    var previous = Path.Combine(directory, "previous-result.json");
    var passed = File.Exists(previous) ? JsonDocument.Parse(File.ReadAllText(previous)).RootElement.GetProperty("passed").Deserialize<List<string>>() ?? [] : new List<string>();
    var failed = new List<string>(); var runtime = window.Runtime;
    void Check(string name, bool value) { if (!passed.Contains(name)) (value ? passed : failed).Add(name); }
    try
    {
      await window.Ready.WaitAsync(TimeSpan.FromSeconds(60));
      var folder = Path.Combine(Directory.GetParent(runtime.Root.DirectoryPath)!.FullName, "sample-project"); Directory.CreateDirectory(folder);
      var project = runtime.Projects.List().FirstOrDefault(p => p.Name == "W9 sample") ?? runtime.Projects.Create("W9 sample", folder); runtime.Projects.Select(project.Id);
      var task = runtime.Tasks.List(new(Status: "all")).FirstOrDefault(t => t.Title == "Review the Windows preview") ?? runtime.Tasks.Create(new("Review the Windows preview", "Synthetic integration task. No live work.", project.Id, folder), TaskActor.Owner);
      if (!passed.Contains("Task create and comment use the shared service"))
      {
        await runtime.Tasks.CommentAsync(task.Id, "This comment belongs to the local scratch task.", TaskActor.Owner);
        Check("Task create and comment use the shared service", runtime.Tasks.Get(task.Id).Comments.Length == 1);
      }
      if (!passed.Contains("Local Windows intake creates one acknowledged task and does not duplicate it"))
      {
      var source = runtime.Receiver.Sources().First(s => s.ProjectId == project.Id && s.Kind == IntakeKind.Drop);
      var package = new DataPackage(); package.SetText("A local data package for Receiver.");
      var intake = new WindowsReceiverData(runtime.Receiver, new ReceiverFiles(runtime.Root));
      var received = await intake.ReadAsync(package.GetView(), source.Id, "W9 local intake");
      var routed = await runtime.Receiver.RouteAsync(received.Id, new(RouteKind.NewTask));
      var count = runtime.Tasks.List(new(Status: "all")).Count;
      var refusedDuplicate = false;
      try { await runtime.Receiver.RouteAsync(received.Id, new(RouteKind.NewTask)); } catch (ArgumentException) { refusedDuplicate = true; }
      Check("Local Windows intake creates one acknowledged task and does not duplicate it", routed.Status == InboxStatus.Delivered && refusedDuplicate && runtime.Tasks.List(new(Status: "all")).Count == count);
      }
      var shell = runtime.Sessions.FirstOrDefault(s => s.Definition.Cwd == folder && s.Definition.Provider == "shell" && s.State == TerminalDeck.Core.Sessions.SessionState.Running)
        ?? await runtime.StartShellForProjectAsync(folder, project.Id);
      window.OpenSession(shell.Definition.Id);
      await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == shell.Definition.Id));
      await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(40));
      await window.SelectedPane.InputForProofAsync("Write-Output 'W9_POWERSHELL_OK'");
      await UntilAsync(async () => (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == shell.Definition.Id).Replay.Split("W9_POWERSHELL_OK", StringSplitOptions.None).Length >= 3);
      Check("Real PowerShell accepts input through the main app", true);
      var account = runtime.Accounts.List("claude").First();
      var chat = await runtime.Chats.CreateAsync(new(Guid.NewGuid().ToString(), "claude", folder, "W9 chat · sign-in needed", account.Id, account.HomeId, new()));
      runtime.Projects.BindSession(chat.Definition.Id, project.Id); await runtime.RefreshSessionsAsync();
      await runtime.Hoot.ConfigureAsync(new("claude", account.Id, folder, new(), RefreshMinutes: 0, RefreshAfterTurns: 0));
      await runtime.Hoot.SaveMemoryAsync("This is the W9 scratch desk. No real accounts are signed in.", "Ask before changing anything outside this preview.");
      Check("Hoot keeps memory through the Keeper connection", runtime.Hoot.Read().Memory.Card.Contains("W9 scratch", StringComparison.Ordinal));
      var artifact = Path.Combine(folder, "w9-output.txt"); await File.WriteAllTextAsync(artifact, "Synthetic produced-file callback from the W9 walk.");
      runtime.RecordReceiverArtifact(chat.Definition.Id, folder, "w9-output.txt", DateTimeOffset.UtcNow);
      Check("Artifacts receives a known-session file callback", runtime.Artifacts.List(folder).Any(f => f.RelPath == "w9-output.txt"));
      var servers = new ServerStore(runtime.Root, new WindowsCredentialStore(runtime.Root));
      var server = await servers.AddAsync(new("W9 fixture · not connected", "example.invalid", 22, "preview", ServerAuthentication.Key, project.Id), ReadOnlyMemory<byte>.Empty, CancellationToken.None);
      Check("Server fixture defaults to Look only", runtime.Servers.Get(server.Id, ServerCaller.Person).Access.LookOnly);
      var grant = new McpGrant("w9-read-proof", shell.Definition.Id, null, true, AiPermissionMode.Plan, McpCatalogue.Load().Select(s => s.Id).ToArray(), [McpTier.Read], ["projects:" + project.Id, "folders:" + folder, "tasks:*", "hoot:main", "accounts:" + account.Id, "servers:" + server.Id, "settings:tasks"], DateTimeOffset.UtcNow.AddMinutes(30));
      var registration = runtime.Door.RegisterCaller(grant, (_, _, _, _, _) => ValueTask.FromResult(true));
      var advertised = runtime.Door.List(registration.Id);
      Check("Shared tool door advertises each implemented lane", new[] { "tasks.local", "servers.look", "receiver.events", "hoot.chat.read" }.All(id => advertised.Any(s => s.Id == id)));
      foreach (var call in new (string, object)[] { ("tasks.local", new { @do = "list" }), ("hoot.chat.read", new { }), ("servers.look", new { }) })
      { await runtime.Door.CallAsync(registration.Id, call.Item1, JsonSerializer.SerializeToElement(call.Item2)); Check("Shared MCP read: " + call.Item1, true); }
      runtime.Door.Revoke(registration.Id);
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        window.SetTheme(theme);
        var suffix = theme.ToString().ToLowerInvariant();
        foreach (var page in new[] { ShellPage.Hoot, ShellPage.Agents, ShellPage.Tasks, ShellPage.Artifacts, ShellPage.Servers, ShellPage.Receiver, ShellPage.Projects, ShellPage.Browser })
        {
          window.Model.Page = page;
          if (page == ShellPage.Browser)
          {
            await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(40));
            await window.Browser.NavigateForProofAsync("https://example.com");
          }
          await SnapshotAsync(directory, "w9-" + page.ToString().ToLowerInvariant() + "-" + suffix);
          Check(page + " mounts in " + suffix, window.PageTitleForProof == page.ToString());
        }
        window.TasksForProof.OpenTask(task.Id); window.Model.Page = ShellPage.Tasks;
        await SnapshotAsync(directory, "w9-task-detail-" + suffix);
        window.TasksForProof.Model.Select(null);
        window.ServersForProof.OpenServer(server.Id); window.Model.Page = ShellPage.Servers;
        await SnapshotAsync(directory, "w9-server-detail-" + suffix); window.ServersForProof.Model.Select(null);
        window.OpenSession(chat.Definition.Id); await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == chat.Definition.Id));
        await SnapshotAsync(directory, "w9-chat-" + suffix);
        window.OpenSession(shell.Definition.Id); await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == shell.Definition.Id));
        window.Model.Split = SplitPresentation.Browser;
        await SnapshotAsync(directory, "w9-split-" + suffix); window.Model.Split = SplitPresentation.None;
        window.Model.Page = ShellPage.Settings;
        for (var section = 0; section < 4; section++)
        { window.Settings.SelectSection(section); await window.Settings.RenderAsync(); await SnapshotAsync(directory, "w9-settings-" + section + "-" + suffix); }
      }
      if (Environment.GetEnvironmentVariable("TD_W9_PHONE") == "1")
      {
        window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(2); await window.Settings.ShowCodeAsync();
        // This private file is never copied into evidence or printed.
        await File.WriteAllTextAsync(Path.Combine(directory, "pair-code.txt"), window.Settings.ActiveCode);
        await File.WriteAllTextAsync(Path.Combine(directory, "phone-ready"), "ready");
        await UntilAsync(() => Task.FromResult(runtime.Remote.Trust.Pending().Count > 0), TimeSpan.FromMinutes(5));
        var device = runtime.Remote.Trust.Pending().Single(); runtime.Remote.Approve(device.Id);
        runtime.SetPhoneWorkspace(device.Id, [project.Id], true, TerminalDeck.Core.Remote.PhoneAccess.Full);
        await File.WriteAllTextAsync(Path.Combine(directory, "phone-approved"), "ready");
        await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, "phone-done"))), TimeSpan.FromMinutes(8));
        runtime.Remote.Trust.Revoke(device.Id); Check("Android paired and owner granted its task project and Hoot", true);
      }
      await runtime.StopAsync(shell.Definition.Id); await runtime.Chats.EndAsync(chat.Definition.Id);
      Check("Owned preview sessions stopped", (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == shell.Definition.Id).State == TerminalDeck.Core.Sessions.SessionState.Exited);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { failed.Add(ex.GetType().Name + ": " + ex.Message); await File.WriteAllTextAsync(Path.Combine(directory, "failure-stack.txt"), ex.ToString()); }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { passed, failed, passCount = passed.Count, failCount = failed.Count, timestamp = DateTimeOffset.UtcNow }));
  }
  private static async Task UntilAsync(Func<Task<bool>> predicate, TimeSpan? timeout = null)
  { var until = DateTimeOffset.UtcNow + (timeout ?? TimeSpan.FromSeconds(50)); while (DateTimeOffset.UtcNow < until) { if (await predicate()) return; await Task.Delay(150); } throw new TimeoutException("The W9 walkthrough check timed out."); }
  private static async Task SnapshotAsync(string directory, string name)
  { await Task.Delay(500); await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name })); await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, name + ".ack")))); }
}
