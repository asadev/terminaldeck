using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Views;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.App.Verification;

// Opt-in walkthrough of this exact app with explicit scratch roots. It never
// signs in, installs a package or opens the person's existing data.
internal static class W7Proof
{
  public static async Task RunAsync(ShellWindow window, string directory, string phase)
  {
    if (phase == "fix2") { await Fix2Proof.RunAsync(window, directory); return; }
    if (phase == "w9-theme") { await W9ThemeProof.RunAsync(window, directory); return; }
    if (phase == "w9-hoot") { await W9PhoneProof.RunAsync(window, directory, hootOnly: true); return; }
    if (phase == "w9-phone") { await W9PhoneProof.RunAsync(window, directory); return; }
    if (phase == "w9") { await W9Proof.RunAsync(window, directory); return; }
    if (phase.StartsWith("review-", StringComparison.Ordinal)) { await ReviewFixProof.RunAsync(window, directory, phase); return; }
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool value) { (value ? passed : failed).Add(name); }
    try
    {
      await window.Ready.WaitAsync(TimeSpan.FromSeconds(50));
      var runtime = window.Runtime;
      var folder = Path.Combine(Directory.GetParent(runtime.Root.DirectoryPath)!.FullName, "sample-project"); Directory.CreateDirectory(folder);
      if (phase == "create")
      {
        window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(2); await window.Settings.ShowCodeAsync();
        Check("Pairing shows an active code without signing in", window.Settings.ActiveCode?.Length == 6 && runtime.Remote.Trust.Pairing.IsOpen);
        await SnapshotAsync(directory, "01-pairing-code"); runtime.Remote.Trust.Pairing.Cancel();
        var row = await runtime.StartAsync("shell", folder, title: "W7 PowerShell"); window.OpenSession(row.Definition.Id);
        await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == row.Definition.Id));
        await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(40));
        await window.SelectedPane.InputForProofAsync("Write-Output 'W7_FINAL_MARKER'");
        await UntilAsync(async () => (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == row.Definition.Id).Replay.Split("W7_FINAL_MARKER", StringSplitOptions.None).Length >= 3);
        Check("PowerShell receives a typed marker through the real terminal bridge", true);
        await SnapshotAsync(directory, "02-powershell-marker");
        var account = runtime.Accounts.List("claude").Single();
        var run = await runtime.Agents.StartAsync(new(null, Folder: folder, Provider: "claude", AccountId: account.Id, Mode: "chat"));
        window.OpenSession(run.SessionId); await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == run.SessionId));
        var page = window.SelectedChat; page.Model.Draft = "Hello from the signed-out walkthrough."; await page.Model.SendAsync();
        await UntilAsync(() => Task.FromResult(page.Model.Snapshot.Problem == ChatErrors.NotSignedIn("claude")));
        Check("Signed-out Claude chat shows the plain Sign in row", Descendants(window.Frame).OfType<TextBlock>().Any(t => t.Text == ChatErrors.NotSignedIn("claude")) && Descendants(window.Frame).OfType<Button>().Any(b => b.Content as string == "Sign in"));
        Check("Sessions sidebar includes both terminal and chat", window.Model.Sessions.Any(s => s.Presentation == TerminalDeck.App.ViewModels.SessionPresentation.Terminal) && window.Model.Sessions.Any(s => s.Presentation == TerminalDeck.App.ViewModels.SessionPresentation.Chat));
        await SnapshotAsync(directory, "03-signed-out-chat-and-sessions");
      }
      if (phase == "restart")
      {
        var terminal = runtime.Sessions.Single(s => s.Definition.Title == "W7 PowerShell");
        window.OpenSession(terminal.Definition.Id); await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == terminal.Definition.Id));
        await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(40));
        Check("App restart restores terminal marker and chat history", terminal.Replay.Contains("W7_FINAL_MARKER", StringComparison.Ordinal) && runtime.Chats.List().Any(c => c.Problem == ChatErrors.NotSignedIn("claude")));
        await SnapshotAsync(directory, "04-app-restart");
        await File.WriteAllTextAsync(Path.Combine(directory, "kill-keeper.request"), "ready");
        await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, "kill-keeper.ack"))));
        await runtime.ReconnectAsync(); await runtime.RefreshSessionsAsync();
        await window.SelectedPane.InputForProofAsync("Write-Output 'W7_AFTER_KEEPER_RESTART'");
        await UntilAsync(async () => (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == terminal.Definition.Id).Replay.Split("W7_AFTER_KEEPER_RESTART", StringSplitOptions.None).Length >= 3);
        Check("Keeper restart preserves marker and accepts fresh input", runtime.Sessions.Single(s => s.Definition.Id == terminal.Definition.Id).Replay.Contains("W7_FINAL_MARKER", StringComparison.Ordinal));
        await SnapshotAsync(directory, "05-keeper-restart");
      }
      if (phase is "walk" or "pages")
      {
        window.SetTheme(ElementTheme.Light);
        if (phase == "walk")
        {
        window.Model.Page = ShellPage.Browser; await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(50));
        await window.Browser.NavigateForProofAsync("https://example.com");
        await window.Browser.EvaluateForProofAsync("document.body.innerHTML='<h1>Windows final browser walk</h1><p>This controlled page proves tab retention.</p>';window.w7Document='retained'");
        var selectedTab = window.Browser.Core.Read().SelectedTabId;
        window.Model.Page = ShellPage.Sessions; window.Model.Page = ShellPage.Browser;
        Check("Browser tab survives switching without reload", window.Browser.Core.Read().SelectedTabId == selectedTab && (await window.Browser.EvaluateForProofAsync("window.w7Document")).GetProperty("result").GetProperty("value").GetString() == "retained");
        await window.Browser.ExecuteAsync("size", "390x844");
        Check("Browser Size reaches the live viewport", (await window.Browser.EvaluateForProofAsync("innerWidth")).GetProperty("result").GetProperty("value").GetInt32() == 390);
        await SnapshotAsync(directory, "06-browser-size-light");
        await window.Browser.ExecuteAsync("inspect"); await SnapshotAsync(directory, "07-inspector-window");
        var terminal = runtime.Sessions.Single(s => s.Definition.Title == "W7 PowerShell");
        window.OpenSession(terminal.Definition.Id); await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == terminal.Definition.Id));
        window.Model.Split = TerminalDeck.App.ViewModels.SplitPresentation.Browser;
        await SnapshotAsync(directory, "08-session-browser-split-light"); window.Model.Split = TerminalDeck.App.ViewModels.SplitPresentation.None;
        }
        foreach (var section in phase == "pages" ? new[] { 3 } : new[] { 0, 1, 2, 3 })
        {
          window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(section);
          if (section == 2) await window.Settings.ShowCodeAsync();
          if (section == 3 && (await runtime.Mcp.ListAsync()).Count == 0) await runtime.Mcp.AddAsync(new() { Name = "final-saved-server", Scope = "user", Transport = "http", Url = "http://127.0.0.1:1/mcp" });
          await window.Settings.RenderAsync(); await SnapshotAsync(directory, "09-settings-" + section);
        }
        Check("All accounts stay signed out", runtime.Accounts.List().All(a => !a.SignedIn));
        runtime.Remote.Trust.Pairing.Cancel(); window.Settings.ActiveCodeForProofClear();
        var project = runtime.Projects.List().FirstOrDefault(p => p.Name == "Windows sample") ?? runtime.Projects.Create("Windows sample", folder);
        var agent = runtime.Agents.List().FirstOrDefault(a => a.Name == "Sample reviewer") ?? runtime.Agents.Save(new("sample-reviewer", "Sample reviewer", "codex", "Reviews project changes", ProjectId: project.Id));
        window.ShowProjectsForProof(); await SnapshotAsync(directory, "10-projects-list-light");
        window.OpenProject(project.Id); await SnapshotAsync(directory, "11-project-page-light");
        window.ShowAgentsForProof(); await SnapshotAsync(directory, "12-agents-list-light");
        window.OpenAgent(agent.Id); await SnapshotAsync(directory, "13-agent-page-light");
        var picker = NewSessionPicker.ShowAsync(window.Frame.XamlRoot, runtime.Agents, runtime.Projects, runtime.Accounts, window, terminalStart: (_, _) => Task.CompletedTask);
        await SnapshotAsync(directory, "14-new-session-picker");
        var dialog = NewSessionPicker.ActiveDialogForProof;
        if (dialog is null) throw new InvalidOperationException("The new-session dialog could not be found.");
        var labels = Descendants(dialog).OfType<ComboBox>().Select(c => c.Header as string).ToArray();
        Check("One picker exposes project, agent, AI, account and view choices", new[] { "Project", "Work as", "Coding AI", "Account", "View" }.All(n => labels.Count(l => l == n) == 1));
        dialog.Hide(); await picker;
        var caller = runtime.Door.RegisterCaller(new("w7-read", null, null, true, AiPermissionMode.Ask, McpCatalogue.Load().Select(t => t.Id).ToArray(), Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddMinutes(2), true), (_, _, _, _, _) => ValueTask.FromResult(true));
        try
        {
          var tools = runtime.Door.List(caller.Id); Check("All 31 project/agent handlers and chat tools are in the guarded door", ProjectsAgentsMcp.Specs.All(s => tools.Any(t => t.Id == s.Id)) && ChatMcpTools.Tools.All(id => tools.Any(t => t.Id == id)));
          var sessions = await runtime.Door.CallAsync(caller.Id, "sessions.list", JsonSerializer.SerializeToElement(new { }));
          Check("MCP session list includes real chat and terminal", sessions.EnumerateArray().Any(s => s.TryGetProperty("mode", out var m) && m.GetString() == "chat") && sessions.GetArrayLength() >= 2);
          var saved = await runtime.Door.CallAsync(caller.Id, "agents.profile", JsonSerializer.SerializeToElement(new { id = agent.Id }));
          Check("MCP reads the saved agent", saved.GetProperty("agent").GetProperty("name").GetString() == agent.Name);
        }
        finally { runtime.Door.Revoke(caller.Id); }
        window.SetTheme(ElementTheme.Dark); window.OpenProject(project.Id); await SnapshotAsync(directory, "15-project-page-dark");
        window.OpenAgent(agent.Id); await SnapshotAsync(directory, "16-agent-page-dark");
        var unsigned = runtime.Chats.List().First(c => c.Problem == ChatErrors.NotSignedIn("claude")); window.OpenSession(unsigned.Definition.Id);
        await UntilAsync(() => Task.FromResult(window.Model.Selected?.Id == unsigned.Definition.Id)); await SnapshotAsync(directory, "17-signed-out-chat-dark");
        await FakeChatAsync(window, directory, Check);
      }
      if (phase == "picker-appearance")
      {
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
          window.SetTheme(theme); await Task.Delay(300);
          var picker = NewSessionPicker.ShowAsync(window.Frame.XamlRoot, runtime.Agents, runtime.Projects, runtime.Accounts, window, terminalStart: (_, _) => Task.CompletedTask);
          await Task.Delay(300);
          var dialog = NewSessionPicker.ActiveDialogForProof ?? throw new InvalidOperationException("The picker did not open.");
          Check("Picker follows " + theme + " and refuses an empty working folder", dialog.RequestedTheme == theme && !dialog.IsPrimaryButtonEnabled);
          await SnapshotAsync(directory, theme == ElementTheme.Light ? "21-new-session-picker-light" : "22-new-session-picker-dark");
          dialog.Hide(); await picker;
        }
      }
      if (phase == "tool-start")
      {
        // W8 uses the caller authority introduced by the review fixes. The old
        // app-wide approval dialog is no longer the calling AI's permission flow.
        var caller = runtime.CallerAuthority.Provision(runtime.Door,
          new("w8-tool-start", null, null, AiPermissionMode.Ask, ["sessions.start"], Enum.GetValues<McpTier>(), ["folders:" + folder, "projects:" + ProjectIdentity.IndependentId]), _ => true);
        Task<JsonElement> ApproveAsync(object arguments) => runtime.Door.CallAsync(caller.Id, "sessions.start", JsonSerializer.SerializeToElement(arguments)).AsTask();
        try
        {
          _ = await ApproveAsync(new { cwd = folder, provider = "shell", mode = "terminal", projectId = ProjectIdentity.IndependentId, title = "MCP shell ownership" });
          var row = runtime.Sessions.Last(s => s.Definition.Title == "MCP shell ownership");
          Check("Approved MCP shell start honors explicit Independent ownership", runtime.Projects.GroupSessions(runtime.ProjectSessions()).Single(g => g.ProjectId == ProjectIdentity.IndependentId).Sessions.Any(s => s.Id == row.Definition.Id));
          await runtime.StopAsync(row.Definition.Id);
          var refused = false;
          try { _ = await ApproveAsync(new { cwd = folder, provider = "shell", mode = "chat" }); }
          catch (McpRefusal ex) { refused = ex.Message == "PowerShell uses the terminal view. Choose terminal mode."; }
          Check("MCP refuses PowerShell chat mode with a plain message", refused);
        }
        finally { runtime.CallerAuthority.Revoke(runtime.Door, "w8-tool-start"); }
      }
      if (phase == "published")
      {
        var hello = await runtime.Keeper.HelloAsync();
        Check("Published layout starts its bundled keeper and chat service in a fresh scratch root", File.Exists(runtime.KeeperExecutable) && runtime.KeeperExecutable.StartsWith(AppContext.BaseDirectory, StringComparison.OrdinalIgnoreCase) && runtime.Chats.List().Count == 0);
        await SnapshotAsync(directory, "27-published-layout-ready");
      }
      if (phase == "picker-start")
      {
        string? created = null;
        var picker = NewSessionPicker.ShowAsync(window.Frame.XamlRoot, runtime.Agents, runtime.Projects, runtime.Accounts, window,
          terminalStart: async (workingFolder, projectId) => { var row = await runtime.StartShellForProjectAsync(workingFolder, projectId); created = row.Definition.Id; window.OpenSession(created); });
        await Task.Delay(300);
        var dialog = NewSessionPicker.ActiveDialogForProof ?? throw new InvalidOperationException("The picker did not open.");
        Descendants(dialog).OfType<ComboBox>().Single(c => c.Header as string == "Coding AI").SelectedValue = "shell";
        Descendants(dialog).OfType<TextBox>().Single(t => t.Header as string == "Working folder").Text = folder;
        await SnapshotAsync(directory, "25-powershell-picker");
        var start = Descendants(dialog).OfType<Button>().Single(b => b.Content as string == "Start");
        var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(start);
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        await picker.WaitAsync(TimeSpan.FromSeconds(40));
        await UntilAsync(() => Task.FromResult(created is not null && window.Model.Selected?.Id == created));
        await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(40));
        Check("Picker Start creates a terminal with explicit Independent ownership", created is not null && runtime.Projects.GroupSessions(runtime.ProjectSessions()).Single(g => g.ProjectId == ProjectIdentity.IndependentId).Sessions.Any(s => s.Id == created));
        await SnapshotAsync(directory, "26-picker-started-terminal");
        await runtime.StopAsync(created!);
      }
      if (phase == "approval-status") await FakeChatAsync(window, directory, Check, statusOnly: true);
      if (phase == "w8-browser") await W8PolishProof.BrowserAsync(window, directory, Check);
      if (phase == "w8-effort") await W8PolishProof.EffortAsync(window, directory, Check);
      if (phase == "w8-polish") await W8PolishProof.RunAsync(window, directory, Check);
      if (phase == "w8-layout") await FakeChatAsync(window, directory, Check, layoutOnly: true);
      if (phase == "chat-appearance") await FakeChatAsync(window, directory, Check, visualOnly: true);
      if (phase == "cleanup")
      {
        foreach (var row in runtime.Sessions.Where(s => s.State != TerminalDeck.Core.Sessions.SessionState.Exited)) await runtime.StopAsync(row.Definition.Id);
        runtime.Remote.Trust.Pairing.Cancel();
        foreach (var dataRoot in new[] { runtime.Root, AppDataRoot.Explicit(Path.Combine(runtime.Root.DirectoryPath, "fake-chat")) })
        {
          var vault = new WindowsCredentialStore(dataRoot);
          foreach (var suffix in new[] { "keeper/auth-v2", "remote-host", "remote-identity" })
            await vault.DeleteAsync(TerminalDeck.Core.Brand.Name + "/" + dataRoot.NamespaceId + "/" + suffix);
        }
        Check("Owned walkthrough terminal stopped and scratch vault entries removed", runtime.Sessions.All(s => s.State == TerminalDeck.Core.Sessions.SessionState.Exited));
      }
      if (phase == "fake") await FakeChatAsync(window, directory, Check);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { failed.Add("Walk stopped: " + ex.GetType().Name + ": " + ex.Message); await File.WriteAllTextAsync(Path.Combine(directory, "failure-location.txt"), ex.StackTrace ?? ""); }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { phase, passed, failed, passCount = passed.Count, failCount = failed.Count, timestamp = DateTimeOffset.UtcNow }));
  }
  private static async Task FakeChatAsync(ShellWindow window, string directory, Action<string, bool> check, bool visualOnly = false, bool statusOnly = false, bool layoutOnly = false)
  {
    var root = AppDataRoot.Explicit(Path.Combine(window.Runtime.Root.DirectoryPath, "fake-chat")); Directory.CreateDirectory(root.DirectoryPath);
    var tools = Path.Combine(root.DirectoryPath, "tools"); var entry = Path.Combine(tools, "node_modules", "@anthropic-ai", "claude-code", "cli.js"); Directory.CreateDirectory(Path.GetDirectoryName(entry)!);
    File.Copy(Path.Combine(AppContext.BaseDirectory, "Verification", "w7-fake-claude.cjs"), entry, true);
    var accounts = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [new FakeAccount()]); var account = accounts.List().FirstOrDefault() ?? await accounts.CreateAsync("claude", "Fake CLI · no real sign-in");
    var process = new WindowsChatProcessKeeper(root, window.Runtime.KeeperExecutable, tools, KeeperCredentials.GetOrCreate(root));
    await using var core = new ChatSessions(new ChatHistory(root), process, accounts);
    using var stop = new CancellationTokenSource(); var serving = new ChatSessionsPipeServer(root, core, KeeperCredentials.GetOrCreate(root)).RunAsync(stop.Token);
    var client = await WindowsChatSessionsClient.ConnectAsync(root, KeeperCredentials.GetOrCreate(root)); var chat = await client.CreateAsync("claude", root.DirectoryPath, account.Id);
    var page = new ChatPage(client, chat.Definition.Id, window.WindowHandle); window.ShowProofChat(page);
    try
    {
      page.Model.Draft = layoutOnly ? "W8 layout fixture: " + string.Join(" ", Enumerable.Repeat("A long user message wraps inside its bubble.", 10)) : "Show bubbles, a tool step and an approval card. Fake CLI only."; await page.Model.SendAsync();
      await UntilAsync(() => Task.FromResult(page.Model.Rows.Any(r => r.Kind == "approval" && r.Waiting)));
      page.Model.Draft = "queued follow-up"; await page.Model.SendAsync();
      if (!visualOnly && !statusOnly && !layoutOnly) check("Fake stream-json CLI reaches bubbles, tool result, approval and pending Send now", page.Model.Rows.Any(r => r.Kind == "assistant") && page.Model.Rows.Any(r => r.Kind == "tool") && page.Model.Pending.Count == 1 && Descendants(page).OfType<Button>().Any(b => b.Content as string == "Send now"));
      if (visualOnly)
      {
        await Task.Delay(500);
        var allow = Descendants(page).OfType<Button>().Single(b => b.Content as string == "Allow once");
        DependencyObject? ancestor = allow;
        while (ancestor is not null && ancestor is not ScrollViewer) ancestor = VisualTreeHelper.GetParent(ancestor);
        var viewport = (ScrollViewer?)ancestor ?? throw new InvalidOperationException("The approval has no history viewport.");
        var bounds = allow.TransformToVisual(viewport).TransformBounds(new Windows.Foundation.Rect(0, 0, allow.ActualWidth, allow.ActualHeight));
        check("Approval actions stay fully visible after the pending queue resizes history", bounds.Y >= 0 && bounds.Bottom <= viewport.ActualHeight);
      }
      if (!statusOnly && !layoutOnly) await SnapshotAsync(directory, visualOnly ? "23-chat-approval-dark-final" : "18-fake-cli-chat-dark");
      window.SetTheme(ElementTheme.Light); if (!statusOnly && !layoutOnly) await SnapshotAsync(directory, visualOnly ? "24-chat-approval-light-final" : "19-fake-cli-chat-light");
      if (layoutOnly) await W8LayoutProof.CheckAsync(window, page, directory, check);
      await page.Model.AnswerAsync(page.Model.Rows.Single(r => r.Kind == "approval" && r.Waiting).Id, false);
      await UntilAsync(() => Task.FromResult(page.Model.Rows.Any(r => r.Text.Contains("received the queued follow-up", StringComparison.Ordinal))));
      if (!visualOnly && !statusOnly && !layoutOnly) check("Fake CLI gets refusal and then drains the pending message", page.Model.Pending.Count == 0);
      if (!visualOnly && !statusOnly && !layoutOnly) await SnapshotAsync(directory, "20-fake-cli-approval-reply");
      if (statusOnly)
      {
        await UntilAsync(() => Task.FromResult(page.Model.Rows.Single(r => r.Kind == "approval").Status == "Refused"));
        check("Completed approval keeps Refused after the late worker receipt", page.Model.Rows.Single(r => r.Kind == "approval").Status == "Refused");
        await SnapshotAsync(directory, "28-final-approval-status");
      }
    }
    finally { window.HideProofChat(); await page.DisposeAsync(); await process.QuitAsync(chat.CreationKey, CancellationToken.None); stop.Cancel(); await serving; }
  }
  private sealed class FakeAccount : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "fake@example.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new InvalidOperationException("Fake CLI has no sign-in.");
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
  private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
  {
    yield return parent;
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) foreach (var child in Descendants(VisualTreeHelper.GetChild(parent, i))) yield return child;
  }
  private static async Task UntilAsync(Func<Task<bool>> predicate)
  {
    var until = DateTimeOffset.UtcNow.AddSeconds(50);
    while (DateTimeOffset.UtcNow < until) { if (await predicate()) return; await Task.Delay(150); }
    throw new TimeoutException("The walkthrough check timed out.");
  }
  private static async Task SnapshotAsync(string directory, string name)
  { await Task.Delay(500); await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name })); await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, name + ".ack")))); }
}
