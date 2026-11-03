using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Views;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Mcp;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Verification;

internal static class W8PolishProof
{
  public static async Task RunAsync(ShellWindow window, string directory, Action<string, bool> check)
  {
    var runtime = window.Runtime;
    var project = runtime.Projects.List().Single(p => p.Name == "Windows sample");
    var agent = runtime.Agents.List().Single(a => a.Name == "Sample reviewer");
    using (var image = new InMemoryRandomAccessStream())
    {
      var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, image);
      var pixels = Enumerable.Range(0, 48 * 48).SelectMany(i => new byte[] { (byte)(80 + i % 48 * 3), 110, 35, 255 }).ToArray();
      encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, 48, 48, 96, 96, pixels); await encoder.FlushAsync();
      using var reader = new DataReader(image.GetInputStreamAt(0)); await reader.LoadAsync((uint)image.Size); var bytes = new byte[checked((int)image.Size)]; reader.ReadBytes(bytes);
      var path = Path.Combine(directory, "project-picture.png"); await File.WriteAllBytesAsync(path, bytes); runtime.Projects.SetPicture(project.Id, path);
    }
    var run = await runtime.Agents.StartAsync(new(null, ProjectId: project.Id, Provider: agent.Provider, AccountId: runtime.Accounts.List(agent.Provider).Single().Id, Mode: "chat", Title: "Project picture and composer"));
    window.OpenSession(run.SessionId); await Task.Delay(400);
    var row = window.Model.Sessions.Single(s => s.Id == run.SessionId);
    check("Sidebar reads the saved project picture and the coding AI fallback", row.PicturePath == runtime.Projects.PicturePath(project.Id) && row.PicturePath is not null && row.Subtitle.StartsWith(TerminalDeck.Core.Agents.AgentSeats.ProviderName(agent.Provider) + " · ", StringComparison.Ordinal));
    check("Healthy connection uses no permanent notice banner", !Tree(window.Frame).OfType<InfoBar>().Any(b => b.IsOpen && b.Message.StartsWith("Connected.", StringComparison.Ordinal)));
    var page = window.SelectedChat;
    var effort = Tree(page).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "chat.effort");
    Invoke(effort);
    await Task.Delay(200);
    var choice = VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<MenuFlyoutItem>().Single(m => m.Text == "high");
    ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(choice).GetPattern(PatternInterface.Invoke)).Invoke();
    await Task.Delay(250);
    check("Effort chip changes the saved chat option without a model list or provider call", page.Model.Snapshot.Definition.Options.Effort == "high" && page.Model.Snapshot.Messages.Length == 0 && (await page.Model.ModelsAsync()).Count == 0);
    var caller = runtime.CallerAuthority.Provision(runtime.Door, new("w8-effort", run.SessionId, null, AiPermissionMode.Ask,
      ["agents.set_control"], Enum.GetValues<McpTier>(), ["sessions:" + run.SessionId, "accounts:" + page.Model.Snapshot.Definition.AccountId, "folders:" + page.Model.Snapshot.Definition.Cwd]), _ => true);
    try
    {
      await runtime.Door.CallAsync(caller.Id, "agents.set_control", JsonSerializer.SerializeToElement(new { sessionId = run.SessionId, control = "effort", value = "medium" }));
      check("Existing guarded MCP tool changes the same effort option", runtime.Chats.Get(run.SessionId).Definition.Options.Effort == "medium");
    }
    finally { runtime.CallerAuthority.Revoke(runtime.Door, "w8-effort"); }
    foreach (var width in new[] { 1280, 920 })
    foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
    {
      window.AppWindow.Resize(new Windows.Graphics.SizeInt32(width, 840)); window.SetTheme(theme); await Task.Delay(300); page.UpdateLayout();
      var chips = Tree(page).OfType<Button>().Where(b => AutomationProperties.GetAutomationId(b) is "chat.model" or "chat.effort" or "chat.account" or "chat.send").ToArray();
      check($"Four composer controls fit at {width} in {theme}", chips.Length == 4 && chips.All(b => { var box = b.TransformToVisual(page).TransformBounds(new Windows.Foundation.Rect(0, 0, b.ActualWidth, b.ActualHeight)); return box.X >= 0 && box.Right <= page.ActualWidth + 1 && box.Bottom <= page.ActualHeight + 1 && b.ActualWidth >= 40; }));
      await Snapshot(directory, $"w8-composer-sidebar-{width}-{theme}");
    }
    window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 840));
    window.ShowProjectsForProof(); await Task.Delay(200);
    check("Projects has one visible page heading", Tree(window.Frame).OfType<TextBlock>().Count(t => t.Text == "Projects" && t.ActualHeight > 0) == 2);
    // One navigation label and one toolbar title; no third in the page content.
    window.ShowAgentsForProof(); await Task.Delay(200);
    check("Agents has one visible page heading", Tree(window.Frame).OfType<TextBlock>().Count(t => t.Text == "Agents" && t.ActualHeight > 0) == 2);
    await runtime.Chats.EndAsync(run.SessionId);
  }
  public static async Task EffortAsync(ShellWindow window, string directory, Action<string, bool> check)
  {
    var runtime = window.Runtime;
    var chat = await runtime.Chats.CreateAsync("codex", runtime.Root.DirectoryPath, runtime.Accounts.List("codex").Single().Id);
    window.OpenSession(chat.Definition.Id); await Task.Delay(300);
    var page = window.SelectedChat;
    Invoke(Tree(page).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "chat.effort"));
    await Task.Delay(200);
    var item = VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<MenuFlyoutItem>().Single(m => m.Text == "high");
    ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(item).GetPattern(PatternInterface.Invoke)).Invoke();
    var until = DateTimeOffset.UtcNow.AddSeconds(10);
    while (page.Model.Snapshot.Definition.Options.Effort != "high" && page.Model.Error is null && DateTimeOffset.UtcNow < until) await Task.Delay(100);
    var ok = runtime.Chats.Get(chat.Definition.Id).Definition.Options.Effort == "high" && page.Model.Snapshot.Messages.Length == 0;
    check("Effort chip changes the saved chat option without a model list or provider call", ok);
    await File.WriteAllTextAsync(Path.Combine(directory, "effort-diagnostic.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, savedEffort = runtime.Chats.Get(chat.Definition.Id).Definition.Options.Effort, displayedEffort = page.Model.Snapshot.Definition.Options.Effort, error = page.Model.Error, messages = page.Model.Snapshot.Messages.Length }));
    await Snapshot(directory, "w8-effort-selected");
    await runtime.Chats.EndAsync(chat.Definition.Id);
  }
  public static async Task BrowserAsync(ShellWindow window, string directory, Action<string, bool> check)
  {
    window.Model.Page = TerminalDeck.App.ViewModels.ShellPage.Browser;
    await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(40));
    await window.Browser.AddTabAsync();
    var until = DateTimeOffset.UtcNow.AddSeconds(10);
    while (window.Browser.StatusForProof != "New tab" && DateTimeOffset.UtcNow < until) await Task.Delay(100);
    foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
    {
      window.SetTheme(theme); await Task.Delay(200);
      check("Loaded New tab reports its actual state in " + theme, window.Browser.StatusForProof == "New tab");
      await Snapshot(directory, "w8-new-tab-ready-" + theme);
    }
  }
  private static void Invoke(Button b) => ((IInvokeProvider)new ButtonAutomationPeer(b).GetPattern(PatternInterface.Invoke)).Invoke();
  private static IEnumerable<DependencyObject> Tree(DependencyObject node)
  {
    yield return node;
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child;
  }
  private static async Task Snapshot(string directory, string name)
  {
    await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name }));
    var until = DateTimeOffset.UtcNow.AddSeconds(30);
    while (!File.Exists(Path.Combine(directory, name + ".ack"))) { if (DateTimeOffset.UtcNow > until) throw new TimeoutException("W8 screenshot was not captured."); await Task.Delay(100); }
  }
}
