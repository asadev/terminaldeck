using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Quality;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Quality;

public sealed partial class StaysFixedPage
{
  private void AddAdvancedActions(StackPanel top, Func<Task>? aiFix, Action<string>? openFile)
  {
    agentAccess = new ToggleSwitch { Header = "Let AI sessions use Stays Fixed", IsOn = service.AiSessionsEnabled(folder), OnContent = "AI tools available for this project", OffContent = "AI tools disabled for this project" };
    agentAccess.Toggled += (_, _) => { try { service.SetAiSessionsEnabled(folder, agentAccess.IsOn); notice.Text = agentAccess.IsOn ? "AI tools enabled after this project's setup is complete." : "AI-session Stays Fixed tools disabled for this project."; } catch (Exception error) when (error is IOException or InvalidOperationException) { notice.Text = error.Message; } };
    top.Children.Add(agentAccess);
    var tools = Horizontal();
    tools.Children.Add(Button("Full report", async () =>
    {
      try { await Dialog(XamlRoot, "Full Stays Fixed report", new ScrollViewer { Content = new TextBox { Text = service.FullReport(folder).ToString(), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = DeckFonts.Mono }, MaxHeight = 520 }, "Done").ShowAsync(); }
      catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException) { notice.Text = ex.Message; }
    }));
    tools.Children.Add(Button("Coverage", async () => await RunAsync("coverage")));
    tools.Children.Add(Button("Repair setup…", async () =>
    {
      if (await Dialog(XamlRoot, "Repair partial setup?", Words("The engine will repair its supported project folders and setup. Your existing configuration remains authoritative. Read the result for any runtime or browser requirements."), "Repair").ShowAsync() == ContentDialogResult.Primary) await RunAsync("repair");
    }));
    if (aiFix is not null) tools.Children.Add(Button("Fix with AI…", aiFix));
    if (openFile is not null) tools.Children.Add(Button("Configuration", () => { var config = new[] { "staysfixed.config.mjs", "staysfixed.config.js", "staysfixed.config.json" }.FirstOrDefault(f => File.Exists(Path.Combine(folder, f))); if (config is null) notice.Text = "Set up this project first."; else openFile(config); return Task.CompletedTask; }));
    top.Children.Add(new ScrollViewer { Content = tools, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    var edits = Horizontal();
    edits.Children.Add(Button("Mark as good…", async () =>
    {
      var reason = Field("Why is this the known-good build?", "");
      var force = new CheckBox { Content = "Use the checked build even if the engine reports differences" };
      var content = Stack(12); content.Children.Add(Words("This moves the engine's reference. Only mark a build that you have checked and reviewed.")); content.Children.Add(reason); content.Children.Add(force);
      if (await Dialog(XamlRoot, "Mark build as good?", content, "Mark as good").ShowAsync() == ContentDialogResult.Primary) await RunAsync(new StaysFixedRequest("mark-good", Reason: reason.Text, Force: force.IsChecked == true));
    }));
    edits.Children.Add(Button("Accept a difference…", async () =>
    {
      var finding = Field("Finding ID from the last report", ""); var reason = Field("Why was this intended?", ""); var content = Stack(12); content.Children.Add(finding); content.Children.Add(reason); content.Children.Add(Words("The engine enforces sealed intent, protected areas and waiver limits. Acceptance records intent; it does not move the reference.", muted: true));
      if (await Dialog(XamlRoot, "Accept intended difference", content, "Accept").ShowAsync() == ContentDialogResult.Primary) await RunAsync(new StaysFixedRequest("accept-diff", Finding: finding.Text, Reason: reason.Text));
    }));
    edits.Children.Add(Button("Seal intent…", async () =>
    {
      var summary = Field("What will change?", ""); var touches = Field("Files or areas · one per line", "", true); var content = Stack(12); content.Children.Add(summary); content.Children.Add(touches);
      if (await Dialog(XamlRoot, "Seal intent before editing", content, "Seal intent").ShowAsync() == ContentDialogResult.Primary) await RunAsync(new StaysFixedRequest("intent", Summary: summary.Text, Touches: touches.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)));
    }));
    edits.Children.Add(Button("Explain finding…", async () =>
    {
      var finding = Field("Finding ID", ""); if (await Dialog(XamlRoot, "Before, after and evidence", finding, "Read evidence").ShowAsync() == ContentDialogResult.Primary) await RunAsync(new StaysFixedRequest("explain", Finding: finding.Text));
    }));
    edits.Children.Add(Button("Add rule…", AddRuleAsync)); top.Children.Add(edits);
  }
  private async Task AddRuleAsync()
  {
    var name = Field("What must stay true? · a plain sentence", ""); var because = Field("Why does this matter?", ""); var command = Field("Executable", ""); var args = Field("Arguments · one per line", "", true);
    var content = Stack(12); foreach (var field in new[] { name, because, command, args }) content.Children.Add(field);
    content.Children.Add(Words("Creates an engine guard. The command runs on future checks, with this project's folder as its working directory. No shell expansion is used.", muted: true));
    if (await Dialog(XamlRoot, "Add a custom check rule", content, "Create rule").ShowAsync() != ContentDialogResult.Primary) return;
    try { var file = await service.AddRuleAsync(folder, name.Text, because.Text, command.Text, args.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries)); notice.Text = "Created " + Path.GetFileName(file) + ". Run a check to verify it."; }
    catch (Exception ex) when (ex is IOException or ArgumentException) { notice.Text = ex.Message; }
  }
}
