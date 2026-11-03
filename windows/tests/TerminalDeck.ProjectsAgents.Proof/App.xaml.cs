using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Agents;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Projects;
using Windows.Graphics.Imaging;
using Windows.Graphics;
using Windows.Storage.Streams;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;

namespace TerminalDeck.ProjectsAgents.Proof;

public partial class App : Application
{
  private Window? window;
  private static Grid? renderRoot;
  public App() => InitializeComponent();
  protected override void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray());
    if (!root.DirectoryPath.StartsWith(@"C:\TD\projects-agents-proof\", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Use a new projects-agents proof root.");
    Directory.CreateDirectory(root.DirectoryPath);
    window = new Window { Title = "Projects and agents · isolated preview" };
    var host = new Grid { RequestedTheme = ElementTheme.Light, Style = ProjectAgentUi.PageStyle() };
    host.RowDefinitions.Add(new() { Height = GridLength.Auto }); host.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    host.Children.Add(new TextBlock { Text = "SAMPLE DATA · isolated Windows preview", Margin = new Thickness(32, 10, 32, 0), FontSize = 12, Opacity = 0.6 });
    var content = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch }; Grid.SetRow(content, 1); host.Children.Add(content);
    window.Content = host; renderRoot = host;
    if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1")
    {
      window.AppWindow.MoveAndResize(new RectInt32(-20000, -20000, 1240, 1000)); window.AppWindow.Show(false);
    }
    else { window.Activate(); window.AppWindow.MoveAndResize(new RectInt32(40, 20, 1240, 1000)); }
    UnhandledException += (_, e) =>
    {
      e.Handled = true; var output = Path.Combine(root.DirectoryPath, "proof"); Directory.CreateDirectory(output);
      var frames = new System.Diagnostics.StackTrace(e.Exception, true).GetFrames().Where(f => f.GetMethod()?.DeclaringType?.Namespace?.StartsWith("TerminalDeck", StringComparison.Ordinal) == true).Select(f => new { method = f.GetMethod()?.DeclaringType?.Name + "." + f.GetMethod()?.Name, line = f.GetFileLineNumber() });
      File.WriteAllText(Path.Combine(output, "unhandled.json"), JsonSerializer.Serialize(new { type = e.Exception.GetType().Name, code = e.Exception.HResult.ToString("X8"), frames }));
      File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { passed = 0, failed = 1, checksFailed = new[] { "The isolated window raised an unhandled UI error." } }));
      window.Close();
    };
    host.DispatcherQueue.TryEnqueue(async () => await RunAsync(root, window, host, content));
  }
  private static async Task RunAsync(AppDataRoot root, Window window, Grid host, ContentControl content)
  {
    var output = Path.Combine(root.DirectoryPath, "proof"); Directory.CreateDirectory(output);
    var passed = new List<string>(); var failed = new List<string>();
    var onlyCheck = Environment.GetEnvironmentVariable("TD_W6_ONLY_CHECK");
    void Check(string name, Func<bool> condition)
    {
      if (string.IsNullOrEmpty(onlyCheck) || onlyCheck == name) (condition() ? passed : failed).Add(name);
    }
    try
    {
      var home = Path.Combine(root.DirectoryPath, "fixtures", "Aurora"); var other = Path.Combine(root.DirectoryPath, "fixtures", "Field notes");
      Directory.CreateDirectory(home); Directory.CreateDirectory(other);
      // Project home folders are outside the app's own data root even in this fixture.
      var data = AppDataRoot.Explicit(Path.Combine(root.DirectoryPath, "app-data"));
      var projects = new ProjectService(new JsonStateStore<ProjectState>(data, "projects"), new LocalProjectFolders(data), new WindowsProjectPictures(data));
      projects.Save(new("aurora", "Aurora", [home])); projects.Save(new("field-notes", "Field notes", [other], Colour: "teal"));
      projects.PatchSettings("aurora", new Dictionary<string, JsonElement> { ["about"] = JsonSerializer.SerializeToElement("A small app with clear goals, focused roles and review before release.") });
      projects.PatchSettings("field-notes", new Dictionary<string, JsonElement> { ["about"] = JsonSerializer.SerializeToElement("Research, drafts and ideas that need a little room.") });
      var source = Path.Combine(root.DirectoryPath, "sample-logo.png"); await SamplePictureAsync(source); projects.SetPicture("aurora", source);
      var iconPng = Path.Combine(other, "logo.png"); await SamplePictureAsync(iconPng, 64, 64);
      var icon = Path.Combine(root.DirectoryPath, "project-icon.ico"); var iconPixels = await File.ReadAllBytesAsync(iconPng);
      using (var file = File.Create(icon)) using (var writer = new BinaryWriter(file))
      {
        writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)1); writer.Write((byte)64); writer.Write((byte)64); writer.Write((byte)0); writer.Write((byte)0);
        writer.Write((ushort)1); writer.Write((ushort)32); writer.Write((uint)iconPixels.Length); writer.Write((uint)22); writer.Write(iconPixels);
      }
      projects.SetPicture("field-notes", icon);

      var accounts = new AccountService(new JsonStateStore<AccountState>(data, "accounts"), new[] { new ExampleProvider("codex"), new ExampleProvider("claude"), new ExampleProvider("gemini") });
      foreach (var provider in new[] { "codex", "claude", "gemini" }) { var a = await accounts.CreateAsync(provider, "Example account"); await accounts.RefreshAsync(a.Id); await accounts.SetDefaultAsync(provider, a.Id); }
      projects.SetWhoUsesWhat("aurora", [new("sessions", "codex", accounts.List("codex")[0].Id), new("chats", "claude", accounts.List("claude")[0].Id)]);
      var plans = new List<AgentLaunchPlan>();
      var agents = new AgentService(new JsonStateStore<AgentState>(data, "agents"), projects, new AgentInstructions(data), accounts,
        new DelegateAgentSessionGateway((plan, ct) => { plans.Add(plan); return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode)); }));
      var lead = agents.Hire("Project lead", "codex", "Keeps the project moving, gives each role a clear job and reviews the result.", AgentCategory.Lead, "aurora", "project-lead", AgentSeats.HootId);
      var reviewer = agents.Hire("Reviewer", "claude", "Checks changes against the brief, looks for failure paths and keeps the review easy to act on.", AgentCategory.Agent, "aurora", "reviewer", lead.Id);
      reviewer = agents.Save(reviewer with { Model = "AI default", Effort = "high", Skills = ["review"] });
      agents.SaveInstructions(reviewer.Id, "Read the brief and the change. Explain each finding in plain words and include the evidence.");
      agents.SaveSeatMemory("role:aurora/reviewer", "Check the smallest useful change first. Keep findings specific.", "");
      agents.SaveSeatMemory("lead:aurora", "Make the project easy for a stranger to use. Review evidence before release.", "");
      var work = await agents.StartAsync(new(reviewer.Id, Mode: "chat", Job: "Review the settings page"));
      var plain = await agents.StartAsync(new(null, "aurora", Provider: "codex", Job: "Explore the next idea"));
      var rows = new List<ProjectSession>
      {
        new(work.SessionId, "Review the settings page", "claude", home, "Sample", "aurora", reviewer.Id, "chat"),
        new(plain.SessionId, "Explore the next idea", "codex", home, "Sample", "aurora")
      };
      using var projectsModel = new ProjectsViewModel(projects, agents, () => rows, accounts);
      using var agentsModel = new AgentsViewModel(agents, projects, accounts);
      var nav = new Navigation(window, content); var projectsPage = new ProjectsPage(projectsModel, nav); var agentsPage = new AgentsPage(agentsModel, nav); nav.Projects = projectsPage; nav.Agents = agentsPage;
      content.Content = projectsPage;
      await Task.Delay(300); window.AppWindow.Resize(new SizeInt32(1040, 780));
      await SnapshotAsync(output, "01-projects-light");
      var projectsRenderedWidth = projectsPage.ActualWidth;
      await File.WriteAllTextAsync(Path.Combine(output, "initial-frame-metrics.json"), JsonSerializer.Serialize(new { appWidth = window.AppWindow.Size.Width, appHeight = window.AppWindow.Size.Height, appX = window.AppWindow.Position.X, appY = window.AppWindow.Position.Y, hostWidth = host.ActualWidth, hostHeight = host.ActualHeight, pageWidth = projectsPage.ActualWidth, rasterScale = host.XamlRoot.RasterizationScale }));
      if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1")
      {
        await W12Async(output, window, host, content, projectsPage, agentsPage, projectsModel, agentsModel, reviewer, Check);
        await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { timestamp = DateTimeOffset.UtcNow, passed = passed.Count, failed = failed.Count, checksPassed = passed, checksFailed = failed }));
        window.Close(); return;
      }
      projectsPage.OpenProject("aurora", "Settings"); await SnapshotAsync(output, "02-project-settings-light");
      content.Content = agentsPage; agentsPage.OpenAgent(reviewer.Id); await SnapshotAsync(output, "03-agent-light");
      var agentsRenderedWidth = agentsPage.ActualWidth;
      host.RequestedTheme = ElementTheme.Dark; await SnapshotAsync(output, "04-agent-dark");
      projectsModel.SelectedId = null; content.Content = projectsPage; await SnapshotAsync(output, "05-projects-dark");
      using var pickerCancellation = new CancellationTokenSource();
      var picker = NewSessionPicker.ShowAsync(host.XamlRoot, agents, projects, accounts, nav, "aurora", cancellationToken: pickerCancellation.Token);
      await SnapshotAsync(output, "06-new-session-picker");
      pickerCancellation.Cancel();
      await picker.WaitAsync(TimeSpan.FromSeconds(30));
      Check("One project group contains both sample sessions", () => projectsModel.Groups.Single(g => g.ProjectId == "aurora").Sessions.Length == 2);
      Check("No agent shows only Codex even with a project lead", () => agents.SessionLabel(plain.SessionId, "codex") == "Codex" && agents.SessionFace(plain.SessionId) is null);
      Check("Saved agent face stays with its own chat", () => agents.SessionFace(work.SessionId)?.Id == reviewer.Id);
      Check("Agent profile has its manager and role", () => agents.Get(reviewer.Id).ReportsTo == lead.Id && agents.SeatOf(reviewer.Id).Key == "role:aurora/reviewer");
      Check("Instructions and model reached the session interface", () => plans[0].Instructions.Contains("Explain each finding", StringComparison.Ordinal) && plans[0].Effort == "high");
      Check("Page model counts use the same project filters", () => projectsModel.SessionsFor("aurora").Count == 2 && projectsModel.AgentsFor("aurora").Count == 2);
      Check("Both page classes rendered at a real window size", () => projectsRenderedWidth > 600 && agentsRenderedWidth > 600);
      Check("Dark theme applied", () => host.ActualTheme == ElementTheme.Dark);
      var scroll = (ScrollViewer)projectsPage.Children[0]; var body = (StackPanel)scroll.Content;
      Check("Page content fits the window width", () => body.ActualWidth + body.Margin.Left + body.Margin.Right <= scroll.ActualWidth + 1);
      await File.WriteAllTextAsync(Path.Combine(output, "frame-metrics.json"), JsonSerializer.Serialize(new { appWidth = window.AppWindow.Size.Width, appHeight = window.AppWindow.Size.Height, hostWidth = host.ActualWidth, hostHeight = host.ActualHeight, pageWidth = projectsPage.ActualWidth, bodyWidth = body.ActualWidth, scrollWidth = scroll.ActualWidth, rasterScale = host.XamlRoot.RasterizationScale }));
      using var imageStream = new InMemoryRandomAccessStream(); var bytes = await File.ReadAllBytesAsync(projects.PicturePath("aurora")!);
      using (var writer = new DataWriter(imageStream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); writer.DetachStream(); }
      var decoder = await BitmapDecoder.CreateAsync(imageStream);
      Check("Picture is a normalized PNG no larger than 256 pixels", () => decoder.DecoderInformation.CodecId == BitmapDecoder.PngDecoderId && Math.Max(decoder.PixelWidth, decoder.PixelHeight) <= 256);
      Check("Settings survived reload in the scratch data root", () => new ProjectService(new JsonStateStore<ProjectState>(data, "projects"), new LocalProjectFolders(data)).Get("aurora").Preferences.WhoUsesWhat.Length == 2);
      if (passed.Count + failed.Count == 0) failed.Add("The requested check name was not found.");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      var cause = ex is AggregateException aggregate ? aggregate.Flatten().InnerExceptions[0] : ex;
      failed.Add("Preview stopped: " + cause.GetType().Name + " 0x" + cause.HResult.ToString("X8") + " " + cause.Message);
      var frames = new System.Diagnostics.StackTrace(cause, true).GetFrames().Where(f => f.GetMethod()?.DeclaringType?.Namespace?.StartsWith("TerminalDeck", StringComparison.Ordinal) == true).Select(f => new { method = f.GetMethod()?.DeclaringType?.Name + "." + f.GetMethod()?.Name, line = f.GetFileLineNumber() });
      await File.WriteAllTextAsync(Path.Combine(output, "failure-location.json"), JsonSerializer.Serialize(frames));
    }
    await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { timestamp = DateTimeOffset.UtcNow, passed = passed.Count, failed = failed.Count, checksPassed = passed, checksFailed = failed }));
  }
  private static async Task Until(Func<bool> ready)
  {
    var end = DateTimeOffset.UtcNow.AddSeconds(10); while (!ready()) { if (DateTimeOffset.UtcNow > end) throw new TimeoutException("The fixture action did not finish."); await Task.Delay(100); }
  }
  private static IEnumerable<DependencyObject> Tree(DependencyObject node)
  { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child; }
  private static void Click(DependencyObject root, string label)
  {
    var button = Tree(root).OfType<Microsoft.UI.Xaml.Controls.Primitives.ButtonBase>().Single(b => b.Content as string == label || AutomationProperties.GetName(b) == label || b.Name == label);
    var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button);
    if (peer?.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) invoke.Invoke();
    else if (peer?.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle) toggle.Toggle();
    else throw new InvalidOperationException("No action for " + label);
  }
  private static void InvokeMenu(MenuFlyout menu, string text)
  {
    var item = menu.Items.OfType<MenuFlyoutItem>().Single(i => i.Text == text);
    ((IInvokeProvider)FrameworkElementAutomationPeer.CreatePeerForElement(item).GetPattern(PatternInterface.Invoke)).Invoke();
  }
  private static async Task W12Async(string output, Window window, Grid host, ContentControl content, ProjectsPage projectsPage, AgentsPage agentsPage,
    ProjectsViewModel projectsModel, AgentsViewModel agentsModel, SavedAgent reviewer, Action<string, Func<bool>> check)
  {
    content.Content = projectsPage; projectsPage.OpenProject("field-notes"); await SnapshotAsync(output, "w12-project-setup-links-light");
    check("Each missing project part has its own destination", () => projectsModel.SetupFor("field-notes").Missing.All(m => Tree(projectsPage).OfType<Button>().Any(b => b.Content as string == m)));
    var projectEditing = projectsPage.ShowSettingsAsync("field-notes"); await Task.Delay(250); var projectWindow = ProjectSettingsWindow.Find(projectsModel.Projects, "field-notes")!;
    var sameProjectEditing = projectsPage.ShowSettingsAsync("field-notes"); check("One native settings window per project", () => ReferenceEquals(projectWindow, ProjectSettingsWindow.Find(projectsModel.Projects, "field-notes")) && projectWindow.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { IsResizable: true });
    var projectName = Tree(projectWindow.Content).OfType<TextBox>().Single(t => t.Header as string == "Name"); projectName.Text = "First name"; projectName.Text = "Final name";
    await Until(() => projectsModel.Projects.Get("field-notes").Name == "Final name"); check("Project name autosaves the last edit", () => projectsModel.Projects.Get("field-notes").Name == "Final name");
    projectName.Text = "Local draft"; var beforeRename = projectsModel.Projects.Get("field-notes"); projectsModel.Projects.Save(new(beforeRename.Id, "Outside name", beforeRename.Folders));
    await Until(() => Tree(projectWindow.Content).OfType<Button>().Any(b => b.Content as string == "Keep mine" && b.Parent is FrameworkElement { Visibility: Visibility.Visible }));
    check("Outside project rename retains the unsaved draft", () => projectName.Text == "Local draft" && projectsModel.Projects.Get("field-notes").Name == "Outside name");
    await SnapshotAsync(output, "w12-project-name-controls-light", Tree(projectWindow.Content).OfType<FrameworkElement>().Single(e => AutomationProperties.GetAutomationId(e) == "projects.name-controls"));
    await SnapshotAsync(output, "w12-project-name-conflict-light", (FrameworkElement)projectWindow.Content); Click(projectWindow.Content, "Keep mine"); await Until(() => projectsModel.Projects.Get("field-notes").Name == "Local draft");
    check("ICO project logos are adopted as owned images", () => projectsModel.Projects.PicturePath("field-notes") is { } path && path.EndsWith(".png", StringComparison.OrdinalIgnoreCase) && File.Exists(path));
    var projectScroll = Tree(projectWindow.Content).OfType<ScrollViewer>().First(); projectScroll.ChangeView(null, 240, null, true); await Task.Delay(200);
    await Until(() => Tree(projectWindow.Content).OfType<Button>().Any(b => b.Content as string == "logo.png"));
    var previousLogo = projectsModel.Projects.Get("field-notes").Logo; Click(projectWindow.Content, "logo.png"); await Until(() => projectsModel.Projects.Get("field-notes").Logo != previousLogo);
    check("Found-in-folder suggestion saves a copied logo", () => projectsModel.Projects.PicturePath("field-notes") is { } path && path != Path.Combine(projectsModel.Projects.Get("field-notes").HomeFolder!, "logo.png") && File.Exists(path));
    await SnapshotAsync(output, "w12-project-settings-light", (FrameworkElement)projectWindow.Content); Click(projectWindow.Content, "Done"); await Task.WhenAll(projectEditing, sameProjectEditing).WaitAsync(TimeSpan.FromSeconds(10));

    var setup = projectsPage.ShowSetupAsync("field-notes", step: "folders"); await Task.Delay(250);
    var dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single();
    check("Setup has structured other-folder controls", () => Tree(dialog).OfType<Button>().Any(b => b.Content as string == "Add a folder…"));
    await SnapshotAsync(output, "w12-project-folders-light", dialog); dialog.Hide(); await setup;
    content.Content = agentsPage; agentsPage.OpenAgent(reviewer.Id); await SnapshotAsync(output, "w12-agent-profile-light");
    check("Agent has Skills tab", () => Tree(agentsPage).OfType<Microsoft.UI.Xaml.Controls.Primitives.ButtonBase>().Any(b => AutomationProperties.GetName(b) == "Skills view"));
    Click(agentsPage, "Skills view"); await SnapshotAsync(output, "w12-agent-skills-light");
    check("Skill controls are reachable", () => Tree(agentsPage).OfType<Button>().Any(b => b.Content as string == "Give more"));
    host.RequestedTheme = ElementTheme.Dark; await SnapshotAsync(output, "w12-agent-skills-dark");
    var editing = AgentEditors.EditAsync(host.XamlRoot, agentsModel.Agents.Get(reviewer.Id), agentsModel.Agents, agentsModel.Projects, agentsModel, "description");
    await Task.Delay(300); var settings = AgentEditorWindow.Find(agentsModel.Agents, reviewer.Id)!;
    check("Agent settings opens its own resizable window", () => settings is not null && !ReferenceEquals(settings, window) && settings.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { IsResizable: true });
    await AgentEditors.EditAsync(host.XamlRoot, agentsModel.Agents.Get(reviewer.Id), agentsModel.Agents, agentsModel.Projects, agentsModel, "model");
    check("All field links focus the same agent editor", () => ReferenceEquals(settings, AgentEditorWindow.Find(agentsModel.Agents, reviewer.Id)));
    await SnapshotAsync(output, "w12-agent-settings-dark", (FrameworkElement)settings.Content);
    var settingsScroll = Tree(settings.Content).OfType<ScrollViewer>().First(); settingsScroll.ChangeView(null, settingsScroll.ScrollableHeight, null, true); await Task.Delay(250);
    check("Agent limits offer No limit by default", () => Tree(settings.Content).OfType<ComboBox>().Any(c => c.Header as string == "Tasks at once" && c.SelectedValue as string == "none"));
    await SnapshotAsync(output, "w12-agent-limits-dark", (FrameworkElement)settings.Content);
    Click(settings.Content, "Save"); await editing.WaitAsync(TimeSpan.FromSeconds(10));
    var instructions = AgentEditors.InstructionsAsync(host.XamlRoot, agentsModel.Agents.Get(reviewer.Id), agentsModel.Agents, agentsModel); await Task.Delay(300);
    var instructionDialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single();
    var instructionText = Tree(instructionDialog).OfType<TextBox>().Single(t => t.Header as string == "Instructions for this agent"); instructionText.Text = "Unsaved editor draft";
    File.WriteAllText(agentsModel.Agents.Get(reviewer.Id).InstructionsFile!, "Changed on disk during editing"); Click(instructionDialog, "PrimaryButton"); await Task.Delay(300);
    check("External instruction edit produces a visible conflict", () => Tree(instructionDialog).OfType<InfoBar>().Any(b => b.IsOpen) && instructionText.Text == "Unsaved editor draft");
    await SnapshotAsync(output, "w12-instruction-conflict-dark", instructionDialog);
    Click(instructionDialog, "Use file"); await Task.Delay(300);
    check("Use file loads the changed contents", () => instructionText.Text == "Changed on disk during editing");
    instructionDialog.Hide(); await instructions;
    var templates = AgentEditors.TemplatesAsync(host.XamlRoot, agentsModel.Agents, agentsModel); await Task.Delay(250);
    var templateDialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single();
    var shared = Tree(templateDialog).OfType<TextBox>().Single(t => t.Header as string == "Shared instructions"); shared.Text = "Saved category instructions";
    Click(templateDialog, "Save for category"); await Task.Delay(250);
    check("Save for category persists the selected template", () => agentsModel.Agents.Templates().Single(t => t.Category == AgentCategory.Agent).Instructions == "Saved category instructions");
    shared.Text = "Unsaved category draft";
    var templateCategory = Tree(templateDialog).OfType<ComboBox>().Single(c => c.Header as string == "Category"); templateCategory.SelectedValue = "Lead"; shared.Text = "Unsaved lead draft"; templateCategory.SelectedValue = "Agent";
    check("Category switches keep drafts without saving the other category", () => shared.Text == "Unsaved category draft" && agentsModel.Agents.Templates().Single(t => t.Category == AgentCategory.Lead).Instructions != "Unsaved lead draft");
    Click(templateDialog, "PrimaryButton"); await Task.Delay(200);
    check("Template close offers explicit discard choices", () => Tree(templateDialog).OfType<Button>().Any(b => b.Content as string == "Close Without Saving" && b.Parent is FrameworkElement { Visibility: Visibility.Visible }));
    await SnapshotAsync(output, "w12-template-discard-dark", templateDialog);
    Click(templateDialog, "Keep Editing"); Click(templateDialog, "Revert"); templateCategory.SelectedValue = "Lead"; Click(templateDialog, "Revert"); templateCategory.SelectedValue = "Agent";
    Click(templateDialog, "PrimaryButton"); await templates.WaitAsync(TimeSpan.FromSeconds(10));


    agentsPage.OpenAgent(reviewer.Id); await Task.Delay(250);
    var agentActions = Tree(agentsPage).OfType<Button>().Single(b => b.Content as string == "Actions"); var menu = (MenuFlyout)agentActions.Flyout;
    menu.ShowAt(agentActions); await Task.Delay(100); InvokeMenu(menu, "Duplicate…"); await Task.Delay(200);
    var duplicateDialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single(); Click(duplicateDialog, "PrimaryButton");
    await Until(() => agentsModel.Agents.List().Count == 3 && !agentsModel.IsBusy); var copied = agentsModel.Agents.List().Single(a => a.Name == "Reviewer copy");
    check("Duplicate has a new role and empty run history", () => copied.Seat != reviewer.Seat && !agentsModel.Agents.Runs().Any(r => r.AgentId == copied.Id)); await SnapshotAsync(output, "w12-agent-duplicate-dark");
    agentsPage.OpenAgent(reviewer.Id); await Task.Delay(200); agentActions = Tree(agentsPage).OfType<Button>().Single(b => b.Content as string == "Actions"); menu = (MenuFlyout)agentActions.Flyout; menu.ShowAt(agentActions); await Task.Delay(100); InvokeMenu(menu, "Make lead"); await Task.Delay(150);
    var leadDialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single(); Click(leadDialog, "PrimaryButton"); await Until(() => agentsModel.Projects.Get("aurora").Lead == "agent:" + reviewer.Id);
    check("Make lead uses the project's existing lead memory", () => agentsModel.Agents.SeatOf(reviewer.Id).Key == "lead:aurora" && agentsModel.Agents.Seats().Single(s => s.SeatKey == "lead:aurora").Card.Contains("Make the project", StringComparison.Ordinal));
    await Task.Delay(200); agentActions = Tree(agentsPage).OfType<Button>().Single(b => b.Content as string == "Actions"); menu = (MenuFlyout)agentActions.Flyout; menu.ShowAt(agentActions); await Task.Delay(100); InvokeMenu(menu, "Stop leading project"); await Task.Delay(150);
    leadDialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single(); Click(leadDialog, "PrimaryButton"); await Until(() => agentsModel.Projects.Get("aurora").Lead is null);
    await Task.Delay(200); agentActions = Tree(agentsPage).OfType<Button>().Single(b => b.Content as string == "Actions"); menu = (MenuFlyout)agentActions.Flyout; menu.ShowAt(agentActions); await Task.Delay(100); InvokeMenu(menu, "Add a hand"); await Until(() => NewSessionPicker.ActiveDialogForProof is not null);
    var handDialog = NewSessionPicker.ActiveDialogForProof!; check("Add a hand requires its own job", () => !handDialog.IsPrimaryButtonEnabled);
    await Task.Delay(200); var handScroll = Tree(handDialog).OfType<ScrollViewer>().First(); handScroll.ChangeView(null, handScroll.ScrollableHeight, null, true); await Task.Delay(200);
    await SnapshotAsync(output, "w12-helper-hand-dialog-dark", handDialog);
    await Until(() => Tree(handDialog).OfType<TextBox>().Any(t => AutomationProperties.GetAutomationId(t) == "agents.hand.job"));
    Tree(handDialog).OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == "agents.hand.job").Text = "Check this isolated fixture";
    Tree(handDialog).OfType<CheckBox>().Single(c => c.Content as string is { } text && text.StartsWith("Temporary helper", StringComparison.Ordinal)).IsChecked = true;
    await Until(() => handDialog.IsPrimaryButtonEnabled); Click(handDialog, "PrimaryButton"); await Until(() => agentsModel.Agents.Runs().Any(r => r.ParentSeatKey == "role:aurora/reviewer"));
    var helper = agentsModel.Agents.Runs().Single(r => r.ParentSeatKey == "role:aurora/reviewer"); check("Helper hand gets its own job and temporary seat", () => helper.Job == "Check this isolated fixture" && helper.SeatKey!.Contains("--helper-", StringComparison.Ordinal)); agentsModel.Agents.EndHand(helper.SessionId);
    agentsModel.SelectedId = null; await Task.Delay(200); Click(agentsPage, "Org chart view"); await Task.Delay(150);
    var search = Tree(agentsPage).OfType<AutoSuggestBox>().Single(); search.Text = "Reviewer"; await Task.Delay(150);
    check("Org chart search preserves its edit control", () => ReferenceEquals(search, Tree(agentsPage).OfType<AutoSuggestBox>().Single()));
    await SnapshotAsync(output, "w12-org-search-dark");
    Click(agentsPage, "Done search"); await Task.Delay(200); check("Done search closes the org search", () => Tree(agentsPage).OfType<Button>().Any(b => b.Content as string == "Find"));
    Click(agentsPage, "Find"); await Task.Delay(200); Tree(agentsPage).OfType<AutoSuggestBox>().Single().Text = "Reviewer"; await Task.Delay(150);

    window.AppWindow.Resize(new SizeInt32(820, 780)); await SnapshotAsync(output, "w12-org-narrow-dark");
    agentsModel.Agents.Save(agentsModel.Agents.Get(reviewer.Id) with { Status = SavedAgentStatus.Archived }); await Task.Delay(200); Click(agentsPage, "Archived"); await Task.Delay(200);
    var archiveScroll = (ScrollViewer)agentsPage.Children[0]; archiveScroll.ChangeView(null, archiveScroll.ScrollableHeight, null, true); await Task.Delay(250);
    check("Archived agent remains reachable for restore", () => Tree(agentsPage).OfType<Button>().Any(b => AutomationProperties.GetName(b) == "Open " + reviewer.Name));
    await SnapshotAsync(output, "w12-archived-dark");
    Click(agentsPage, "Archived"); await Task.Delay(200); Click(agentsPage, "New agent"); await Task.Delay(250);
    var hire = VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single();
    Tree(hire).OfType<TextBox>().Single(t => t.Header as string == "Name").Text = "New role proof";
    Tree(hire).OfType<TextBox>().Single(t => t.Header as string == "New role · lowercase words and dashes").Text = "proof-worker";
    Tree(hire).OfType<ComboBox>().Single(c => c.Header as string == "Project").SelectedValue = "aurora";
    var picture = Tree(hire).OfType<Button>().Single(b => b.Content as string == "Choose picture…"); ((Flyout)picture.Flyout).ShowAt(picture); await Task.Delay(150);
    var pictureContent = (FrameworkElement)((Flyout)picture.Flyout).Content;
    Tree(pictureContent).OfType<ComboBox>().Single(c => c.Header as string == "Picture").SelectedValue = "emoji";
    Tree(pictureContent).OfType<ComboBox>().Single(c => c.Header as string == "Colour").SelectedValue = "teal";
    Tree(pictureContent).OfType<TextBox>().Single(t => t.Header as string == "One emoji").Text = "🛠️"; Click(pictureContent, "Use emoji");
    await SnapshotAsync(output, "w12-agent-picture-detail-dark", pictureContent); ((Flyout)picture.Flyout).Hide(); Click(hire, "PrimaryButton");
    await Until(() => agentsModel.Agents.List().Any(a => a.Name == "New role proof") && !agentsModel.IsBusy);
    var hired = agentsModel.Agents.List().Single(a => a.Name == "New role proof"); check("New agent keeps the chosen project role and picture", () => hired.ProjectId == "aurora" && hired.Seat == "proof-worker" && hired.Icon == "emoji:🛠️@teal");
    await SnapshotAsync(output, "w12-new-agent-dark");
    check("Empty descriptions do not offer a dead More action", () => !Tree(agentsPage).OfType<HyperlinkButton>().Any(b => b.Content as string == "More" && b.Visibility == Visibility.Visible));

  }
  private static async Task SnapshotAsync(string directory, string name, FrameworkElement? target = null)
  {
    await Task.Delay(700);
    if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1")
    {
      renderRoot!.UpdateLayout();
      var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(target ?? renderRoot);
      if (bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0) throw new InvalidOperationException("Empty offscreen render.");
      var pixels = await bitmap.GetPixelsAsync(); var bytes = new byte[checked((int)pixels.Length)]; DataReader.FromBuffer(pixels).ReadBytes(bytes);
      using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
      encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync();
      using var reader = new DataReader(stream.GetInputStreamAt(0)); await reader.LoadAsync((uint)stream.Size); var png = new byte[checked((int)stream.Size)]; reader.ReadBytes(png);
      await File.WriteAllBytesAsync(Path.Combine(directory, name + ".png"), png); return;
    }
    var ack = Path.Combine(directory, name + ".ack"); var completion = new TaskCompletionSource();
    using var watcher = new FileSystemWatcher(directory, "*.ack") { EnableRaisingEvents = true }; watcher.Created += (_, e) => { if (e.FullPath == ack) completion.TrySetResult(); };
    await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name, closeDialog = name == "06-new-session-picker" }));
    if (File.Exists(ack)) completion.TrySetResult(); await completion.Task.WaitAsync(TimeSpan.FromSeconds(30));
  }
  private static async Task SamplePictureAsync(string path, int width = 640, int height = 360)
  {
    using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    var bytes = new byte[width * height * 4];
    for (var y = 0; y < height; y++) for (var x = 0; x < width; x++) { var i = (y * width + x) * 4; var bright = x > 250 && x < 390 || y > 130 && y < 230; bytes[i] = bright ? (byte)220 : (byte)94; bytes[i + 1] = bright ? (byte)220 : (byte)76; bytes[i + 2] = bright ? (byte)240 : (byte)104; bytes[i + 3] = 255; }
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, (uint)width, (uint)height, 96, 96, bytes); await encoder.FlushAsync();
    using var reader = new DataReader(stream.GetInputStreamAt(0)); await reader.LoadAsync((uint)stream.Size); var png = new byte[checked((int)stream.Size)]; reader.ReadBytes(png); await File.WriteAllBytesAsync(path, png);
  }
  private sealed class Navigation(Window window, ContentControl content) : IProjectsAgentsNavigation
  {
    public ProjectsPage Projects { get; set; } = null!;
    public AgentsPage Agents { get; set; } = null!;
    public nint WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(window);
    public void OpenSession(string id) { }
    public void OpenProject(string id) { content.Content = Projects; Projects.OpenProject(id); }
    public void OpenAgent(string id) { content.Content = Agents; Agents.OpenAgent(id); }
  }
  private sealed class ExampleProvider(string provider) : IAccountProvider
  {
    public string Provider => provider;
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "example@invalid.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new InvalidOperationException("No provider sign-in is used by this preview.");
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
}
