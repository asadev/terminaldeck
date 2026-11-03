using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RunTaskDetailProofAsync()
  {
    var output = Environment.GetEnvironmentVariable("TD_TASK_DETAIL_PROOF")!;
    if (!dataRoot.DirectoryPath.StartsWith(@"C:\TD-TasksDetailProof\", StringComparison.OrdinalIgnoreCase) ||
      !File.Exists(Path.Combine(dataRoot.DirectoryPath, ".tasks-detail-allow")) ||
      !Path.GetFullPath(output).StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("Task renders require a marked isolated root.");
    var passed = new List<string>(); var failed = new List<string>(); var frames = new List<object>();
    void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
    void Stage(string name) => File.WriteAllText(Path.Combine(output, "stage.txt"), name);
    async Task Capture(string name)
    {
      Stage(name); Model.Notice = ""; await Task.Delay(250); Root.UpdateLayout();
      frames.Add(await Verification.W10Proof.CaptureAsync(Root, output, name, Root.ActualTheme.ToString().ToLowerInvariant(), "Synthetic task, comments and activity. No provider launch or live data.", Stage));
    }
    try
    {
      await Ready; using var sizing = new W13RenderWindow(this);
      var projectFolder = Path.Combine(Path.GetDirectoryName(dataRoot.DirectoryPath)!, "project"); Directory.CreateDirectory(projectFolder);
      var project = Runtime.Projects.Save(new("task-proof", "Deck Dev", [projectFolder]));
      var agent = Runtime.Agents.Save(new("task-proof-agent", "Codex", "codex", ProjectId: project.Id, Icon: "chart.bar@green"));
      var task = Runtime.Tasks.Create(new("Compile both configurations", "Build Debug and Release, then compare the task popup with the reference.\n\nKeep the existing sessions and project data.", project.Id, projectFolder, Status: "Working on it"), TaskActor.Owner);
      await Runtime.Tasks.CommentAsync(task.Id, "I started on both configurations. The task popup is ready for review.", new(agent.Id, agent.Name, "agent"));
      await Runtime.Tasks.CommentAsync(task.Id, "Light and dark renders are next. Check the fields, thread and top bar.", new(agent.Id, agent.Name, "agent"));
      Runtime.Tasks.Status(task.Id, "In Progress", TaskActor.Owner); Runtime.Tasks.Status(task.Id, "Working on it", TaskActor.Owner);
      foreach (var width in new[] { 1920, 1280 }) foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        sizing.Resize(width, width == 1920 ? 1080 : 900); SetTheme(theme); await Task.Delay(250);
        var tabs = windowState.Tabs.Select(t => t.Id).ToArray();
        foreach (var page in new[] { ShellPage.Projects, ShellPage.Devices, ShellPage.Servers, ShellPage.Receiver, ShellPage.Mcp, ShellPage.Tasks }) { Model.Page = page; await Task.Delay(80); }
        Check(width + " " + theme + " sidebar pages create no tabs", tabs.SequenceEqual(windowState.Tabs.Select(t => t.Id)));
        tasksPage!.Model.Select(null); await Capture($"tasks-list-{width}-{theme.ToString().ToLowerInvariant()}");
        Check(width + " " + theme + " far-left toggle", SidebarToggle.TransformToVisual(Root).TransformPoint(new(0, 0)).X < 16);
        sidebar.Geometry(sidebar.Read.Width, false); Root.UpdateLayout();
        Check(width + " " + theme + " hidden toggle stays left", SidebarToggle.TransformToVisual(Root).TransformPoint(new(0, 0)).X < 16);
        sidebar.Geometry(sidebar.Read.Width, true);
        await Capture($"tasks-topbar-{width}-{theme.ToString().ToLowerInvariant()}");
        tasksPage.Model.Select(task.Id); await Capture($"task-popup-{width}-{theme.ToString().ToLowerInvariant()}");
        var popup = ProofTree(Root).OfType<FrameworkElement>().FirstOrDefault(e => AutomationProperties.GetAutomationId(e) == "tasks.popup");
        Check(width + " " + theme + " floating popup is mounted", popup is not null);
        var properties = ProofTree(popup!).OfType<Grid>().Single(g => AutomationProperties.GetAutomationId(g) == "tasks.properties");
        Check(width + " " + theme + " two property columns", properties.ColumnDefinitions.Count == 4 && properties.Children.OfType<FrameworkElement>().Any(e => AutomationProperties.GetAutomationId(e) == "tasks.label.Assignees" && Grid.GetColumn(e) == 2));
        Check(width + " " + theme + " fields stay inside popup", properties.Children.OfType<FrameworkElement>().All(e => e.TransformToVisual(properties).TransformPoint(new(0, 0)).X + e.ActualWidth <= properties.ActualWidth + 2));
        Check(width + " " + theme + " inline description and no old post button", ProofTree(popup!).OfType<TextBox>().Any(b => AutomationProperties.GetName(b) == "Description") && !ProofTree(popup!).OfType<Button>().Any(b => b.Content as string == "Post comment"));
        var inline = ProofTree(popup!).OfType<TextBox>().Single(b => AutomationProperties.GetName(b) == "Description");
        Check(width + " " + theme + " multiline description remains readable", inline.Text.Contains("Keep the existing sessions", StringComparison.Ordinal) && inline.ActualHeight >= 54);
        Check(width + " " + theme + " comment cards present", ProofTree(popup!).OfType<TextBlock>().Count(t => t.Text == "Codex") == 2);
        Check(width + " " + theme + " no shortcut tooltip", !Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(Root.XamlRoot).Any(p => ProofTree(p.Child).OfType<ToolTip>().Any()));
        tasksPage.Model.ThreadPane = "Activity"; tasksPage.Model.PresentationChanged();
        await Capture($"task-activity-{width}-{theme.ToString().ToLowerInvariant()}");
        tasksPage.Model.ThreadPane = "Comments"; tasksPage.Model.Select(null);
      }
      await RunTaskHeaderProofAsync(output, task.Id, agent.Id, project.Id);
      await RunTaskPropertyProofAsync(output, task.Id);
      await RunModelPickerProofAsync(output);
      await RunTaskTabsProofAsync(output);
      File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { passed, failed, frames }));
    }
    catch (Exception ex) { failed.Add(ex.ToString()); File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { passed, failed, frames })); }
    finally { closingShell = true; Close(); }
  }
}
