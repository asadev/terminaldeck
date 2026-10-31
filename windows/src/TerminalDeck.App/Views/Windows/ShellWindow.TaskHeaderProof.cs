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
  private async Task RunTaskHeaderProofAsync(string output, string taskId, string agentId, string projectId)
  {
    var passed = new List<string>(); var failed = new List<string>(); var frames = new List<object>();
    void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
    void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    Button Header(string id) => ProofTree(Root).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == id);
    async Task Until(Func<bool> ready)
    {
      var end = DateTime.UtcNow.AddSeconds(5);
      while (!ready()) { if (DateTime.UtcNow > end) throw new TimeoutException("Task header operation did not finish"); await Task.Delay(40); }
      await Task.Delay(60);
    }
    async Task Frame(FrameworkElement content, string name) => frames.Add(await Verification.W10Proof.CaptureAsync(content, output, name, "light", "Synthetic local roster and board only; no agents started, no messages sent", _ => { }));
    var theme = Root.RequestedTheme;
    var helper = Runtime.Agents.Save(new("task-header-helper", "Header helper", "codex", ProjectId: projectId));
    try
    {
      SetTheme(ElementTheme.Light); tasksPage!.Model.Select(taskId); await Task.Delay(180); Root.UpdateLayout();
      var before = Runtime.Tasks.Get(taskId); var runs = Runtime.Tasks.Runs(taskId).Count;
      var shareButton = Header("tasks.share"); var share = (Flyout)shareButton.Flyout;
      share.ShowAt(shareButton); await Task.Delay(100);
      var panel = (FrameworkElement)share.Content;
      var search = ProofTree(panel).OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == "tasks.share.search");
      search.Text = "Codex"; await Task.Delay(100); panel.UpdateLayout();
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Invite Codex"));
      await Until(() => Runtime.Tasks.Get(taskId).Assignee == agentId);
      Check("First invite becomes main person without starting work", Runtime.Tasks.Get(taskId).Status == before.Status && Runtime.Tasks.Runs(taskId).Count == runs);
      search.Text = "Header helper"; await Task.Delay(100); panel.UpdateLayout();
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Invite Header helper"));
      await Until(() => TaskExtras.Of(Runtime.Tasks.Get(taskId)).Participants.Contains(helper.Id));
      Check("Invite stays in the same live share panel", panel.XamlRoot is not null && ProofTree(panel).OfType<TextBlock>().Any(t => t.Text == "MAIN"));
      Check("Share explains the local-only scope", ProofTree(panel).OfType<TextBlock>().Any(t => t.Text.StartsWith("No link to share:", StringComparison.Ordinal)));
      search.Text = "no-such-local-agent"; await Task.Delay(100); panel.UpdateLayout();
      Check("Local people search filters its list", ProofTree(panel).OfType<TextBlock>().Any(t => t.Text == "No matching agents"));
      search.Text = ""; await Task.Delay(100); panel.UpdateLayout(); await Frame(panel, "task-share-roster");
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Remove Codex"));
      await Until(() => Runtime.Tasks.Get(taskId).Assignee == helper.Id);
      Check("Removing main promotes the next participant", TaskExtras.Of(Runtime.Tasks.Get(taskId)).Participants.IsEmpty);
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Invite You"));
      await Until(() => TaskExtras.Of(Runtime.Tasks.Get(taskId)).Participants.Contains("me"));
      Click(ProofTree(panel).OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Remove Header helper"));
      await Until(() => Runtime.Tasks.Get(taskId).Assignee == "me");
      share.Hide(); await Task.Delay(150); Root.UpdateLayout();
      Check("The personal task is restored after removals", TaskExtras.Of(Runtime.Tasks.Get(taskId)).Participants.IsEmpty && Runtime.Tasks.Get(taskId).Status == before.Status && Runtime.Tasks.Runs(taskId).Count == runs);
      var moveButton = Header("tasks.move"); var move = (Flyout)moveButton.Flyout;
      move.ShowAt(moveButton); await Task.Delay(80);
      var boards = (FrameworkElement)move.Content;
      var name = ProofTree(boards).OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == "tasks.move.new-board");
      Check("Move has the focused board controls", name.MaxLength == 40 && ProofTree(boards).OfType<Button>().Any(b => b.Content is string text && text.StartsWith("No board", StringComparison.Ordinal)));
      name.Text = "Native header proof"; await Frame(boards, "task-move-board");
      Click(ProofTree(boards).OfType<Button>().Single(b => b.Content as string == "Create board"));
      await Until(() => Runtime.Tasks.Get(taskId).Board == "Native header proof");
      Check("Moving changes only the board", JsonSerializer.Serialize(TaskService.Draft(before) with { Assignee = "me", Board = "Native header proof" }) == JsonSerializer.Serialize(TaskService.Draft(Runtime.Tasks.Get(taskId))));
      moveButton = Header("tasks.move"); move = (Flyout)moveButton.Flyout; move.ShowAt(moveButton); await Task.Delay(80);
      Click(ProofTree((FrameworkElement)move.Content).OfType<Button>().Single(b => b.Content is string text && text.StartsWith("No board", StringComparison.Ordinal)));
      await Until(() => Runtime.Tasks.Get(taskId).Board is null);
      Check("No board restores the original destination", Runtime.Tasks.Get(taskId).Assignee == "me" && Runtime.Tasks.Runs(taskId).Count == runs);
    }
    catch (Exception ex) { failed.Add(ex.ToString()); }
    finally { tasksPage!.Model.Select(null); SetTheme(theme); }
    File.WriteAllText(Path.Combine(output, "task-header-proof.json"), JsonSerializer.Serialize(new { passed, failed, frames }));
    if (failed.Count > 0) throw new InvalidOperationException("Task header native checks failed: " + string.Join(", ", failed));
  }
}
