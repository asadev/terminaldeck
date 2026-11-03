using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RunW14ProofAsync()
  {
    var output = Environment.GetEnvironmentVariable("TD_W14_PROOF")!;
    if (!dataRoot.DirectoryPath.StartsWith(@"C:\TD-W14Proof\", StringComparison.OrdinalIgnoreCase) || !File.Exists(Path.Combine(dataRoot.DirectoryPath, ".w14-allow")) ||
      !Path.GetFullPath(output).StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("W14 requires an isolated marked scratch root.");
    var passed = new List<string>(); var failed = new List<string>(); var frames = new List<object>();
    void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
    void Stage(string text) => File.WriteAllText(Path.Combine(output, "stage.txt"), text);
    async Task Capture(string name)
    {
      Model.Notice = ""; await Task.Delay(250); Root.UpdateLayout();
      frames.Add(await Verification.W10Proof.CaptureAsync(name.StartsWith("settings-", StringComparison.Ordinal) ? settingsWindowRoot! : Root, output, name, Root.ActualTheme.ToString().ToLowerInvariant(), "W11-format project copy; isolated terminal/chat; no AI delivery", Stage));
    }
    string? owned = null;
    try
    {
      await Ready; using var sizing = new W13RenderWindow(this);
      var before = File.ReadAllBytes(Path.Combine(dataRoot.DirectoryPath, "w11-projects-original.json"));
      Check("W11 projects unchanged by upgrade", before.SequenceEqual(File.ReadAllBytes(Path.Combine(dataRoot.DirectoryPath, "state", "projects.json"))));
      Check("W11 upgrade with absent sidebar retains project section", sidebar.Pinned("Projects") && ProjectsSection.Visibility == Visibility.Visible);
      Check("W11 two open projects and all five bindings preserved", Runtime.Projects.List().Count == 2 && Runtime.Projects.List().All(p => p.IsOpen) && new JsonStateStore<TerminalDeck.Core.Projects.ProjectState>(dataRoot, "projects").Load()!.Sessions.Length == 5);
      RefreshProjectRows(); Check("Both W11 projects rendered", ProjectRows.Children.Count == 2);
      var project = Runtime.Projects.List().First(p => p.Id != "independent");
      var folder = Path.Combine(dataRoot.DirectoryPath, "fixture-work"); Directory.CreateDirectory(folder);
      var shell = await Runtime.StartAsync("shell", folder, title: "Review PowerShell"); owned = shell.Definition.Id;
      Runtime.Projects.BindSession(owned, project.Id); SyncSessions(); W10SelectSession(owned);
      Check("Project count honors W11 explicit session binding outside its folder", ProjectRunningCount(project.Id) == 1);
      await sessionPanes[owned].Ready.WaitAsync(TimeSpan.FromSeconds(30));
      await sessionPanes[owned].InputForProofAsync("Write-Output 'W14 review - isolated scratch terminal'");
      var chat = await Runtime.Chats.CreateAsync("codex", folder, Runtime.Accounts.List("codex").Single().Id);
      SyncSessions();
      var ended = Model.AddDraft("shell", folder, SessionPresentation.Terminal); ended.Rename("Ended fixture"); ended.State = "exited";
      UpdateSidebarSessions(); Check("Ended terminal is absent from running and archives", !sidebarSessions.Contains(ended) && !archivedSessions.Contains(ended));
      ArchiveSidebarChat(chat.Definition.Id, true); Check("Archive excludes its chat from running project counts", ProjectRunningCount("independent") == 0); Check("Archive contains only explicitly archived chat", archivedSessions.Count == 1 && archivedSessions[0].Id == chat.Definition.Id);
      ArchiveSidebarChat(chat.Definition.Id, false); Check("Restore keeps chat and history", archivedSessions.Count == 0 && Runtime.Chats.Get(chat.Definition.Id).Definition.Id == chat.Definition.Id);
      foreach (var width in new[] { 1920, 1280 }) foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        CloseSettingsPanel(); settingsBounds = null; SetTheme(theme); sizing.Resize(width, width == 1920 ? 1080 : 840); await Task.Delay(300);
        W10SelectSession(owned); await Capture("terminal-" + width);
        var expectedInk = ((Microsoft.UI.Xaml.Media.SolidColorBrush)ShellTheme.Resource(Root, "DeckInkBrush")).Color;
        Check(width + " " + theme + " unselected running row has theme ink", ProofTree(SessionList).OfType<SidebarSessionRow>()
          .Where(row => row.DataContext is SessionDraft draft && draft.Id != owned).All(row => ProofTree(row).OfType<TextBlock>().Where(t => t.Text is "fixture-work" or "Codex").All(t => t.Foreground is Microsoft.UI.Xaml.Media.SolidColorBrush brush && brush.Color.Equals(expectedInk))));
        Check(width + " " + theme + " exact width", Math.Abs(Root.ActualWidth - width) < 2);
        Check(width + " " + theme + " no unknown usage or Shell chip", !ProofTree(Workspace).OfType<TextBlock>().Any(t => t.Text is "Usage unknown" or "Shell") && !ProofTree(Workspace).OfType<Button>().Any(b => b.Content as string is "Usage unknown" or "Shell"));
        foreach (var section in new[] { "general", "notifications", "appearance", "browser", "tasks", "coding-ais", "accounts", "outside-ai-apps", "advanced", "agent-defaults", "about" })
        {
          await OpenSettingsAsync(section); await Task.Delay(100); Root.UpdateLayout();
          Check(width + " " + theme + " " + section + " has its own window", settingsWindow is not null);
          if (section == "general")
          {
            var switches = ProofTree(settingsPanel!).OfType<ToggleSwitch>().ToArray();
            Check(width + " " + theme + " five General switches", switches.Length == 5);
            Check(width + " " + theme + " restore is honestly disabled", switches.Any(t => AutomationProperties.GetName(t) == "Pick up where you left off" && !t.IsEnabled && t.IsOn));
            foreach (var title in new[] { "Name sessions from the conversation", "Confirm before closing a session", "Copy on select", "Keep this PC awake while " + TerminalDeck.Core.Brand.Name + " is open" })
            {
              var control = switches.Single(t => AutomationProperties.GetName(t) == title);
              var was = control.IsOn; ((IToggleProvider)new ToggleSwitchAutomationPeer(control).GetPattern(PatternInterface.Toggle)).Toggle();
              var saved = title.StartsWith("Name", StringComparison.Ordinal) ? Runtime.General.Read().AutoNameSessions : title.StartsWith("Confirm", StringComparison.Ordinal) ? sidebar.Read.ConfirmDelete : title.StartsWith("Copy", StringComparison.Ordinal) ? Runtime.General.Read().CopyOnSelect : Runtime.General.Read().KeepAwake;
              Check(width + " " + theme + " saves " + title, saved != was); control.IsOn = was;
            }
            Check(width + " " + theme + " package version is real", Services.WindowsUpdateStatus.Version() == "0.20.2.44014");
            var check = ProofTree(settingsPanel!).OfType<Button>().Single(b => b.Content as string == "Check for updates");
            ((IInvokeProvider)new ButtonAutomationPeer(check).GetPattern(PatternInterface.Invoke)).Invoke(); await Task.Delay(500);
            Check(width + " " + theme + " updater reports configured-source status", ProofTree(settingsPanel!).OfType<TextBlock>().Any(t => t.Text.Contains("update source", StringComparison.Ordinal) || t.Text.Contains("up to date", StringComparison.Ordinal) || t.Text.Contains("MSIX updater", StringComparison.Ordinal)));
          }
          await Capture("settings-" + section + "-" + width);
          var surfaceRight = settingsPanel!.ActualWidth;
          foreach (var card in ProofTree(settingsPanel!).OfType<Border>().Where(b => AutomationProperties.GetAutomationId(b) == "settings.row"))
          {
            var cardRight = card.TransformToVisual(settingsPanel).TransformPoint(new(card.ActualWidth, 0)).X;
            Check(width + " " + theme + " " + section + " card fits content viewport", cardRight <= surfaceRight - 20);
            if (card.Child is Grid row)
              foreach (var control in row.Children.OfType<FrameworkElement>().Where(c => Grid.GetColumn(c) == 1))
              {
                var right = control.TransformToVisual(settingsPanel).TransformPoint(new(control.ActualWidth, 0)).X;
                Check(width + " " + theme + " " + section + " control stays flush inside card", right <= cardRight - card.Padding.Right + 1 && right >= cardRight - card.Padding.Right - 2);
              }
          }
          // Every shared SettingRow puts info immediately after its measured label.
          foreach (var info in ProofTree(settingsPanel!).OfType<Button>().Where(b => AutomationProperties.GetName(b).StartsWith("About ", StringComparison.Ordinal)))
            if (Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(info) is Grid labels && labels.Children.OfType<TextBlock>().FirstOrDefault() is { } label)
            {
              var labelRight = label.TransformToVisual(settingsPanel).TransformPoint(new(label.ActualWidth, 0)).X;
              var infoLeft = info.TransformToVisual(settingsPanel).TransformPoint(new(0, 0)).X;
              Check(width + " " + theme + " info hugs " + label.Text, infoLeft - labelRight is >= 0 and <= 4);
            }
        }
        CloseSettingsPanel(); ArchiveSidebarChat(chat.Definition.Id, true); ArchivedChatRows.Visibility = Visibility.Visible; UpdateSidebarSessions(); await Capture("archived-" + width); ArchiveSidebarChat(chat.Definition.Id, false);
      }
      var errors = Path.Combine(dataRoot.DirectoryPath, "logs", "errors.log"); Check("No hidden UI errors", !File.Exists(errors) || new FileInfo(errors).Length == 0);
    }
    catch (Exception ex) { failed.Add(ex.ToString()); }
    finally
    {
      if (owned is not null) try { await Runtime.StopAsync(owned); } catch (Exception ex) { failed.Add("Scratch terminal cleanup: " + ex.Message); }
      File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { passed, failed, frames }, new JsonSerializerOptions { WriteIndented = true }));
      App.Current.Exit();
    }
  }
}
