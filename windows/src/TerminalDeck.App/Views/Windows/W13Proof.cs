using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RunW13ProofAsync()
  {
    if (Environment.GetEnvironmentVariable("TD_W14_PROOF") is not null) { await RunW14ProofAsync(); return; }
    var output = Environment.GetEnvironmentVariable("TD_W13_PROOF")!;
    if (!dataRoot.DirectoryPath.StartsWith(@"C:\TD-W13Proof\", StringComparison.OrdinalIgnoreCase) ||
        !Guid.TryParse(Path.GetFileName(Path.GetDirectoryName(dataRoot.DirectoryPath)), out _) ||
        !File.Exists(Path.Combine(dataRoot.DirectoryPath, ".w13-allow")) ||
        File.ReadAllText(Path.Combine(dataRoot.DirectoryPath, ".w13-allow")).Trim() != "W13 SCRATCH ONLY" ||
        !Path.GetFullPath(output).StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("W13 requires a new marked scratch root.");
    Directory.CreateDirectory(output);
    if (Environment.GetEnvironmentVariable("TD_PARITY_PROOF") == "1") { await RunParityRenderProofAsync(output); return; }
    if (Environment.GetEnvironmentVariable("TD_SESSION_ICONS_PROOF") == "1") { await RunSessionIconsProofAsync(output); return; }
    var passed = new List<string>(); var failed = new List<string>(); var frames = new List<object>();
    string? ownedSession = null;
    void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
    void Stage(string name) => File.WriteAllText(Path.Combine(output, "stage.txt"), name);
    async Task Capture(string name)
    {
      Stage(name); Model.Notice = ""; await Task.Delay(250); Root.UpdateLayout();
      frames.Add(await Verification.W10Proof.CaptureAsync(name.StartsWith("settings-", StringComparison.Ordinal) ? settingsWindowRoot! : Root, output, name, Root.ActualTheme.ToString().ToLowerInvariant(),
        "Private synthetic project/agent/task metadata; own live PowerShell; signed-out chat; no AI send/sign-in", Stage));
    }
    try
    {
      await Ready; AppWindow.Move(new(-20000, -20000));
      using var renderWindow = new W13RenderWindow(this);
      if (Runtime.Projects.List().Count != 1 || Runtime.Sessions.Count != 0 || Runtime.Chats.List().Count != 0 || Runtime.Tasks.List(new(Status: "all")).Count != 0)
        throw new InvalidOperationException("W13 fixture root was not fresh.");
      Check("Startup has browser/session tabs only; Hoot stays closed", windowState.Tabs.All(t => t.Kind != "page") && Model.Page != ShellPage.Hoot);
      Check("Optional pages unpinned by default", SidebarState.Catalogue.Where(p => p.Id is not ("Agents" or "Tasks" or "Projects")).All(p => !sidebar.Pinned(p.Id)));
      sidebar.Pin("Projects", true);
      var folder = Path.Combine(Path.GetDirectoryName(dataRoot.DirectoryPath)!, "review-project"); Directory.CreateDirectory(folder);
      var project = Runtime.Projects.Create("Deck Dev", folder);
      Runtime.Agents.Save(new("w13-decker", "Decker", "codex", "Synthetic local review metadata", ProjectId: project.Id, Seat: "project-lead"));
      Runtime.Agents.Save(new("w13-alex", "Alex", "claude", "Synthetic local review metadata", ProjectId: project.Id));
      string? firstTask = null;
      foreach (var title in new[] { "Check the Windows frame", "Review task details", "Finish the handoff" })
      { var created = Runtime.Tasks.Create(new(title, "Synthetic review task. No run or delivery.", project.Id, folder, Status: title.Contains("handoff", StringComparison.Ordinal) ? "Stuck" : "To-Do"), TaskActor.Owner); firstTask ??= created.Id; }
      var shell = await Runtime.StartShellForProjectAsync(folder, project.Id); ownedSession = shell.Definition.Id; SyncSessions();
      var live = Model.Sessions.Single(s => s.Id == ownedSession); SelectSessionWindow(live);
      await sessionPanes[live.Id].Ready.WaitAsync(TimeSpan.FromSeconds(35));
      await sessionPanes[live.Id].InputForProofAsync("Write-Output 'W13 Windows review - isolated PowerShell, no coding AI started.'");
      for (var i = 0; i < 11; i++)
      {
        var row = Model.AddDraft(i % 2 == 0 ? "codex" : "claude", folder, SessionPresentation.Terminal);
        row.Rename("Review session " + (i + 2)); row.SetAppearance(project.Name, null, i % 2 == 0 ? "Decker" : "Alex", project.Id);
      }
      await Runtime.Accounts.SetDefaultAsync("codex", Runtime.Accounts.List("codex").Single().Id);
      var secondAccount = await Runtime.Accounts.CreateAsync("codex", "B1");
      var chat = await Runtime.Chats.CreateAsync("codex", folder, secondAccount.Id);
      await browser.Ready; await browser.AddTabAsync(); browser.ObserveShellPages(); SyncSessions();
      var browserId = browser.Core.Read().SelectedTabId!;
      Check("At least twelve retained session tabs", windowState.Tabs.Count(t => t.Kind is "terminal" or "chat") >= 12);
      foreach (var width in new[] { 1920, 1280 })
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        CloseSettingsPanel(); SetTheme(theme); renderWindow.Resize(width, width == 1920 ? 1080 : 840);
        await Task.Delay(350);
        Check(width + " " + theme + " exact requested client width", Math.Abs(Root.ActualWidth - width) < 2);
        W10SelectSession(live.Id); live.SetAppearance(project.Name, null, "Decker", project.Id);
        UpdateSidebarSessions(); await Capture("terminal-" + width);
        Check(width + " " + theme + " selected running sidebar row", SessionList.SelectedItem == live && live.State == "running");
        Check(width + " " + theme + " readable tab minimum", WorkspaceTabSizing.Width(windowState.Tabs.Count, WorkspaceHeader.ActualWidth) >= 156);
        W10SelectSession(chat.Definition.Id); await Capture("chat-" + width);
        foreach (var page in new[] { ShellPage.Tasks, ShellPage.Hoot, ShellPage.Projects, ShellPage.Agents })
        { Model.Page = page; if (page == ShellPage.Projects) Projects.Model.SelectedId = null; if (page == ShellPage.Agents) Agents.Model.SelectedId = null; await Capture(page.ToString().ToLowerInvariant() + "-" + width); }
        await W10ShowBrowserAsync(browserId); await Capture("browser-" + width);
        Model.Page = ShellPage.Tasks; tasksPage!.OpenTask(firstTask!); await Capture("task-detail-" + width); tasksPage.Model.Select(null);
        OpenProject(project.Id); await Capture("project-detail-" + width);
        OpenAgent("w13-decker"); await Capture("agent-detail-" + width);
        W10HostFixture(ShellPage.Servers, TerminalDeck.App.Views.Servers.ServersParityFixture.Create(windowHandle: WindowHandle)); await Capture("servers-" + width);
        W10HostFixture(ShellPage.Receiver, TerminalDeck.App.Views.Receiver.ReceiverParityFixture.Inbox()); await Capture("receiver-" + width);
        W10HostFixture(ShellPage.Artifacts, TerminalDeck.App.Views.Receiver.ReceiverParityFixture.Artifacts()); await Capture("artifacts-" + width);
        Model.Page = ShellPage.Mcp; await Capture("mcp-" + width);
        W10SelectSession(live.Id);
        foreach (var route in new[] { "general", "appearance", "coding-ais", "accounts", "notifications", "agent-defaults", "browser", "tasks", "outside-ai-apps", "advanced", "about" })
        {
          await OpenSettingsAsync(route); await Capture("settings-" + route + "-" + width);
          Check(width + " " + theme + " " + route + " Settings is a native window", settingsWindow is not null);
          Check(width + " " + theme + " " + route + " selected category matches page", settingsPanel!.SelectedCategory == SettingsNavigation.Canonical(route));
          var categoryInk = (Microsoft.UI.Xaml.Media.SolidColorBrush)ShellTheme.Resource(settingsPanel!, "DeckInkBrush");
          Check(width + " " + theme + " " + route + " all category labels retain theme contrast",
            ProofTree(settingsPanel!).OfType<ListViewItem>().Where(entry => entry.Tag is string && !entry.IsSelected)
              .All(entry => entry.Content is Border { Child: StackPanel labelRow } && labelRow.Children.OfType<TextBlock>()
                .All(label => label.Foreground is Microsoft.UI.Xaml.Media.SolidColorBrush ink && ink.Color.Equals(categoryInk.Color))));
        }
        var identity = settingsPanel; ShowSettingsPanel(); Check("Reopen retains one panel", ReferenceEquals(identity, settingsPanel) && settingsWindow is not null);
        ApplyNativeSettingsBounds(new(-500, -500, 2000, 2000));
        Check(width + " " + theme + " Settings clamps to the display", settingsWindow!.AppWindow.Position.X >= 0 && settingsWindow.AppWindow.Position.Y >= 0);
        settingsBounds = null; CloseSettingsPanel();
        W10SelectSession(live.Id); MorePages_Click(MorePages, new RoutedEventArgs()); await Task.Delay(100);
        var more = (FrameworkElement)morePagesFlyout!.Content; morePagesFlyout.Hide(); morePagesFlyout.Content = null;
        var menu = new Border { Child = more, Width = 280, Padding = new(12), CornerRadius = new(16), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new(16, 220, 0, 0) };
        menu.SetResourceReference(Border.BackgroundProperty, "DeckGlassBrush"); Grid.SetColumnSpan(menu, 2); Grid.SetRowSpan(menu, 2); Root.Children.Add(menu);
        try
        {
          var pin = ProofTree(more).OfType<ToggleButton>().First(p => p.Tag as string == "Servers");
          var before = sidebar.Pinned("Servers"); ((IToggleProvider)new ToggleButtonAutomationPeer(pin).GetPattern(PatternInterface.Toggle)).Toggle();
          Check(width + " " + theme + " actual More pin persists", sidebar.Pinned("Servers") != before && new JsonStateStore<SidebarSaved>(dataRoot, "sidebar").Load()!.Pages.Contains("Servers"));
          await Capture("more-pin-" + width); ((IToggleProvider)new ToggleButtonAutomationPeer(pin).GetPattern(PatternInterface.Toggle)).Toggle();
        }
        finally { Root.Children.Remove(menu); menu.Child = null; morePagesFlyout.Content = more; }
      }
      Check("Ten working Settings categories", SettingsNavigation.Categories.Count == 10);
      var errorLog = Path.Combine(dataRoot.DirectoryPath, "logs", "errors.log");
      Check("No recovered UI exception was hidden by the render runner", !File.Exists(errorLog) || new FileInfo(errorLog).Length == 0);
      Check("No AI chat sent", Runtime.Chats.List().All(c => c.Messages.Length == 0));
      Check("No Hoot turn or agent run", Runtime.Hoot.Read().Turns.Length == 0 && Runtime.Agents.Runs().Count == 0);
    }
    catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(error.ToString()); }
    finally
    {
      if (ownedSession is not null) try { await Runtime.StopAsync(ownedSession); } catch (Exception error) when (error is not OutOfMemoryException) { failed.Add("Own PowerShell cleanup: " + error.Message); }
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, failed, frames }, new JsonSerializerOptions { WriteIndented = true }));
      closingShell = true; Close();
    }
  }
}
