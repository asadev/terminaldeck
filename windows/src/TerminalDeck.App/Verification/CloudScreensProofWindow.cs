using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels.Agents;
using TerminalDeck.App.Views;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Verification;

/// The Cloud screens' picture proof (developer copies only: TD_DEV=1 and TD_CLOUD_SCREENS_PROOF=<a folder inside the
/// --user-data-dir>). It draws the real pages with LOCAL MADE-UP data, writes one PNG per page ("r6-<page>-<theme>.png")
/// and a `cloud-screens-proof.json` into that folder, then closes. No AppRuntime, no keeper, no account, no network:
/// the account is signed in against an in-memory stand-in of the service. Made-up names only (Studio Mac, Sam Rivera,
/// the Website and Mobile app projects).
/// Drawn as stand-ins (said in the JSON): the side panel's frame (its session and project rows are the real row
/// builders), the agent's right-click menu (a menu cannot be drawn off-screen: its items are drawn in a list beside the
/// real Agents page). Not drawn: Devices' reach switch and the GitHub page's code backup (both need the app's runtime).
internal sealed class CloudScreensProofWindow : Window
{
  private readonly Grid host = new();
  private readonly string output;
  private readonly AppDataRoot data;
  private readonly List<string> written = [], failed = [];

  internal CloudScreensProofWindow(AppDataRoot data, string output)
  {
    this.data = data; this.output = output;
    // The background is set per picture (Shot): the canvas, or the Settings window's grey.
    Content = host; AppWindow.Resize(new(1500, 1000)); AppWindow.Move(new(-20000, -20000));
    host.Loaded += async (_, _) =>
    {
      Directory.CreateDirectory(output);
      try { await RunAsync(); }
      catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(error.ToString()); }
      finally
      {
        await File.WriteAllTextAsync(Path.Combine(output, "cloud-screens-proof.json"), JsonSerializer.Serialize(new
        {
          at = DateTimeOffset.UtcNow, written, failed,
          standIns = new[] { "side panel frame: the real session and project row builders in a plain column", "agent menu: the real menu's items drawn as a list beside the real Agents page" },
          notDrawn = new[] { "Devices with the reach switch on and off: the page needs the app's runtime (reach coordinator)", "GitHub page code-backup line and its menu: needs the app's runtime (CodeBackupHolder)" }
        }, new JsonSerializerOptions { WriteIndented = true }));
        Close();
      }
    };
  }

  private async Task Shot(string name, FrameworkElement page, double width, double height, bool dark = false, int settle = 400, Func<Task>? ready = null, string background = "DeckCanvasBrush")
  {
    foreach (var theme in dark ? new[] { ElementTheme.Light, ElementTheme.Dark } : [ElementTheme.Light])
    {
      try
      {
        host.Children.Clear(); host.RequestedTheme = theme; host.Width = width; host.Height = height;
        if (page.Parent is Panel old) old.Children.Remove(page);
        host.Children.Add(page);
        await Task.Delay(settle); host.UpdateLayout();
        if (ready is not null) { await ready(); await Task.Delay(settle); host.UpdateLayout(); }
        // The window's own background for this page (Settings pages sit on the Settings window's grey, so their cards show).
        host.Background = (Brush)ShellTheme.Resource(host, background); host.UpdateLayout();
        var themeWord = theme == ElementTheme.Dark ? "dark" : "light";
        await W10Proof.CaptureAsync(host, output, "r9-" + name, themeWord, "Made-up local data; no account, no network", _ => { });
        written.Add("r9-" + name + "-" + themeWord + ".png");
      }
      catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(name + " " + theme + ": " + error.Message); }
    }
  }

  // One page at a time: a page whose set-up or drawing fails is written into the json with its error, and the proof goes on.
  private async Task Page(string name, Func<Task> draw)
  {
    try { await draw(); }
    catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(name + ": " + error); }
  }

  private ProjectService? projects;
  private ProjectService Projects()
  {
    if (projects is not null) return projects;
    var service = new ProjectService(new JsonStateStore<ProjectState>(data, "projects"), new LocalProjectFolders(data));
    // Made-up home folders sit NEXT TO the data folder: the app refuses a home folder inside its own data folder.
    var root = Path.Combine(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(data.DirectoryPath))!, "proof-projects");
    foreach (var name in new[] { "Website", "Mobile app" })
    {
      var folder = Path.Combine(root, name); Directory.CreateDirectory(folder);
      if (!service.List().Any(p => p.Name == name)) service.Create(name, folder);
    }
    return projects = service;
  }

  private async Task RunAsync()
  {
    // ---- the side panel* ----
    await Page("side-panel", () => Shot("side-panel", SidePanel(Projects()), 264, 560, dark: true));

    // ---- Your Cloud* ----
    YourCloudPage? cloud = null;
    YourCloudPage Cloud() => cloud ??= new YourCloudPage(Contents(withBin: true), () => { }, () => { }, _ => { });
    await Page("your-cloud-places", () => Shot("your-cloud-places", Cloud(), 1280, 760, dark: true, ready: Cloud().ProofReadAsync));
    await Page("your-cloud-folder-selected", () => Shot("your-cloud-folder-selected", Cloud(), 1280, 760, ready: () => { Cloud().ProofVisit("Memory", "Website"); Cloud().ProofSelect("Plan for the launch", "Design review"); return Task.CompletedTask; }));
    await Page("your-cloud-reading-pane", () => Shot("your-cloud-reading-pane", Cloud(), 1280, 760, settle: 800, ready: async () => { Cloud().ProofVisit("Memory", "Website"); Cloud().ProofSelect("Plan for the launch"); await Cloud().ProofOpenAsync("Plan for the launch"); }));
    await Page("your-cloud-not-on-this-pc", () => Shot("your-cloud-not-on-this-pc", Cloud(), 1280, 760, ready: () => { Cloud().ProofVisit("Memory", "Website"); Cloud().ProofSelect("Old pricing ideas"); return Task.CompletedTask; }));
    await Page("your-cloud-only-on-this-pc", () => Shot("your-cloud-only-on-this-pc", Cloud(), 1280, 760, ready: () => { Cloud().ProofVisit("Memory", "Website"); Cloud().ProofSelect("Kept notes"); return Task.CompletedTask; }));
    await Page("your-cloud-saved-passwords", () => Shot("your-cloud-saved-passwords", Cloud(), 1280, 760, ready: () => { Cloud().ProofVisit("Passwords"); return Task.CompletedTask; }));
    await Page("your-cloud-tasks", () => Shot("your-cloud-tasks", Cloud(), 1280, 760, dark: true, ready: () => { Cloud().ProofVisit("Tasks"); return Task.CompletedTask; }));

    // ---- the Bin* ----
    await Page("bin-empty", () =>
    {
      var emptyBin = new YourCloudPage(Contents(withBin: false), () => { }, () => { }, _ => { });
      return Shot("bin-empty", emptyBin, 1280, 560, dark: true, ready: async () => { await emptyBin.ProofReadAsync(); emptyBin.ProofVisit("Bin"); });
    });
    await Page("bin-six-lines", () =>
    {
      var bin = new YourCloudPage(Contents(withBin: true), () => { }, () => { }, _ => { });
      return Shot("bin-six-lines", bin, 1280, 560, dark: true, settle: 800, ready: async () =>
      {
        await bin.ProofReadAsync(); bin.ProofVisit("Bin"); await Task.Delay(800);
        if (WorkspaceVisuals.Tree(bin).OfType<CloudBinPage>().FirstOrDefault() is { } page && WorkspaceVisuals.Tree(page).OfType<ListView>().FirstOrDefault() is { Items.Count: > 1 } lines)
          ((ListViewItem)lines.Items[1]).IsSelected = true;
      });
    });

    // ---- an agent's menu (stand-in list beside the real page) ----
    await Page("agent-menu", async () =>
    {
      var projects = Projects();
      var agents = new AgentService(new JsonStateStore<AgentState>(data, "agents"), projects, new AgentInstructions(data));
      var website = projects.List().First(p => p.Name == "Website");
      if (!agents.List().Any(a => a.Id == "proof-lead")) agents.Save(new("proof-lead", "Lead", "claude", "Made-up agent for the picture.", ProjectId: website.Id, Seat: "project-lead"));
      if (!agents.List().Any(a => a.Id == "proof-review")) agents.Save(new("proof-review", "Reviewer", "codex", "Made-up agent for the picture.", ProjectId: website.Id));
      AgentsViewModel.BinDelete = () => (_, _) => { };
      using var model = new AgentsViewModel(agents, projects);
      var page = new AgentsPage(model, new ProofNavigation());
      var menu = page.AgentMenuForProof(agents.List().First(a => a.Id == "proof-review"));
      await Shot("agent-menu", MenuBeside(page, menu), 1280, 760);
    });

    // ---- the Cloud chat page of a session on another machine (read only) ----
    await Page("cloud-chat", async () =>
    {
      var machines = new Dictionary<string, CloudSessionsRead.Machine> { ["m-studio"] = new("m-studio", "Studio Mac", false, true, "macos"), ["m-air"] = new("m-air", "MacBook Air", true, true, "macos") };
      var rows = SidebarCloudRows.From([
        new("r-off", "s-off", "Fix the login page", 2, Kind: "chat", Machine: "m-studio"),
        new("r-on", "s-on", "Write the release notes", 1, Kind: "chat", Machine: "m-air")], machines, []);
      foreach (var row in rows)
      {
        var name = row.MachineOn ? "cloud-chat-machine-on" : "cloud-chat-machine-off";
        await Page(name, () => Shot(name, new CloudChatPage(row, () => ChatDoor), 900, 620, settle: 1200));
      }
    });

    // ---- Settings > Profile signed in*, the Cloud page, a device's page ----
    var service = new ProofCloudService();
    using var account = new CloudAccountClient(CloudConfiguration.Today("Office PC", "0.22.0.0"),
      new ProtectedCloudSecretStore(Path.Combine(data.DirectoryPath, "cloud", "account.protected"), new ProofProtector()), service, new SystemCloudRandom(), new ProofBrowser());
    var signedIn = false;
    await Page("made-up sign-in", async () =>
    {
      var url = await account.BeginSignInAsync();
      var query = url.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
      await account.FinishAppReturnAsync(new Uri($"terminaldeck://cloud/return/{query["callback"]}?code=Q29kZUZyb21UaGVXZWJzaXRlX19fX19fX19fX19fX19&state={query["state"]}"));
      signedIn = true;
    });
    if (!signedIn) { failed.Add("settings-profile, settings-cloud-manage-files, settings-device: skipped, the made-up sign-in failed"); return; }
    await Page("settings-profile", () => Shot("settings-profile", new ProfilePage(account, _ => { }), 760, 960, dark: true, settle: 800, background: "DeckRailBrush"));
    await Page("settings-cloud-manage-files", () => Shot("settings-cloud-manage-files", new CloudPage(account, null, () => { }), 760, 620, dark: true, settle: 800, background: "DeckRailBrush"));
    await Page("settings-personal", () => Shot("settings-personal", new PersonalPage(account), 760, 480, dark: true, settle: 800, background: "DeckRailBrush"));
    await Page("settings-sign-in", () => Shot("settings-sign-in", new SignInPage(account), 760, 620, dark: true, settle: 800, background: "DeckRailBrush"));
    await Page("settings-device", async () =>
    {
      if (account.Snapshot.DeviceRows.FirstOrDefault(d => !d.ThisDevice) is { } other)
        await Shot("settings-device", new DevicePage(account, other.DeviceId, _ => { }), 760, 520, dark: true, settle: 600, background: "DeckRailBrush");
      else failed.Add("settings-device: the made-up account shows no other device");
    });
  }

  // ---- the stand-ins ----

  /// The side panel's two sections drawn with the real row builders (project picture + name; session type icon + name,
  /// the orange dot when it needs him). Two chats, a terminal, a PowerShell, one on another machine, one that needs him.
  private static FrameworkElement SidePanel(ProjectService projects)
  {
    var panel = new StackPanel { Spacing = 2, Padding = new(12, 8, 12, 8) };
    panel.SetResourceReference(Panel.BackgroundProperty, "DeckRailBrush");
    TextBlock Caption(string text) { var c = new TextBlock { Text = text, Margin = new(8, 10, 0, 4), FontSize = 12 }; c.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); return c; }
    panel.Children.Add(Caption("Projects"));
    foreach (var project in projects.List().Where(p => p.Name is "Website" or "Mobile app"))
    {
      var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new(8, 6, 8, 6) };
      row.Children.Add(ProjectAgentUi.ProjectPicture(projects, project, 14));
      row.Children.Add(new TextBlock { Text = project.Name, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
      panel.Children.Add(row);
    }
    panel.Children.Add(Caption("Sessions"));
    var sessions = new (string Name, bool Chat, bool NeedsYou, bool Selected)[]
    {
      ("Plan the launch", true, false, true), ("Fix the login page", true, true, false), ("Build the website", false, false, false), ("PowerShell", false, false, false)
    };
    var other = SidebarCloudRows.From([new("r1", "s9", "Review the store listing", 1, Kind: "terminal", Machine: "m1")],
      new Dictionary<string, CloudSessionsRead.Machine> { ["m1"] = new("m1", "Studio Mac", true, true, "macos") }, []);
    foreach (var (name, chat, needs, selected) in sessions.Concat(other.Select(o => (o.Name, o.Chat, o.NeedsYou, false))))
    {
      var button = new Button { Content = ShellWindow.SidebarSimpleRow(SidebarRowLook.Glyph(chat), name, needs, selected), Height = 32, Padding = new(8, 0, 8, 0),
        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Style = (Style)Application.Current.Resources["DeckSidebarActionStyle"] };
      if (selected) button.SetResourceReference(Control.BackgroundProperty, "DeckSidebarSelectionBrush");
      panel.Children.Add(button);
    }
    return panel;
  }

  /// A menu cannot be drawn off-screen: the real menu's items, in order, in a plain list beside its owner.
  private static FrameworkElement MenuBeside(FrameworkElement owner, MenuFlyout menu)
  {
    var grid = new Grid();
    grid.Children.Add(owner);
    var items = new StackPanel { Spacing = 0, Padding = new(4) };
    foreach (var item in menu.Items)
    {
      if (item is MenuFlyoutSeparator) { var line = new Border { Height = 1, Margin = new(8, 4, 8, 4) }; line.SetResourceReference(Border.BackgroundProperty, "DeckDividerBrush"); items.Children.Add(line); continue; }
      if (item is MenuFlyoutItemBase { } named && (named as MenuFlyoutItem)?.Text is { } text) items.Children.Add(new TextBlock { Text = text, FontSize = 13, Padding = new(12, 6, 24, 6) });
      else if (item is MenuFlyoutSubItem sub) items.Children.Add(new TextBlock { Text = sub.Text + "  ›", FontSize = 13, Padding = new(12, 6, 24, 6) });
    }
    var card = new Border { Child = items, CornerRadius = new(8), BorderThickness = new(1), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new(0, 80, 40, 0), MinWidth = 220 };
    card.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush"); card.SetResourceReference(Border.BorderBrushProperty, "DeckDividerBrush");
    grid.Children.Add(card);
    return grid;
  }

  // ---- made-up Cloud contents ----

  private static CloudContents Contents(bool withBin)
  {
    var contents = new CloudContents(() => true, () => new(CloudDeleteBy.Person, "proof-pc", "Office PC", null, null, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), Guid.NewGuid().ToString()))
    {
      // A removal's place is a route (the project's id); the page names it ("12 notes in Website").
      PlaceNames = id => id switch { "p-website" => "Website", "p-mobile" => "Mobile app", _ => null }
    };
    var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    long Ago(double hours) => now - (long)(hours * 3_600_000);
    CloudContentsRow R(CloudContentsKind kind, string name, string[] folder, double hours, long? bytes = null, string? detail = null, bool secret = false) =>
      new(kind + ":" + name, kind, name, folder, Ago(hours), "Studio Mac", bytes, CloudItemState.InSync, detail, IsSecret: secret);
    var memory = new ProofSource(CloudContentsKind.Memory, [
      R(CloudContentsKind.Memory, "Plan for the launch", ["Website"], 1, 2_400), R(CloudContentsKind.Memory, "Design review", ["Website"], 2, 1_100),
      R(CloudContentsKind.Memory, "Old pricing ideas", ["Website"], 30, 800), R(CloudContentsKind.Memory, "Kept notes", ["Website"], 50, 600),
      R(CloudContentsKind.Memory, "Who does what", ["Website", "Lead"], 5, 900), R(CloudContentsKind.Memory, "Store screenshots", ["Mobile app"], 20, 3_000),
      R(CloudContentsKind.Memory, "Release checklist", ["Mobile app"], 26, 1_800)],
      marks: [("Memory:Old pricing ideas", CloudLocalMark.NotOnThisPc), ("Memory:Kept notes", CloudLocalMark.OnlyOnThisPc)],
      groups: withBin ? Groups(now) : []);
    contents.Register(memory);
    contents.Register(new ProofSource(CloudContentsKind.Projects, [R(CloudContentsKind.Projects, "Website", [], 3), R(CloudContentsKind.Projects, "Mobile app", [], 9)]));
    contents.Register(new ProofSource(CloudContentsKind.Agents, [R(CloudContentsKind.Agents, "Lead", ["Website"], 4), R(CloudContentsKind.Agents, "Reviewer", ["Website"], 8)], cloudOnly: false));
    contents.Register(new ProofSource(CloudContentsKind.Tasks, [
      R(CloudContentsKind.Tasks, "Write the launch post", [], 1, detail: "To do"), R(CloudContentsKind.Tasks, "Fix the login page", [], 3, detail: "In progress"),
      R(CloudContentsKind.Tasks, "Ship version 1.2", [], 30, detail: "Done")], cloudOnly: false));
    contents.Register(new ProofSource(CloudContentsKind.Settings, [
      R(CloudContentsKind.Settings, "Appearance", ["General"], 40, detail: "Dark"), R(CloudContentsKind.Settings, "Sounds", ["Notifications"], 60, detail: "On"),
      R(CloudContentsKind.Settings, "Reopen sessions after a restart", ["General"], 70, detail: "On")], removals: false));
    contents.Register(new ProofSource(CloudContentsKind.Passwords, [
      R(CloudContentsKind.Passwords, "github.com · sam.rivera", [], 12, secret: true), R(CloudContentsKind.Passwords, "store.example.com · sam", [], 48, secret: true),
      R(CloudContentsKind.Passwords, "Mobile app .env", [], 72, secret: true)]));
    // C-6: every place has something to show.
    contents.Register(new ProofSource(CloudContentsKind.InstructionFiles, [
      R(CloudContentsKind.InstructionFiles, "CLAUDE.md", ["Website"], 6, 3_200), R(CloudContentsKind.InstructionFiles, "AGENTS.md", ["Mobile app"], 30, 1_400)]));
    contents.Register(new ProofSource(CloudContentsKind.Artifacts, [
      R(CloudContentsKind.Artifacts, "Launch checklist.html", [], 4, 18_000), R(CloudContentsKind.Artifacts, "Pricing table.html", [], 28, 9_500)]));
    contents.Register(new ProofSource(CloudContentsKind.CloudFolder, [
      R(CloudContentsKind.CloudFolder, "Logo.svg", ["Designs"], 10, 12_000), R(CloudContentsKind.CloudFolder, "Brand colours.pdf", ["Designs"], 34, 220_000),
      R(CloudContentsKind.CloudFolder, "Interview notes.txt", [], 52, 4_100)]));
    contents.Register(new ProofSource(CloudContentsKind.Sessions, [
      R(CloudContentsKind.Sessions, "Fix the login page", ["Website"], 1), R(CloudContentsKind.Sessions, "Write the release notes", ["Mobile app"], 3),
      R(CloudContentsKind.Sessions, "Plan the launch", ["Website"], 24)], cloudOnly: false));
    return contents;
  }

  private static IReadOnlyList<CloudBinGroup> Groups(long now)
  {
    CloudDeleteItem Note(string name, string place = "p-website") => new("bin:" + place + ":" + name, "memory", name, place);
    CloudBinGroup G(string id, CloudDeleteBy by, string device, double hours, params CloudDeleteItem[] items) => new(id, by, device, null, null, now - (long)(hours * 3_600_000), items);
    return [
      G("g1", CloudDeleteBy.Person, "Studio Mac", 2, Note("Old landing copy")),
      G("g2", CloudDeleteBy.Ai, "MacBook Air", 5, Note("Draft FAQ")),
      G("g3", CloudDeleteBy.Person, "Studio Mac", 26, [.. Enumerable.Range(1, 12).Select(i => Note("Note " + i))]),
      G("g4", CloudDeleteBy.Person, "Office PC", 50, Note("Store screenshots v1", "p-mobile")),
      G("g5", CloudDeleteBy.Ai, "Studio Mac", 80, Note("Test plan", "p-mobile")),
      G("g6", CloudDeleteBy.Person, "MacBook Air", 200, Note("Pricing table"))
    ];
  }

  private sealed class ProofSource(CloudContentsKind kind, IReadOnlyList<CloudContentsRow> rows, (string Id, CloudLocalMark Mark)[]? marks = null,
    IReadOnlyList<CloudBinGroup>? groups = null, bool cloudOnly = true, bool removals = true) : ICloudContentsSource
  {
    private readonly ProofRemovals? owner = removals ? new(rows, marks ?? [], groups ?? []) : null;
    public CloudContentsKind Kind => kind;
    public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel) => Task.FromResult(rows);
    public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult<CloudOpenedItem?>(row.IsSecret
      ? new(row.Name, row.ChangedAt, null, null, null, null, IsSecret: true)
      : new(row.Name, row.ChangedAt, "## " + row.Name + "\n\nLaunch on **Monday**. Sam writes the post; the Lead checks the store copy.\n\n- Website goes live first\n- Mobile app follows on Wednesday\n- Every note stays in sync on Studio Mac, MacBook Air and Office PC",
        null, null, null));
    public ICloudDeleteOwning? Removals => owner;
    public bool OffersCloudOnly => cloudOnly;
    public CloudDeleteItem DeleteItem(CloudContentsRow row) => new(row.Id, kind.ToString(), row.Name);
  }

  private sealed class ProofRemovals(IReadOnlyList<CloudContentsRow> rows, (string Id, CloudLocalMark Mark)[] marks, IReadOnlyList<CloudBinGroup> groups) : ICloudDeleteOwning
  {
    public Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by) => throw new NotSupportedException("The picture proof changes nothing.");
    public Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to) => Task.FromResult<IReadOnlyList<CloudDeleteItem>>([]);
    public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Task.FromResult<IReadOnlyList<CloudNotHereItem>>(marks
      .Select(m => rows.FirstOrDefault(r => r.Id == m.Id) is { } row ? new CloudNotHereItem(new(row.Id, row.Kind.ToString(), row.Name), m.Mark, row.ChangedAt) : null).OfType<CloudNotHereItem>().ToArray());
    public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() => Task.FromResult(groups);
    public Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group) => Task.FromResult<IReadOnlyList<CloudDeleteItem>>([]);
    public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items) => Task.CompletedTask;
  }

  // ---- the Cloud chat page's door: a made-up readable copy ----

  private static readonly CloudChatsSend ChatDoor = (method, path, body) =>
  {
    var lines = new (string Kind, string Text)[]
    {
      ("user", "Add a test for the login page"),
      ("message", "I added LoginPageTests with three cases: a good password, a wrong one, and an empty field."),
      ("user", "Now run it"),
      ("message", "All three pass. The empty field now shows \"Enter your password\" instead of a blank error.")
    };
    var events = lines.Select((l, i) => new { version = 1, id = "c:" + (i + 1), conversationId = "c", turnId = "", sequence = i + 1, provider = "claude", kind = l.Kind, messageId = "m" + i, value = new { text = l.Text }, at = 1_763_000_000_000L + i * 60_000 });
    return Task.FromResult(new CloudChatsAnswer(200, JsonSerializer.SerializeToUtf8Bytes(new { gen = 1, total = 4, first = 0, count = 4, events })));
  };

  private sealed class ProofNavigation : IProjectsAgentsNavigation
  {
    public nint WindowHandle => 0;
    public void OpenSession(string id) { }
    public void OpenProject(string id) { }
    public void OpenAgent(string id) { }
  }

  // ---- an in-memory stand-in of the account service: sign-in, this PC and two other devices by friendly name ----

  private sealed class ProofCloudService : ICloudHttp
  {
    private CloudDeviceRegistration? registered;
    private readonly (CloudDeviceRegistration Device, string Name)[] others =
      [(CloudDeviceKeys.Fresh().Registration("sams-studio-mac", "0.22.0", "macos"), "Studio Mac"), (CloudDeviceKeys.Fresh().Registration("sams-air", "0.22.0", "macos"), "MacBook Air")];

    public Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct)
    {
      var path = request.Url.AbsolutePath;
      CloudHttpResponse Ok(object body, int status = 200) => new(status, JsonSerializer.SerializeToUtf8Bytes(body));
      if (path.EndsWith("/exchange", StringComparison.Ordinal))
        return Task.FromResult(Ok(new { accessToken = Jwt(), refreshToken = "made-up", expiresAt = DateTimeOffset.UtcNow.AddMinutes(60).ToUnixTimeMilliseconds(),
          user = new { id = UserId, displayName = "Sam Rivera", email = "sam@example.com", provider = "google" }, capabilities = new { features = new[] { "cloud" }, storageEntitled = true } }));
      if (path == "/profile/v1/me") return Task.FromResult(Ok(new { name = "Sam Rivera", email = "sam@example.com", username = "sam", usernameCanChange = true, waysToSignIn = new[] {
        new { id = "google", provider = "google", providerName = "Google", account = "sam@example.com", canRemove = true, connectedSince = "2026-11-01T00:00:00Z" },
        new { id = "github", provider = "github", providerName = "GitHub", account = "samrivera", canRemove = true, connectedSince = "2026-11-03T00:00:00Z" }
      }, addable = new[] { "apple" } }));
      if (path == "/settings") return Task.FromResult(Ok(new { external = new { github = true, google = true, apple = true } }));
      if (path == "/v1/capabilities") return Task.FromResult(Ok(new { features = new[] { "cloud" }, storageEntitled = true, session = "valid" }));
      if (path == "/v1/devices" && request.Method == HttpMethod.Post)
      {
        registered = JsonSerializer.Deserialize<CloudDeviceRegistration>(request.Body, CloudWire.Json);
        return Task.FromResult(Ok(new { deviceId = registered!.DeviceId, status = "active", secretsApproved = false, headSeq = "0", vaultState = "unset" }, 201));
      }
      if (path == "/v1/devices" && registered is { } mine)
      {
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var all = new List<object> { new { mine.DeviceId, mine.Label, mine.Platform, mine.AppVersion, status = "active", secretsApproved = false, lastSeenAt = now, registeredAt = now - 86_400_000L * 3, mine.SignPublicJwk, mine.WrapPublicJwk, displayName = "Office PC" } };
        var at = 0;
        foreach (var (other, name) in others)
          all.Add(new { other.DeviceId, other.Label, other.Platform, other.AppVersion, status = "active", secretsApproved = false, lastSeenAt = now - 600_000L * ++at, registeredAt = now - 86_400_000L * 30 * at, other.SignPublicJwk, other.WrapPublicJwk, displayName = name });
        return Task.FromResult(Ok(new { devices = all }));
      }
      if (path == "/v1/state") return Task.FromResult(Ok(new { headSeq = "0", devicesVersion = "1", vaultState = "unset", vaultEpoch = "0", vaultVersion = "1" }));
      return Task.FromResult(new CloudHttpResponse(404, []));
    }

    private const string UserId = "5b8e2f10-0c4d-4e2a-9d6b-1a2b3c4d5e6f";
    private static string Jwt()
    {
      var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
      var claims = JsonSerializer.SerializeToUtf8Bytes(new { iss = CloudWire.Issuer, sub = UserId, role = "authenticated", aud = "authenticated", exp = now + 3600, iat = now, session_id = Guid.NewGuid().ToString() });
      return CloudWire.Base64Url("{\"alg\":\"ES256\"}"u8) + "." + CloudWire.Base64Url(claims) + ".bWFkZS11cA";
    }
  }

  private sealed class ProofProtector : IDataProtector
  {
    public byte[] Protect(ReadOnlySpan<byte> plaintext) => [1, .. plaintext.ToArray().Select(b => (byte)(b ^ 0x5A))];
    public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => ciphertext[1..].ToArray().Select(b => (byte)(b ^ 0x5A)).ToArray();
  }

  private sealed class ProofBrowser : ICloudBrowser { public Task OpenAsync(Uri url, CancellationToken ct) => Task.CompletedTask; }
}
