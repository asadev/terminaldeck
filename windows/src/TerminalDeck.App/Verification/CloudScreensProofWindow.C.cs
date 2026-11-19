using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels.Agents;
using TerminalDeck.App.Views;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.App.Views.Computers;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Verification;

internal sealed partial class CloudScreensProofWindow
{
  private void Check(string name, bool value)
  {
    if (value) passed.Add(name); else failed.Add(name);
  }
  private async Task RunCAsync()
  {
    // Every write in this branch is below the explicitly marked scratch root.
    var folder = Path.Combine(data.DirectoryPath, "c-fixtures", "Website"); Directory.CreateDirectory(folder);
    var projectStore = new CMemory<ProjectState>();
    var projects = new ProjectService(projectStore, new CProjectFolders(folder));
    var website = projects.Create("Website", folder);
    var agentStore = new CMemory<AgentState>();
    var agents = new AgentService(agentStore, projects, new AgentInstructions(data));
    agents.Save(new("release-review", "Release reviewer", "codex", "Review the package and release notes.", ProjectId: website.Id, Skills: ["Release check"]));
    var run = new AgentRun("fixture-chat", "release-review", "Release reviewer", "codex", website.Id, AgentSeats.Role(website.Id, "release-review").Key, 1, "Review the release notes", "chat", AgentRunState.Running, DateTimeOffset.UtcNow);
    agentStore.Save(agentStore.Load()! with { Runs = [run] });
    agents = new AgentService(agentStore, projects, new AgentInstructions(data));
    var skillRoot = Path.Combine(folder, ".agents", "skills");
    var skillFolder = Path.Combine(skillRoot, "release-check"); Directory.CreateDirectory(skillFolder);
    await File.WriteAllTextAsync(Path.Combine(skillFolder, "SKILL.md"), "---\nname: Release check\ndescription: Check the package before release.\n---\nRead the release notes and package manifest.");
    var skills = AgentSkills.Find([skillRoot]);
    using var model = new AgentsViewModel(agents, projects) { Sessions = () => [new("fixture-chat", "Review the release notes", "codex", folder, "working", website.Id, "release-review", "chat")] };
    var agentPage = new AgentsPage(model, new ProofNavigation());
    Check("Agents at-work fixture derives one live busy hand", model.Activity(agents.Get("release-review")) is { Live: 1, Busy: 1 });
    Check("Skills are read only from the explicit scratch project", skills.Count == 1 && skills[0].Folder == skillFolder);
    agentPage.CProofDirectory("At work", skills);
    await Shot("agents-at-work", agentPage, 1100, 700, dark: true);
    Check("At work renders the real job row", Texts(agentPage).Contains("Review the release notes"));
    agentPage.CProofDirectory("Skills", skills);
    await Shot("agents-skills", agentPage, 1100, 700, dark: true);
    Check("Skills renders assigned agent and real actions", Texts(agentPage).Contains("Release reviewer") && Buttons(agentPage).Contains("Show skill") && Buttons(agentPage).Contains("Assign skill"));
    agentPage.CProofDirectory("All agents", skills);
    await Shot("agents-library", agentPage, 1100, 700);
    AgentEfficiency? policy = null;
    var editor = new StackPanel { Spacing = 16, Margin = new(24), MaxWidth = 700 };
    foreach (var row in AgentEfficiencyEditor.Rows(() => policy, value => policy = value, failed.Add)) editor.Children.Add(row);
    await Shot("agent-efficiency", new ScrollViewer { Content = editor }, 900, 1000, dark: true, background: "DeckRailBrush");
    Check("Efficiency editor exposes all nine real policy fields", WorkspaceVisuals.Tree(editor).OfType<FrameworkElement>().Count(e => Microsoft.UI.Xaml.Automation.AutomationProperties.GetAutomationId(e).StartsWith("agents.efficiency.", StringComparison.Ordinal)) == 9);
    Check("Viewing efficiency controls writes no default policy", policy is null);
    var at = DateTimeOffset.UtcNow;
    var ledger = new AgentBudgetLedger(new JsonStateStore<AgentUsageLedgerState>(data, "c-proof-agent-usage"));
    await ledger.ObserveAsync(new("fixture-chat", "release-review", "fixture-task", false, at, [new("fixture-request", at, 80), new("fixture-request", at, 80)], true, false));
    var totals = await ledger.MonthlyAsync("release-review", false, at);
    Check("Budget ledger counts repeated usage only once", totals.Tokens == 80);
    Check("Budget warning uses the real eighty-percent policy", AgentBudgetPolicy.Monthly(new(MonthlyTokens: 100), totals, false).Warning is not null);
    Check("Budget pause uses the real launch policy", AgentBudgetPolicy.Monthly(new(MonthlyTokens: 80, OnExhaustion: "pause"), totals, false).Pause);

    await using var computers = OtherComputersService.CProof(data);
    var header = new RemoteSessionHeader(computers, "fixture", "fixture-session", false, _ => { });
    header.CProofData(JsonSerializer.SerializeToElement(new
    {
      reading = new { model = new { value = "gpt-5", label = "GPT-5", choices = new[] { new { id = "gpt-5", name = "GPT-5" } } }, effort = new { value = "high", label = "High", choices = new[] { new { id = "high", name = "High" } } } }
    }), JsonSerializer.SerializeToElement(new { current = new { id = "personal", name = "Personal" }, accounts = new[] { new { id = "personal", name = "Personal" } } }));
    var remote = new Grid { VerticalAlignment = VerticalAlignment.Top }; remote.Children.Add(header);
    await Shot("remote-header", remote, 1000, 200, dark: true);
    Check("Remote header retains title and device name", Texts(header).Contains("Review the release") && Texts(header).Contains("Studio Mac"));
    Check("Remote header account has friendly name", Buttons(header).Contains("Personal"));
    Check("Remote header uses real offered model and effort labels", Buttons(header).Contains("GPT-5") && Buttons(header).Contains("High"));
    var refused = false;
    try { computers.RequireCapability("fixture", "sims"); } catch (InvalidOperationException ex) { refused = ex.Message.Contains("does not currently grant sims", StringComparison.Ordinal); }
    Check("Remote unsupported capability refuses at real service owner", refused);
    var subscriptionAllowed = true;
    computers.CloudServicesAllowed = () => subscriptionAllowed;
    subscriptionAllowed = false;
    refused = false;
    try { computers.RequireCapability("fixture", "controls"); } catch (InvalidOperationException ex) { refused = ex.Message == CloudRelayLifecycle.SubscriptionRequired; }
    Check("Remote stale supported action refuses after access loss", refused);
    subscriptionAllowed = true;

    foreach (var (paywall, state) in new[] { ("off", "none"), ("on", "none"), ("on", "gift"), ("on", "lapsed") })
    {
      var answer = new CloudSubscription(paywall, state, PaidUntil: state == "lapsed" ? 1_795_000_000_000 : null, Source: state == "gift" ? "gift" : null, Offer: true);
      var service = new ProofCloudService { Subscription = answer };
      using var account = new CloudAccountClient(CloudConfiguration.Today("Scratch PC", "0.23.0"), new CAccount(), service, new SystemCloudRandom(), new ProofBrowser());
      var start = await account.BeginSignInAsync();
      var query = start.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
      if (!await account.FinishAppReturnAsync(new Uri($"terminaldeck://cloud/return/{query["callback"]}?code=Q29kZUZyb21UaGVXZWJzaXRlX19fX19fX19fX19fX19&state={query["state"]}"))) throw new InvalidOperationException("The local payment fixture did not sign in.");
      var snapshot = account.Snapshot.Subscription;
      Check(paywall + "/" + state + " service answer projects the expected access", snapshot.ShowsSubscription == (paywall == "on" || state == "gift") && snapshot.AllowsCloudServices == (paywall == "off" || state == "gift"));
      var profile = new ProfilePage(account, _ => { });
      await Shot("profile-" + paywall + "-" + state, profile, 760, 900, background: "DeckRailBrush");
      Check(paywall + "/" + state + " Profile plan row follows service", Texts(profile).Contains(CloudSubscriptionPageText.Title) == (paywall == "on"));
      if (paywall == "on") await Shot("subscription-" + state, new CloudSubscriptionPage(account), 760, 620, dark: true, background: "DeckRailBrush");
      else
      {
        var specs = McpCatalogue.Load().Where(s => s.Id != CloudSubscriptionTools.Id).ToArray();
        Check("Paywall off preserves every existing catalogue tool", specs.All(s => CloudPaidInventory.ShowsTool(snapshot, s.Id)));
        Check("Paywall off hides subscription even when offer=true", !CloudPaidInventory.ShowsTool(snapshot, CloudSubscriptionTools.Id));
      }
    }
    // The real surface retains its child/model while removing controls on loss.
    var allowed = true; Action? changed = null;
    var content = new TextBox { Text = "Kept draft" };
    var access = new CloudAccessSurface(content, () => allowed, h => changed += h, h => changed -= h);
    await Shot("paid-surface-off", access, 760, 260);
    Check("Default/off wrapper leaves the original content visible", content.Visibility == Visibility.Visible);
    allowed = false; changed?.Invoke();
    await Shot("paid-surface-blocked", access, 760, 260);
    Check("Paid surface hides controls and retains the draft", content.Visibility == Visibility.Collapsed && content.Text == "Kept draft");
    allowed = true; changed?.Invoke(); await Task.Delay(100);
    Check("Access regain restores the same draft", content.Visibility == Visibility.Visible && content.Text == "Kept draft");
  }
  private static string[] Texts(FrameworkElement page) => WorkspaceVisuals.Tree(page).OfType<TextBlock>().Select(t => t.Text).ToArray();
  private static string[] Buttons(FrameworkElement page) => WorkspaceVisuals.Tree(page).OfType<Button>().Select(b => b.Content is string s ? s : b.Content is TextBlock t ? t.Text : "").ToArray();
  private sealed class CMemory<T> : IStateStore<T> where T : class
  {
    private T? value;
    public T? Load() => value;
    public void Save(T state) => value = state;
  }
  private sealed class CAccount : ICloudSecretStore
  {
    private byte[]? bytes;
    public bool Exists => bytes is not null;
    public byte[]? Read() => bytes?.ToArray();
    public void Write(ReadOnlySpan<byte> value) => bytes = value.ToArray();
    public void Remove() => bytes = null;
  }
  private sealed class CProjectFolders(string folder) : IProjectFolders
  {
    public string RequireFolder(string path) => ProjectPaths.Equal(folder, path) ? folder : throw new InvalidOperationException("Only the scratch project is available.");
    public IReadOnlyList<ProjectFolder> Browse(string path, bool showHidden) => [];
  }
}
