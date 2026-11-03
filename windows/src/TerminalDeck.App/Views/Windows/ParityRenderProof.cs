using System.Diagnostics;
using System.Reflection;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Hoot;
using TerminalDeck.App.Views.Quality;
using TerminalDeck.App.Views.Computers;
using TerminalDeck.App.Views.Store;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Quality;
using TerminalDeck.Core.Store;
using TerminalDeck.Core.Storage;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Code;
using TerminalDeck.App.Views.Receiver;
using TerminalDeck.App.Views.Servers;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Dispatch occurs only after W13's fresh-root marker and output validation.
  // No control actions, provider sessions, hooks, credentials or network calls.
  private async Task RunParityRenderProofAsync(string output)
  {
    var frames = new List<object>(); var failed = new List<string>(); var captured = new List<string>();
    var unseen = new[] { "Terminal and remote terminal pixels (no session started)", "Side question and fork dialogs (no modal actions invoked)", "Phone/browser pick and handover overlays (no phone connection)", "Live device/screen/session states (no pairing/device access)", "Account/coding-AI settings (no credential or account-home inspection)", "Native creation dialogs and popup menus (ContentDialog/Flyout focus intentionally avoided)" };
    void Stage(string text) => File.WriteAllText(Path.Combine(output, "stage.txt"), text);
    void CheckSession()
    {
      var id = Process.GetCurrentProcess().SessionId;
      if (!WTSQuerySessionInformation(0, id, 8, out var buffer, out var length)) throw new IOException("Own Windows session state could not be verified; captures stopped.");
      try { var state = length >= 4 ? Marshal.ReadInt32(buffer) : -1; if (state is not (0 or 1)) throw new IOException("Own Windows session is not Active/Connected; captures stopped (state " + state + ")."); }
      finally { WTSFreeMemory(buffer); }
    }
    async Task Capture(string name, string evidence)
    {
      CheckSession(); AppWindow.Move(new(-20000, -20000)); Model.Notice = "";
      await Task.Delay(300); CheckSession(); Root.UpdateLayout();
      name += "-" + Math.Round(Root.ActualWidth);
      frames.Add(await Verification.W10Proof.CaptureAsync(Root, output, name, Root.ActualTheme.ToString().ToLowerInvariant(), evidence, Stage));
      captured.Add(name + ":" + Root.ActualTheme);
    }
    try
    {
      await Ready; CheckSession(); proofChatVisible = true; settings.SettingsBrowser = null; settings.PrivacyBrowser = null; AppWindow.Move(new(-20000, -20000));
      using var sizing = new W13RenderWindow(this);
      if (Runtime.Sessions.Count != 0 || Runtime.Chats.List().Count != 0 || Runtime.Tasks.List(new(Status: "all")).Count != 0 || Runtime.Projects.List().Count != 1)
        throw new InvalidOperationException("Parity rendering needs a fresh empty W13 scratch root.");
      var folder = Path.Combine(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(dataRoot.DirectoryPath))!, "fixture-project"); Directory.CreateDirectory(folder);
      var project = Runtime.Projects.Create("Parity review", folder);
      Runtime.Agents.Save(new("parity-reviewer", "Review agent", "codex", "Synthetic visual metadata only. No run.", ProjectId: project.Id, Seat: "project-lead"));
      string? taskId = null;
      foreach (var title in new[] { "Review header spacing", "Check dense controls", "Finish visual handoff" })
      { var task = Runtime.Tasks.Create(new(title, "Synthetic visual fixture. No run or delivery.", project.Id, folder, Status: title.Contains("handoff", StringComparison.Ordinal) ? "Stuck" : "To-Do"), TaskActor.Owner); taskId ??= task.Id; }
      var emptyHost = new ParityCodeHost(); var noProcess = new ParityNoProcess();
      foreach (var width in new[] { 1920, 1280 })
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        SetTheme(theme); sizing.Resize(width, width == 1920 ? 1080 : 900);
        foreach (var page in new[] { ShellPage.Tasks, ShellPage.Projects, ShellPage.Agents })
        { W10HostFixture(page, PageView(page)); if (page == ShellPage.Projects) Projects.Model.SelectedId = null; if (page == ShellPage.Agents) Agents.Model.SelectedId = null; await Capture(page.ToString().ToLowerInvariant(), "Real shell/page; scratch synthetic project, agent and task metadata only"); }
        W10HostFixture(ShellPage.Tasks, PageView(ShellPage.Tasks)); tasksPage!.OpenTask(taskId!); await Capture("task-detail", "Real task detail; synthetic metadata, no delivery"); tasksPage.Model.Select(null);
        Projects.OpenProject(project.Id); W10HostFixture(ShellPage.Projects, Projects); await Capture("project-detail", "Real project detail; private scratch folder only");
        Agents.OpenAgent("parity-reviewer"); W10HostFixture(ShellPage.Agents, Agents); await Capture("agent-detail", "Real agent detail; no run or provider call");
        foreach (var section in new[] { "Directory", "Apps", "Coding AIs", "Websites", "Health", "Files" })
        { W10HostFixture(ShellPage.Servers, ServersParityFixture.Create(section, WindowHandle)); await Capture("servers-" + section.ToLowerInvariant().Replace(" ", "-", StringComparison.Ordinal), "Real ServersPage with in-memory synthetic service; writes refused"); }
        W10HostFixture(ShellPage.Receiver, ReceiverParityFixture.Inbox()); await Capture("receiver-inbox", "Real ReceiverPage with in-memory synthetic service; no intake listener");
        W10HostFixture(ShellPage.Artifacts, ReceiverParityFixture.Artifacts()); await Capture("artifacts", "Real ArtifactsPage with synthetic in-memory catalogue");
        W10HostUnlisted( new FilesPage(emptyHost, new ProjectFiles(noProcess))); await Capture("files-empty", "Real FilesPage; no roots and no process/filesystem requests");
        W10HostUnlisted( new SourceControlPage(emptyHost, new GitClient(noProcess))); await Capture("source-control-empty", "Real SourceControlPage; no roots and synthetic process runner");
        W10HostUnlisted( new GitHubPage(emptyHost, new GitHubClient(noProcess, _ => null))); await Capture("github-signed-out", "Real GitHubPage; synthetic signed-out process result, no credential access");
        using (var hoot = new HootPage(DispatchProxy.Create<IHoot, ParityRenderHoot>(), () => [], () => []))
        { W10HostFixture(ShellPage.Hoot, hoot); await Capture("hoot-empty", "Real HootPage; empty in-memory owner, no provider/account access"); }
        var chatService = DispatchProxy.Create<IChatSessions, UiConsistencyChatSessionProxy>();
        var fixtureChatId = Guid.NewGuid().ToString();
        ((UiConsistencyChatSessionProxy)(object)chatService).Initialize(new ChatRecord(1, new(fixtureChatId, "codex", folder, "Visual chat fixture", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()), "fixture", [], []));
        await using (var chat = new ChatPage(chatService, fixtureChatId))
        { W10HostUnlisted( chat); await Capture("chat-dense", "Real ChatPage with existing in-memory no-delivery fixture; synthetic approval, tools and queued text"); }
        await TerminalDeck.App.Views.Agents.NewSessionPicker.ShowAsync(Root.XamlRoot, Runtime.Agents, Runtime.Projects, null, this, projectId: project.Id, renderForProof: async form =>
        { W10HostUnlisted( new ScrollViewer { Content = form, Padding = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Stretch }); await Capture("new-session-form", "Actual NewSessionPicker form hosted nonmodally; no account service and no control actions; native dialog chrome unseen"); });
        W10HostUnlisted( new Hooks.HooksPage(Runtime, () => [new("fixture", "Synthetic account", "codex", new("codex", "", false, "missing", [], ["SessionStart", "Stop"], 0, null, "Synthetic fixture: no account configuration was inspected."))])); await Capture("hooks", "Actual HooksPage with injected synthetic status; install/remove disabled, no config inspected");
        W10HostUnlisted( new ProjectReadinessPage(new ProjectReadiness(), folder, runner: noProcess)); await Capture("readiness", "Real readiness scanner against owned empty scratch folder; synthetic process runner, no executable run");
        W10HostUnlisted( new StaysFixedPage(new StaysFixedService(new ParityQualityRunner()), folder, () => { })); await Capture("stays-fixed", "Real StaysFixedPage; synthetic doctor report, no engine process");
        W10HostUnlisted( new ScrollViewer { Content = new OtherComputersCard(Runtime.OtherComputers) { MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Left }, Padding = new Thickness(48, 34, 28, 24) }); await Capture("other-computers-empty", "Real empty OtherComputersCard; no pair/connect/watch action");
        var devices = new SettingsPane(Model, Runtime, 2, popupPresentation: true);
        W10HostUnlisted( devices); await devices.SelectSectionAsync(2); await Capture("devices-empty", "Real Devices settings content; scratch trust only, no pairing/screen action");
        var store = new AppStoreService(new ParityMemory<StoreLedger>(new([], [])), new ParityStoreInstaller(), new ParityStoreAuthorizer()); store.MergeCatalog(NativeStoreStock.BuiltIns.Concat(McpStoreStock.Read()));
        W10HostUnlisted( new StorePage(store, () => { }, refreshCommunityOnLoad: false)); await Capture("store", "Real StorePage and bundled stock catalogue; remote refresh disabled, installs refused");
        var proofBrowser = new BrowserPane(AppDataRoot.Explicit(Path.Combine(dataRoot.DirectoryPath, "browser-proof-" + width + "-" + theme)), _ => Task.FromException(new InvalidOperationException("Visual fixture cannot send browser context.")));
        try
        {
          W10HostUnlisted( proofBrowser); await proofBrowser.Ready.WaitAsync(TimeSpan.FromSeconds(30));
          await proofBrowser.AddTabAsync();
          var outside = proofBrowser.Core.Read().Tabs.Select(t => t.Url).Where(u => u.Length != 0 && !u.StartsWith("about:", StringComparison.OrdinalIgnoreCase) && !(Uri.TryCreate(u, UriKind.Absolute, out var local) && local.Host == "start.deck.invalid")).ToArray();
          if (outside.Length != 0) throw new InvalidOperationException("Browser proof can render only blank or built-in start pages: " + string.Join(", ", outside.Select(u => Uri.TryCreate(u, UriKind.Absolute, out var x) ? x.Scheme + "://" + x.Host : "(unparsed)")));
          await Capture("browser-blank", "Real BrowserPane/WebView2 at about:blank, private scratch storage only");
        }
        finally { proofBrowser.DisposeViews(); }
        // Host Settings content inside the already offscreen shell. Never open,
        // activate or clamp the normal native Settings window onto the display.
        settingsPanel ??= CreateSettingsPanel();
        foreach (var route in new[] { "general", "appearance", "notifications", "agent-defaults", "browser", "tasks", "advanced", "about" })
        {
          W10HostUnlisted( settingsPanel); await settingsPanel.SelectAsync(route);
          await Capture("settings-" + route, "Real SettingsPanel content inside offscreen scratch shell; no controls invoked");
        }
      }
      if (Runtime.Sessions.Count != 0 || Runtime.Chats.List().Count != 0 || Runtime.Hoot.Read().Turns.Length != 0 || Runtime.Agents.Runs().Count != 0)
        failed.Add("The renderer unexpectedly created a session or run.");
      var errors = Path.Combine(dataRoot.DirectoryPath, "logs", "errors.log");
      if (File.Exists(errors) && new FileInfo(errors).Length > 0) failed.Add("Recovered UI errors were recorded in the owned scratch errors.log; inspect before accepting frames.");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add(ex.ToString()); }
    finally
    {
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, synthetic = true, offscreen = true, expectedFrames = 140, captured, unseen, failed, frames }, new JsonSerializerOptions { WriteIndented = true }));
      closingShell = true; Close();
    }
  }
  private sealed class ParityCodeHost : ICodePageHost
  {
    public IReadOnlyList<CodeRoot> Roots() => [];
    public (string? ProjectId, string? Folder) Current() => (null, null);
    public UIElement Picture(CodeRoot root, double size) => new Grid();
    public Task OpenTerminalAsync(CodeRoot root, string folder) => throw new InvalidOperationException("Visual fixture cannot start a session.");
    public Task OpenInBrowserAsync(string url) => throw new InvalidOperationException("Visual fixture cannot browse.");
    public void Notice(string message) { }
  }
  private sealed class ParityNoProcess : ICodeProcessRunner
  {
    public Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken ct, string? input = null)
      => Task.FromResult(new CodeProcessResult(1, "", "Synthetic signed-out fixture; no process executed.", Missing: true));
  }
  [DllImport("wtsapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSQuerySessionInformation(nint server, int session, int information, out nint buffer, out int bytes);
  [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(nint buffer);
}

// Read-only owners for actual page trees. All mutations fail rather than
// accidentally falling through to the application's real service graph.
public class ParityRenderHoot : DispatchProxy
{
  protected override object? Invoke(MethodInfo? method, object?[]? arguments) => method!.Name switch
  {
    "Read" => HootState.Empty,
    "ModelsAsync" => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]),
    "add_Changed" or "remove_Changed" => null,
    _ => throw new InvalidOperationException("Visual Hoot fixture cannot send or change settings.")
  };
}
internal sealed class ParityQualityRunner : IQualityRunner
{
  public Task<QualityCommandResult> RunAsync(string folder, IReadOnlyList<string> arguments, CancellationToken ct)
    => Task.FromResult(new QualityCommandResult(0, "{\"status\":\"needs-setup\",\"summary\":\"Synthetic project doctor report\",\"checks\":[{\"name\":\"Recorded reference\",\"status\":\"missing\",\"detail\":\"No reference has been recorded in this scratch fixture.\"}]}", ""));
}
internal sealed class ParityMemory<T>(T value) : IStateStore<T>
{
  public T? Load() => value;
  public void Save(T next) => value = next;
}
internal sealed class ParityStoreAuthorizer : IStoreAuthorizer
{
  public ValueTask<bool> ApproveAsync(StoreEntry entry, string action, CancellationToken ct) => ValueTask.FromResult(false);
}
internal sealed class ParityStoreInstaller : IAppStoreInstaller
{
  public ValueTask<StoreInstallation> InstallAsync(StoreEntry entry, bool update, CancellationToken ct, StoreInstallOptions? options = null) => throw new InvalidOperationException("Visual fixture cannot install.");
  public ValueTask RemoveAsync(StoreEntry entry, string receipt, CancellationToken ct) => throw new InvalidOperationException("Visual fixture cannot uninstall.");
}
