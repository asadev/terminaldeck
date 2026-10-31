using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Agents;

// Opt-in rendering of the production pages in a scratch instance. It never starts
// a provider or captures the desktop; the window stays outside the work area.
internal static class ProjectsAgentsParityProof
{
  private static bool started;
  public static void Start(IProjectsAgentsNavigation navigation)
  {
    var output = Environment.GetEnvironmentVariable("TD_PROJECTS_AGENTS_PARITY");
    if (started || output is null || navigation is not ShellWindow window ||
        !Path.GetFullPath(output).StartsWith(window.Runtime.Root.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return;
    started = true;
    window.AppWindow.Move(new Windows.Graphics.PointInt32(-20000, -20000));
    window.DispatcherQueue.TryEnqueueHandled(async () => await Run(window, output));
  }
  private static async Task Run(ShellWindow window, string output)
  {
    Directory.CreateDirectory(output);
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string title, bool ok) => (ok ? passed : failed).Add(title);
    try
    {
      await window.Ready.WaitAsync(TimeSpan.FromSeconds(60));
      var runtime = window.Runtime;
      if (runtime.Projects.List().Count != 1 || runtime.Agents.List().Count != 0 || runtime.Accounts.List().Count != 0)
        throw new InvalidOperationException("Use a fresh scratch root for these fixture writes.");
      var deckFolder = Path.Combine(runtime.Root.DirectoryPath, "Deck Dev"); Directory.CreateDirectory(deckFolder);
      var crmFolder = Path.Combine(runtime.Root.DirectoryPath, "CRM"); Directory.CreateDirectory(crmFolder);
      var matchFolder = Path.Combine(runtime.Root.DirectoryPath, "iMatch"); Directory.CreateDirectory(matchFolder);
      var deck = runtime.Projects.Create("Deck Dev", deckFolder);
      var crm = runtime.Projects.Create("CRM", crmFolder); runtime.Projects.Create("iMatch", matchFolder);
      await runtime.Accounts.CreateAsync("codex", "Personal"); await runtime.Accounts.CreateAsync("claude", "Work");
      var description = "Leads the project, plans the next release, and keeps the team focused on the work that matters. " +
        "Checks every change against the agreed scope and asks for evidence before calling it ready. " +
        "Coordinates the project’s agents, reviews their work, and leaves clear notes for the next session. " +
        "Keeps the project’s role memory current so another session can pick up the same work without losing its history.";
      var lead = runtime.Agents.Save(new("decker", "Decker", "codex", description, Model: "GPT-6.1 Sol", ProjectId: deck.Id, Seat: "project-lead", ReportsTo: AgentSeats.HootId));
      runtime.Agents.SetProjectLead(deck.Id, lead.Id);
      runtime.Agents.Save(new("alex", "Alex", "claude", "Builds and maintains the CRM.", Model: "Sonnet", ProjectId: crm.Id, Seat: "crm-engineer", ReportsTo: AgentSeats.HootId));
      runtime.Agents.Save(new("reviewer", "Release reviewer", "codex", "Checks and reviews releases.", Model: "GPT-6.1 Sol", ProjectId: deck.Id, Seat: "reviewer", ReportsTo: lead.Id));
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        window.SetTheme(theme); var suffix = theme.ToString().ToLowerInvariant();
        window.ShowProjectsForProof(); await Settle(); await Capture(window.Projects, output, "projects-" + suffix);
        window.OpenProject(deck.Id); await Settle(); await Capture(window.Projects, output, "project-page-" + suffix);
        window.ShowAgentsForProof(); await Settle(); await Capture(window.Agents, output, "agents-" + suffix);
        Click(window.Agents, "List view"); await Settle(); await Capture(window.Agents, output, "agents-list-" + suffix);
        Check("Three agent rows in list · " + suffix, Tree(window.Agents).OfType<Button>().Count(b => AutomationProperties.GetName(b).StartsWith("Open ", StringComparison.Ordinal)) == 3);
        Click(window.Agents, "Org chart view"); await Settle(); await Capture(window.Agents, output, "agents-org-" + suffix);
        Check("Org chart keeps nested reviewer visible · " + suffix, Tree(window.Agents).OfType<TextBlock>().Any(t => t.Text == "Release reviewer" && t.ActualWidth > 0));
        window.OpenAgent(lead.Id); await Settle(); await Capture(window.Agents, output, "agent-page-" + suffix);
        var more = Tree(window.Agents).OfType<HyperlinkButton>().Single(b => b.Content as string == "More");
        Check("Long description offers More · " + suffix, more.Visibility == Visibility.Visible);
        Invoke(more); await Settle();
        Check("More expands description and offers Less · " + suffix, more.Content as string == "Less" && Tree(window.Agents).OfType<TextBlock>().Any(t => t.Text == description && t.MaxLines == 0));
        Invoke(more); await Settle();
        Check("Less collapses to three lines · " + suffix, more.Content as string == "More" && Tree(window.Agents).OfType<TextBlock>().Any(t => t.Text == description && t.MaxLines == 3));
        Check("Nine facts have actionable destinations · " + suffix, Tree(window.Agents).OfType<Button>().Count(b => b.Content is Grid && ToolTipService.GetToolTip(b) is string) >= 9);
        Click(window.Agents, "Memory view"); await Settle();
        Check("Memory tab reaches edit action · " + suffix, Tree(window.Agents).OfType<Button>().Any(b => b.Content as string == "Edit memory"));
        window.ShowAgentsForProof(); await Settle(); Click(window.Agents, "All agents view"); await Settle(); Click(window.Agents, "Cards view"); await Settle();
        var picker = NewSessionPicker.ShowAsync(window.Frame.XamlRoot, runtime.Agents, runtime.Projects, runtime.Accounts, window, deck.Id, lead.Id);
        await Settle();
        var dialog = NewSessionPicker.ActiveDialogForProof ?? throw new InvalidOperationException("Picker did not open.");
        var combos = Tree(dialog).OfType<ComboBox>().ToArray();
        Check("Picker uses agent AI and account · " + suffix, ProjectAgentUi.Picked(combos.Single(c => c.Header as string == "AI")) == "codex" && ProjectAgentUi.Picked(combos.Single(c => c.Header as string == "Account")) == runtime.Accounts.List("codex").Single().Id);
        combos.Single(c => c.Header as string == "Agent").SelectedValue = "";
        var ai = combos.Single(c => c.Header as string == "AI"); ai.SelectedValue = "claude";
        Check("No agent permits changing AI and its account · " + suffix, ai.IsEnabled && ProjectAgentUi.Picked(combos.Single(c => c.Header as string == "Account")) == runtime.Accounts.List("claude").Single().Id);
        ai.SelectedValue = "codex"; await Settle(); await Capture(dialog, output, "new-session-" + suffix);
        var folder = Tree(dialog).OfType<TextBox>().Single(t => t.Header as string == "Working folder"); folder.Text = "";
        Check("Empty folder refuses Start · " + suffix, !dialog.IsPrimaryButtonEnabled);
        dialog.Hide(); await picker;
      }
      window.AppWindow.Resize(new Windows.Graphics.SizeInt32(920, 840)); window.ShowAgentsForProof(); await Settle();
      await Capture(window.Agents, output, "agents-narrow");
      Check("Narrow agent cards stay inside the page", Tree(window.Agents).OfType<Button>().Where(b => AutomationProperties.GetName(b).StartsWith("Open ", StringComparison.Ordinal)).All(b => b.TransformToVisual(window.Agents).TransformBounds(new Windows.Foundation.Rect(0, 0, b.ActualWidth, b.ActualHeight)).Right <= window.Agents.ActualWidth + 1));
      Check("No provider session or message was started", runtime.Agents.Runs().Count == 0 && runtime.Chats.List().Count == 0 && runtime.Sessions.Count == 0);
    }
    catch (Exception e) { failed.Add(e.ToString()); }
    finally
    {
      var vault = new WindowsCredentialStore(window.Runtime.Root);
      foreach (var suffix in new[] { "keeper/auth-v2", "remote-host", "remote-identity" })
        await vault.DeleteAsync(TerminalDeck.Core.Brand.Name + "/" + window.Runtime.Root.NamespaceId + "/" + suffix);
    }
    await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, failed, passCount = passed.Count, failCount = failed.Count }));
  }
  private static Task Settle() => Task.Delay(250);
  private static void Click(DependencyObject root, string name) => Invoke(Tree(root).OfType<ButtonBase>().Single(b => AutomationProperties.GetName(b) == name));
  private static void Invoke(ButtonBase button)
  {
    var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button);
    if (peer?.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) invoke.Invoke();
    else if (peer?.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle) toggle.Toggle();
    else throw new InvalidOperationException("No automation action for " + AutomationProperties.GetName(button));
  }
  private static IEnumerable<DependencyObject> Tree(DependencyObject node)
  {
    yield return node;
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child;
  }
  private static async Task Capture(FrameworkElement view, string output, string name)
  {
    view.UpdateLayout();
    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(view);
    if (bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0) throw new InvalidOperationException("Empty render: " + name);
    var pixels = await bitmap.GetPixelsAsync(); var bytes = new byte[checked((int)pixels.Length)]; DataReader.FromBuffer(pixels).ReadBytes(bytes);
    using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync();
    using var reader = new DataReader(stream.GetInputStreamAt(0)); await reader.LoadAsync((uint)stream.Size); var png = new byte[checked((int)stream.Size)]; reader.ReadBytes(png);
    await File.WriteAllBytesAsync(Path.Combine(output, name + ".png"), png);
  }
}
