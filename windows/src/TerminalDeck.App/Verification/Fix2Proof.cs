using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.App.Views.Receiver;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Verification;

// This path is reached only through the existing explicit scratch-root gate.
// Fixtures stay in that root, and every launched session is retired in finally.
internal static class Fix2Proof
{
  public static async Task RunAsync(ShellWindow window, string directory)
  {
    var previous = Path.Combine(directory, "previous-result.json");
    var passed = File.Exists(previous) ? JsonDocument.Parse(File.ReadAllText(previous)).RootElement.GetProperty("passed").Deserialize<List<string>>() ?? [] : new List<string>();
    var failed = new List<string>(); var runtime = window.Runtime;
    string? shellId = null; string? chatId = null; string? phoneId = null;
    void Check(string name, Func<bool> check) { if (!passed.Contains(name)) (check() ? passed : failed).Add(name); }
    try
    {
      await window.Ready.WaitAsync(TimeSpan.FromSeconds(60));
      var folder = Path.Combine(Directory.GetParent(runtime.Root.DirectoryPath)!.FullName, "fix2-project"); Directory.CreateDirectory(folder);
      var privateFolder = Path.Combine(folder, "Private"); Directory.CreateDirectory(privateFolder);
      var project = runtime.Projects.List().FirstOrDefault(p => p.Name == "Review fixes") ?? runtime.Projects.Create("Review fixes", folder);
      var other = runtime.Projects.List().FirstOrDefault(p => p.Name == "Private nested project") ?? runtime.Projects.Create("Private nested project", privateFolder);
      runtime.Projects.Select(project.Id);
      var task = runtime.Tasks.List(new(Status: "all")).FirstOrDefault(t => t.Title == "Check the Windows review fixes") ?? runtime.Tasks.Create(new("Check the Windows review fixes", "Synthetic task for this isolated walk.", project.Id, folder), TaskActor.Owner);
      if (task.Comments.Length == 0) await runtime.Tasks.CommentAsync(task.Id, "This comment is task context and grants no fresh permission.", TaskActor.Owner);
      if (!runtime.Tasks.List(new(Status: "all")).Any(t => t.Title == "Private task must stay hidden"))
        runtime.Tasks.Create(new("Private task must stay hidden", ProjectId: other.Id, Folder: privateFolder), TaskActor.Owner);
      runtime.Agents.Save(new("fix2-reviewer", "Preview reviewer", "codex", "Reviews only this scratch project", ProjectId: project.Id));
      var account = runtime.Accounts.List("claude").First();
      Check("All coding AI accounts remain signed out", () => runtime.Accounts.List().All(a => !a.SignedIn));
      var shell = await runtime.StartShellForProjectAsync(folder, project.Id); shellId = shell.Definition.Id;
      var chat = await runtime.Chats.CreateAsync(new(Guid.NewGuid().ToString(), "claude", folder, "Preview chat", account.Id, account.HomeId, new()));
      chatId = chat.Definition.Id; runtime.Projects.BindSession(chatId, project.Id); await runtime.RefreshSessionsAsync();
      if (!passed.Contains("Changing Hoot owner mode retires old caller authority"))
      {
      await runtime.Hoot.ConfigureAsync(new("claude", account.Id, folder, new(), 0, 0, AiPermissionMode.Plan));
      await runtime.Hoot.SaveMemoryAsync("Only this isolated Windows preview is under review.", "Ask the person before changing server access.");
      await runtime.Hoot.SayAsync(Guid.NewGuid().ToString(), "Reply only if this isolated account is already signed in.");
      await Until(() => runtime.Hoot.Read().Problem is not null && !runtime.Hoot.Read().Busy);
      var oldHoot = runtime.Hoot.Read().ChatId!;
      var provisioned = runtime.CallerAuthority.List().Single(p => p.CallerId == "hoot:" + oldHoot);
      Check("Hoot tool connection has saved Plan mode and bounded server management", () => provisioned.Mode == AiPermissionMode.Plan && provisioned.ServerManagement && provisioned.Resources.Contains("settings:servers") && !provisioned.Resources.Contains("*"));
      await runtime.Chats.RefreshAsync();
      Check("Hoot provider definition carries Plan mode", () => runtime.Chats.Get(oldHoot).Definition.PermissionMode == AiPermissionMode.Plan);
      await runtime.Hoot.ConfigureAsync(runtime.Hoot.Read().Settings! with { PermissionMode = AiPermissionMode.Ask });
      await Until(() => !runtime.CallerAuthority.IsCurrent("hoot:" + oldHoot));
      Check("Changing Hoot owner mode retires old caller authority", () => !runtime.CallerAuthority.List().Any(p => p.CallerId == "hoot:" + oldHoot));

      }
      if (!passed.Contains("Workspace sharing preserves separate session and account grants"))
      {
      var offer = runtime.Remote.Trust.Pairing.Create();
      var receipt = runtime.Remote.Trust.Redeem(offer.Code, "Local synthetic phone", "proof", System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
      phoneId = receipt.DeviceId; runtime.Remote.Trust.Approve(phoneId, PhoneAccess.Look);
      var device = runtime.Remote.Trust.List().Single(d => d.Id == phoneId);
      runtime.Remote.Grants.Set(new(phoneId, false, [shellId], [folder], []));
      var beforeShell = runtime.Remote.Grants.Allows(device, shell);
      var beforeChat = runtime.Remote.Grants.Allows(device, ChatSessions.Session(chat));
      runtime.SetPhoneWorkspace(phoneId, [project.Id], true, PhoneAccess.Full);
      Check("Workspace sharing preserves separate session and account grants", () => beforeShell && !beforeChat && runtime.Remote.Grants.Allows(device, shell) && !runtime.Remote.Grants.Allows(device, ChatSessions.Session(chat)));
      Check("Nested project task does not inherit the selected parent project", () => runtime.TaskGrants.Allows(device, project.Id, folder) && !runtime.TaskGrants.Allows(device, other.Id, privateFolder));

      }
      var script = Path.Combine(folder, "generated.py"); await File.WriteAllTextAsync(script, "This preview is text, never a command.");
      runtime.RecordReceiverArtifact(chatId, folder, "generated.py", DateTimeOffset.UtcNow);
      Check("Script artifact chooses a text editor rather than Windows execution", () => ArtifactOpenPolicy.HandlerFor(script) == ArtifactOpenHandler.TextEditor && runtime.Artifacts.List(folder).Any(a => a.RelPath == "generated.py"));
      var source = runtime.Receiver.Sources().First(s => s.ProjectId == project.Id && s.Kind == IntakeKind.Drop);
      runtime.Receiver.SaveRule(new("fix2-rule", "Propose Hoot", source.Id, "review destination", new(RouteKind.Hoot)));
      var item = runtime.Receiver.Receive(new(source.Id, "Review proposed destination", "review destination: task context only " + chatId));
      Check("Receiver keeps the rule's saved proposal", () => item.Target == new ReceiverTarget(RouteKind.Hoot));
      var server = runtime.Servers.List(ServerCaller.Person).FirstOrDefault(s => s.Name == "Preview server · not connected") ?? await new ServerStore(runtime.Root, new WindowsCredentialStore(runtime.Root)).AddAsync(new("Preview server · not connected", "example.invalid", 22, "preview", ServerAuthentication.Key, project.Id), ReadOnlyMemory<byte>.Empty, CancellationToken.None);
      var readGrant = new McpGrant("fix2-read", chatId, null, true, AiPermissionMode.Plan,
        McpCatalogue.Load().Select(s => s.Id).ToArray(), [McpTier.Read], ["sessions:" + chatId, "projects:" + project.Id, "folders:" + folder, "tasks:*", "hoot:main", "accounts:" + account.Id, "servers:" + server.Id], DateTimeOffset.UtcNow.AddMinutes(20));
      var registration = runtime.Door.RegisterCaller(readGrant, (_, _, _, _, _) => ValueTask.FromResult(true));
      try
      {
        Check("Shared MCP door advertises all four v2 feature areas", () => new[] { "tasks.local", "servers.look", "receiver.events", "hoot.chat.read" }.All(id => runtime.Door.List(registration.Id).Any(t => t.Id == id)));
        if (!passed.Contains("Scoped task and Hoot MCP reads finish through the real app"))
        {
          await runtime.Door.CallAsync(registration.Id, "tasks.local", JsonSerializer.SerializeToElement(new { @do = "list" }));
          await runtime.Door.CallAsync(registration.Id, "hoot.chat.read", JsonSerializer.SerializeToElement(new { }));
          Check("Scoped task and Hoot MCP reads finish through the real app", () => true);
        }
      }
      finally { runtime.Door.Revoke(registration.Id); }
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        window.SetTheme(theme); var suffix = theme.ToString().ToLowerInvariant();
        foreach (var page in new[] { ShellPage.Hoot, ShellPage.Agents, ShellPage.Tasks, ShellPage.Artifacts, ShellPage.Servers, ShellPage.Receiver, ShellPage.Projects, ShellPage.Browser })
        {
          window.Model.Page = page;
          if (page == ShellPage.Browser) await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(40));
          await Snapshot(directory, "fix2-" + page.ToString().ToLowerInvariant() + "-" + suffix);
          Check(page + " renders in " + suffix, () => window.PageTitleForProof == page.ToString());
        }
        window.Model.Page = ShellPage.Receiver; await Task.Delay(200);
        var receiverPage = Tree(window.Frame).OfType<ReceiverPage>().Single(); receiverPage.Model.SelectedId = item.Id; receiverPage.ShowSection("Inbox");
        await Until(() => Tree(receiverPage).OfType<ComboBox>().Any(c => c.Header as string == "Send to"));
        var selected = Tree(receiverPage).OfType<ComboBox>().Single(c => c.Header as string == "Send to");
        Check("Receiver selects the named rule proposal in " + suffix, () => selected.SelectedIndex > 0 && selected.SelectedIndex == ReceiverReview.DestinationIndex(runtime.Receiver.Destinations(project.Id), item.Target) && Tree(receiverPage).OfType<TextBlock>().Any(t => t.Text.StartsWith("Rule proposes ", StringComparison.Ordinal)));
        await Snapshot(directory, "fix2-receiver-proposal-" + suffix);
        foreach (var section in new[] { "Sources", "Rules", "Intake" }) { receiverPage.ShowSection(section); await Snapshot(directory, "fix2-receiver-" + section.ToLowerInvariant() + "-" + suffix); }
        window.Model.Page = ShellPage.Tasks; window.TasksForProof.OpenTask(task.Id); await Snapshot(directory, "fix2-task-detail-" + suffix); window.TasksForProof.Model.Select(null);
        window.Model.Page = ShellPage.Servers; window.ServersForProof.OpenServer(server.Id);
        foreach (var section in new[] { "Files", "Apps", "Access", "Connection" }) { window.ServersForProof.Model.Tab(section); await Snapshot(directory, "fix2-server-" + section.ToLowerInvariant() + "-" + suffix); }
        window.ServersForProof.Model.Select(null);
        window.OpenProject(project.Id); await Snapshot(directory, "fix2-project-detail-" + suffix);
        window.OpenAgent("fix2-reviewer"); await Snapshot(directory, "fix2-agent-detail-" + suffix);
        window.OpenSession(chatId); await Until(() => window.Model.Selected?.Id == chatId); await Snapshot(directory, "fix2-chat-" + suffix);
        window.OpenSession(shellId); await Until(() => window.Model.Selected?.Id == shellId); await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(40));
        await Snapshot(directory, "fix2-terminal-" + suffix);
        window.Model.Split = SplitPresentation.Browser; await Snapshot(directory, "fix2-split-" + suffix); window.Model.Split = SplitPresentation.None;
        window.Model.Page = ShellPage.Settings;
        for (var section = 0; section < 4; section++) { window.Settings.SelectSection(section); await window.Settings.RenderAsync(); await Snapshot(directory, "fix2-settings-" + section + "-" + suffix); }
        window.Model.Page = ShellPage.Hoot; await Task.Delay(250);
        Invoke(Tree(window.Frame).OfType<Button>().Single(b => b.Content as string == "Hoot options"));
        await Task.Delay(150);
        var menu = VisualTreeHelper.GetOpenPopupsForXamlRoot(window.Frame.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<MenuFlyoutItem>().Single(m => m.Text == "Hoot settings");
        ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu).GetPattern(PatternInterface.Invoke)).Invoke();
        await Until(() => OpenDialog(window) is not null); var dialog = OpenDialog(window)!;
        Check("Hoot permission choice is visible in " + suffix, () => Tree(dialog).OfType<ComboBox>().Any(c => c.Header as string == "Permissions"));
        await Snapshot(directory, "fix2-hoot-settings-" + suffix); dialog.Hide(); await Task.Delay(200);
        Invoke(Tree(window.Frame).OfType<Button>().Single(b => b.Content as string == "Desk & memory"));
        await Until(() => OpenDialog(window) is not null); dialog = OpenDialog(window)!;
        await Snapshot(directory, "fix2-hoot-memory-" + suffix); dialog.Hide(); await Task.Delay(200);
        var picker = NewSessionPicker.ShowAsync(window.Frame.XamlRoot, runtime.Agents, runtime.Projects, runtime.Accounts, window, terminalStart: (_, _) => Task.CompletedTask);
        await Until(() => NewSessionPicker.ActiveDialogForProof is not null); await Snapshot(directory, "fix2-session-picker-" + suffix);
        NewSessionPicker.ActiveDialogForProof!.Hide(); await picker;
        var accounts = window.ShowAccountAsync(); await Until(() => OpenDialog(window) is not null); await Snapshot(directory, "fix2-accounts-" + suffix); window.DismissAccountSheet(); await accounts;
      }
      Check("No signed-in account was used during the walk", () => runtime.Accounts.List().All(a => !a.SignedIn));
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { failed.Add(ex.GetType().Name + ": " + ex.Message); await File.WriteAllTextAsync(Path.Combine(directory, "failure-stack.txt"), ex.ToString()); }
    finally
    {
      try
      {
        if (phoneId is not null) runtime.Remote.Trust.Revoke(phoneId);
        if (shellId is not null) await runtime.StopAsync(shellId);
        if (chatId is not null) await runtime.Chats.EndAsync(chatId);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add("Owned fixture cleanup: " + ex.GetType().Name); }
    }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { passed, failed, passCount = passed.Count, failCount = failed.Count, timestamp = DateTimeOffset.UtcNow, installed = false, signedIn = false }));
  }
  private static ContentDialog? OpenDialog(ShellWindow window) => VisualTreeHelper.GetOpenPopupsForXamlRoot(window.Frame.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().FirstOrDefault();
  private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
  private static IEnumerable<DependencyObject> Tree(DependencyObject node)
  { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child; }
  private static async Task Until(Func<bool> ready)
  { var until = DateTimeOffset.UtcNow.AddSeconds(60); while (!ready()) { if (DateTimeOffset.UtcNow > until) throw new TimeoutException("Review-fix walk timed out."); await Task.Delay(100); } }
  private static async Task Snapshot(string directory, string name)
  { if (File.Exists(Path.Combine(directory, name + ".ack"))) return; await Task.Delay(400); await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name })); await Until(() => File.Exists(Path.Combine(directory, name + ".ack"))); }
}
