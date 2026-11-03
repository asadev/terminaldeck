using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RunTaskPropertyProofAsync(string output, string taskId)
  {
    var passed = new List<string>(); var failed = new List<string>(); var frames = new List<object>();
    void Check(string label, bool ok) => (ok ? passed : failed).Add(label);
    Button FieldButton(string id) => ProofTree(Root).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == id);
    TextBox Text(FrameworkElement panel, string id) => ProofTree(panel).OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == id);
    void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    void Choose(MenuFlyout menu, string id) => ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu.Items.OfType<MenuFlyoutItem>().Single(i => AutomationProperties.GetAutomationId(i) == id)).GetPattern(PatternInterface.Invoke)).Invoke();
    bool SameDraft(TaskDraft expected) => JsonSerializer.Serialize(expected) == JsonSerializer.Serialize(TaskService.Draft(Runtime.Tasks.Get(taskId)));
    async Task Until(Func<bool> ready)
    {
      var end = DateTime.UtcNow.AddSeconds(5);
      while (!ready()) { if (DateTime.UtcNow > end) throw new TimeoutException("Focused task field operation did not finish"); await Task.Delay(40); }
      await Task.Delay(150); Root.UpdateLayout();
    }
    async Task Frame(FrameworkElement panel, string name) => frames.Add(await Verification.W10Proof.CaptureAsync(panel, output, name, "light", "Synthetic focused task field editor; no agents launched or messages sent", _ => { }));
    var theme = Root.RequestedTheme;
    try
    {
      SetTheme(ElementTheme.Light); tasksPage!.Model.Select(taskId); await Task.Delay(180); Root.UpdateLayout();
      var initial = Runtime.Tasks.Get(taskId); var baseline = TaskService.Draft(initial); var runs = Runtime.Tasks.Runs(taskId).Count;
      var button = FieldButton("tasks.dates"); var dates = (Flyout)button.Flyout; dates.ShowAt(button); await Task.Delay(100);
      var panel = (FrameworkElement)dates.Content;
      Check("Dates opens only its focused start and due editors", ProofTree(panel).OfType<TextBox>().Count() == 4 && Text(panel, "tasks.dates.start").MaxLength == 10 && Text(panel, "tasks.dates.due").MaxLength == 10);
      Text(panel, "tasks.dates.start").Text = "2026-11-04"; Text(panel, "tasks.dates.due").Text = "2026-11-05";
      await Frame(panel, "task-dates-editor");
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "tasks.dates.save"));
      await Until(() => Runtime.Tasks.Get(taskId).DueDate == "2026-11-05");
      Check("Date Save changes only dates and times", SameDraft(baseline with { StartDate = "2026-11-04", StartTime = null, DueDate = "2026-11-05", DueTime = null }));
      button = FieldButton("tasks.dates"); dates = (Flyout)button.Flyout; dates.ShowAt(button); await Task.Delay(100);
      panel = (FrameworkElement)dates.Content;
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "tasks.dates.clear"));
      await Until(() => Runtime.Tasks.Get(taskId).StartDate is null && Runtime.Tasks.Get(taskId).DueDate is null);
      Check("Date Clear changes only dates and times", SameDraft(baseline with { StartDate = null, StartTime = null, DueDate = null, DueTime = null }));
      var clearedDates = TaskService.Draft(Runtime.Tasks.Get(taskId));
      button = FieldButton("tasks.priority"); var priority = (MenuFlyout)button.Flyout; priority.ShowAt(button); await Task.Delay(100);
      var popup = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(Root.XamlRoot).LastOrDefault()?.Child as FrameworkElement;
      if (popup is not null) await Frame(popup, "task-priority-editor");
      Choose(priority, "tasks.priority.high"); await Until(() => Runtime.Tasks.Get(taskId).Priority == "High");
      Check("Priority selection changes only Priority", SameDraft(clearedDates with { Priority = "High" }));
      button = FieldButton("tasks.priority"); priority = (MenuFlyout)button.Flyout; priority.ShowAt(button); await Task.Delay(100); Choose(priority, "tasks.priority.clear");
      await Until(() => Runtime.Tasks.Get(taskId).Priority is null); Check("Priority Clear changes only Priority", SameDraft(clearedDates with { Priority = null }));
      var beforeTags = TaskService.Draft(Runtime.Tasks.Get(taskId));
      button = FieldButton("tasks.tags"); var tags = (Flyout)button.Flyout; tags.ShowAt(button); await Task.Delay(100); panel = (FrameworkElement)tags.Content;
      var search = Text(panel, "tasks.tags.search"); search.Text = "Native property proof"; await Task.Delay(100); panel.UpdateLayout();
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "tasks.tags.create"));
      await Until(() => Runtime.Tasks.Get(taskId).Labels.Contains("Native property proof"));
      Check("Create tag changes only Labels", SameDraft(beforeTags with { Labels = beforeTags.Labels.Add("Native property proof") }));
      search.Text = "missing-tag-for-native-proof"; await Task.Delay(100); panel.UpdateLayout();
      Check("Tag search filters the real toggle list", !ProofTree(panel).OfType<CheckBox>().Any() && ProofTree(panel).OfType<TextBlock>().Any(t => t.Text == "No matching tags"));
      search.Text = "Native property proof"; await Task.Delay(100); panel.UpdateLayout(); await Frame(panel, "task-tags-editor"); tags.Hide(); await Task.Delay(180); Root.UpdateLayout();
      button = FieldButton("tasks.tags");
      Check("Nonempty Tags renders a chip instead of Empty", ProofTree(button).OfType<Border>().Any() && ProofTree(button).OfType<TextBlock>().Any(t => t.Text == "Native property proof"));
      tags = (Flyout)button.Flyout; tags.ShowAt(button); await Task.Delay(100); panel = (FrameworkElement)tags.Content;
      var toggle = ProofTree(panel).OfType<CheckBox>().Single(c => AutomationProperties.GetName(c) == "Tag Native property proof");
      ((IToggleProvider)new CheckBoxAutomationPeer(toggle).GetPattern(PatternInterface.Toggle)).Toggle();
      await Until(() => !Runtime.Tasks.Get(taskId).Labels.Contains("Native property proof"));
      Check("Tag toggle removes only the selected label", SameDraft(beforeTags)); tags.Hide(); await Task.Delay(150);
      Check("Focused field edits never start task work", Runtime.Tasks.Runs(taskId).Count == runs && Runtime.Tasks.Get(taskId).Status == initial.Status && Runtime.Tasks.Get(taskId).CurrentRunId == initial.CurrentRunId);
    }
    catch (Exception ex) { failed.Add(ex.ToString()); }
    finally { tasksPage!.Model.Select(null); SetTheme(theme); }
    File.WriteAllText(Path.Combine(output, "task-property-proof.json"), JsonSerializer.Serialize(new { passed, failed, frames }));
    if (failed.Count > 0) throw new InvalidOperationException("Task property native checks failed: " + string.Join(", ", failed));
  }
}
