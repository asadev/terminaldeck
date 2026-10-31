using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views;
using TerminalDeck.App.Views.Receiver;
using TerminalDeck.App.Views.Servers;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tasks;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Verification
{
  // Launch only with a new C:\TD-W10Proof\<GUID>\data root. Before launch,
  // write "W10 SCRATCH ONLY" to <root>\.w10-proof-allow and set
  // TD_W10_PROOF_ROOT=<root>, TD_W10_PROOF=<root>\frames.
  // No legacy proof runner is invoked: some of those start real processes.
  internal static class W10Proof
  {
    internal sealed record FrameResult(string Page, string Theme, string Path, int Width, int Height,
      int WebViewsComposed, string DataMode, DateTimeOffset At);
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    private sealed record Plan(string Name, Func<Task> Prepare, string DataMode);
    private sealed record Replacement(Panel Parent, int Index, WebView2 View, Image Pixels);
    private sealed record StageResult(DateTimeOffset At, string Name, int ManagedThread);
    private sealed record FailureResult(DateTimeOffset At, string Context, string Stage, string Detail);

    internal static async Task RunIfRequestedAsync(ShellWindow window, AppDataRoot root)
    {
      var output = Environment.GetEnvironmentVariable("TD_W10_PROOF");
      if (string.IsNullOrWhiteSpace(output)) return;
      RequireScratch(root, output);
      Directory.CreateDirectory(output);
      using (new FileStream(Path.Combine(root.DirectoryPath, "w10-proof.started"), FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
      var frames = new List<FrameResult>(); var passed = new List<string>(); var failed = new List<string>();
      var started = DateTimeOffset.UtcNow; var planned = 0;
      var stages = new List<StageResult>(); var diagnostics = new List<FailureResult>(); var stage = "entry";
      void Stage(string name)
      {
        stage = name;
        var entry = new StageResult(DateTimeOffset.UtcNow, name, Environment.CurrentManagedThreadId);
        stages.Add(entry);
        // Synchronous writes retain the last successful boundary even if a
        // WinUI/COM failure stops dispatch before an async continuation runs.
        File.AppendAllText(Path.Combine(output, "stages.jsonl"), JsonSerializer.Serialize(entry) + Environment.NewLine);
        File.WriteAllText(Path.Combine(output, "stage.json"), JsonSerializer.Serialize(entry));
      }
      void Diagnose(string context, Exception error)
      {
        // This entry point has already checked the explicitly marked, fresh
        // scratch root. Only synthetic fixture actions run below this guard.
        diagnostics.Add(new(DateTimeOffset.UtcNow, context, stage, error.ToString()));
        File.WriteAllText(Path.Combine(output, "diagnostics.json"), JsonSerializer.Serialize(diagnostics, Json));
      }
      string[] limitations = [
        "Images are full WinUI client frames. OS-drawn caption buttons and the outer native window border require a separate desktop screenshot.",
        "Sessions use a real draft terminal without a running provider or shell. Chat is a real signed-out empty chat; no message is sent.",
        "Servers, Receiver and Artifacts use the existing in-memory appearance fixtures inside the real shell host. Their network/write actions refuse changes.",
        "Hoot tabs render the fresh signed-out runtime. No Hoot turn, refresh, handoff or sign-in is requested.",
        "Control checks cover named navigation, view switches and structural contracts. This is not an exhaustive test of every product action.",
        "Windows frames alone do not establish Mac parity. Compare these paths with the supplied Mac references and inspect the results separately."
      ];
      async Task Manifest()
      {
        await File.WriteAllTextAsync(Path.Combine(output, "manifest.json"), JsonSerializer.Serialize(new {
          started, updated = DateTimeOffset.UtcNow, scratchRoot = root.DirectoryPath,
          renderer = "RenderTargetBitmap with actual CapturePreview PNGs substituted for visible WebView2 controls",
          plannedFrames = planned, capturedFrames = frames.Count, checksPassed = passed.Count, checksFailed = failed.Count,
          stage, stages, diagnostics, passed, failed, frames, limitations
        }, Json));
      }
      void Check(string title, bool ok) => (ok ? passed : failed).Add(title);
      try
      {
        Stage("before-ready");
        await window.Ready.WaitAsync(TimeSpan.FromSeconds(60)); Stage("after-ready");
        Stage("before-require-fresh"); RequireFresh(window); Stage("after-require-fresh");
        Stage("before-main-window-move"); window.AppWindow.Move(new Windows.Graphics.PointInt32(-20000, -20000)); Stage("after-main-window-move");
        Stage("before-main-window-resize"); window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 840)); Stage("after-main-window-resize");
        Stage("before-clear-notice"); window.Model.Notice = ""; Stage("after-clear-notice");
        // These are the same scratch-only metadata fixtures used by the
        // projects/agents parity proof, with no provider run or sign-in.
        Stage("before-fixture-folders");
        var deckFolder = Path.Combine(Path.GetDirectoryName(root.DirectoryPath)!, "projects", "Deck Dev"); Directory.CreateDirectory(deckFolder);
        var crmFolder = Path.Combine(Path.GetDirectoryName(root.DirectoryPath)!, "projects", "CRM"); Directory.CreateDirectory(crmFolder); Stage("after-fixture-folders");
        Stage("before-project-deck-create"); var deck = window.Runtime.Projects.Create("Deck Dev", deckFolder); Stage("after-project-deck-create");
        Stage("before-project-crm-create"); var crm = window.Runtime.Projects.Create("CRM", crmFolder); Stage("after-project-crm-create");
        Stage("before-default-account-read"); var account = window.Runtime.Accounts.List("codex").Single(); Stage("after-default-account-read");
        Stage("before-agent-lead-save");
        var lead = window.Runtime.Agents.Save(new("w10-decker", "Decker", "codex",
          "Plans the release, reviews changes and keeps a clear handoff. Synthetic appearance fixture in a private data root.",
          Model: "GPT-6.1 Sol", ProjectId: deck.Id, Seat: "project-lead", ReportsTo: AgentSeats.HootId)); Stage("after-agent-lead-save");
        Stage("before-project-set-lead"); window.Runtime.Agents.SetProjectLead(deck.Id, lead.Id); Stage("after-project-set-lead");
        Stage("before-agent-alex-save");
        window.Runtime.Agents.Save(new("w10-alex", "Alex", "claude", "Maintains the CRM appearance fixture.", ProjectId: crm.Id, ReportsTo: AgentSeats.HootId)); Stage("after-agent-alex-save");
        Stage("before-agent-reviewer-save"); window.Runtime.Agents.Save(new("w10-reviewer", "Release reviewer", "codex", "Checks both themes.", ProjectId: deck.Id, ReportsTo: lead.Id)); Stage("after-agent-reviewer-save");
        var today = DateOnly.FromDateTime(DateTime.Today);
        Stage("before-task-frame-create"); var task = window.Runtime.Tasks.Create(new("Review the Windows frame", "Compare the whole frame and detailed controls in both themes.", deck.Id, deckFolder,
          Priority: "High", DueDate: today.ToString("yyyy-MM-dd")), TaskActor.Owner); Stage("after-task-frame-create");
        Stage("before-task-browser-create");
        window.Runtime.Tasks.Create(new("Check browser recording", "Use only the bundled local page.", deck.Id, deckFolder,
          Status: "In Progress", Priority: "Medium", DueDate: today.AddDays(1).ToString("yyyy-MM-dd")), TaskActor.Owner); Stage("after-task-browser-create");
        Stage("before-task-handoff-create");
        window.Runtime.Tasks.Create(new("Prepare the review handoff", "Keep source evidence separate from rendered evidence.", crm.Id, crmFolder), TaskActor.Owner); Stage("after-task-handoff-create");
        Stage("before-terminal-draft-create"); var terminal = window.Model.AddDraft("codex", deckFolder, SessionPresentation.Terminal); Stage("after-terminal-draft-create");
        Stage("before-terminal-appearance"); terminal.SetAppearance("Deck Dev", null, "Decker"); Stage("after-terminal-appearance");
        Stage("before-chat-create"); var chat = await window.Runtime.Chats.CreateAsync("codex", deckFolder, account.Id);
        Stage("after-chat-create");
        Stage("before-session-sync"); window.W10SyncSessions(); Stage("after-session-sync");
        Stage("before-terminal-select"); window.W10SelectSession(terminal.Id); Stage("after-terminal-select");
        Stage("before-terminal-ready"); await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(40)); Stage("after-terminal-ready");
        Stage("before-browser-ready"); await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(40)); Stage("after-browser-ready");
        // A second retained browser tab proves that the header shows all windows.
        Stage("before-browser-add-tab"); await window.Browser.AddTabAsync(); Stage("after-browser-add-tab");
        Stage("before-browser-observe"); window.Browser.ObserveShellPages(); Stage("after-browser-observe");
        Stage("before-browser-session-sync"); window.W10SyncSessions(); Stage("after-browser-session-sync");
        var browserId = window.Browser.Core.Read().SelectedTabId!;
        var plans = new List<Plan>
        {
          new("sessions", async () => { window.W10SelectSession(terminal.Id); await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(20)); }, "real retained draft terminal; no process"),
          new("sessions-split", () => window.W10SplitAsync(terminal.Id, browserId), "real retained draft terminal and bundled local WebView2"),
          new("browser", () => window.W10ShowBrowserAsync(browserId), "real bundled local WebView2"),
          new("browser-recording", async () => {
            await window.W10ShowBrowserAsync(browserId);
            if (!window.Browser.IsRecording) await window.Browser.ExecuteAsync("record");
            await window.Browser.EvaluateForProofAsync("if(!document.getElementById('w10-proof-click')){document.querySelector('main').insertAdjacentHTML('beforeend','<p style=\"margin-top:24px\">Synthetic local recording fixture</p><button id=\"w10-proof-click\">Review layout</button><input aria-label=\"Proof input\" id=\"w10-proof-input\">');}document.getElementById('w10-proof-click').click();document.getElementById('w10-proof-input').dispatchEvent(new Event('change',{bubbles:true}));");
            await Until(() => window.Browser.StepCount >= 2);
            Check("recording collects selectors on the bundled page", window.Browser.StepCount >= 2);
          }, "real bundled local WebView2 with synthetic local recording controls"),
          new("browser-recorded", async () => { await window.W10ShowBrowserAsync(browserId); if (window.Browser.IsRecording) await window.Browser.ExecuteAsync("record"); }, "real retained browser recording; entered values omitted"),
          new("chat-signed-out", () => { window.W10SelectSession(chat.Definition.Id); return Task.CompletedTask; }, "real signed-out empty chat; no send"),
          new("projects", () => { window.ShowProjectsForProof(); return Task.CompletedTask; }, "real scratch project metadata"),
          new("project-detail", () => { window.OpenProject(deck.Id); return Task.CompletedTask; }, "real scratch project metadata"),
          new("agents", async () => { window.ShowAgentsForProof(); await Settle(); Invoke(window.Agents, "All agents view"); await Settle(); Invoke(window.Agents, "Cards view"); }, "real scratch agent metadata"),
          new("agents-list", async () => { window.ShowAgentsForProof(); await Settle(); Invoke(window.Agents, "List view"); }, "real scratch agent metadata"),
          new("agents-org", async () => { window.ShowAgentsForProof(); await Settle(); Invoke(window.Agents, "Org chart view"); }, "real scratch agent metadata"),
          new("agent-detail", () => { window.OpenAgent(lead.Id); return Task.CompletedTask; }, "real scratch agent metadata"),
          new("tasks", async () => { window.Model.Page = ShellPage.Tasks; window.TasksForProof.Model.Select(null); await Settle(); Invoke(window.TasksForProof, "List view"); }, "real scratch tasks; no assignment or run"),
          new("tasks-board", async () => { window.Model.Page = ShellPage.Tasks; window.TasksForProof.Model.Select(null); await Settle(); Invoke(window.TasksForProof, "Board view"); }, "real scratch tasks; no assignment or run"),
          new("tasks-calendar", async () => { window.Model.Page = ShellPage.Tasks; window.TasksForProof.Model.Select(null); await Settle(); Invoke(window.TasksForProof, "Calendar view"); }, "real scratch tasks; no assignment or run"),
          new("task-detail", () => { window.Model.Page = ShellPage.Tasks; window.TasksForProof.OpenTask(task.Id); return Task.CompletedTask; }, "real scratch task; no comment or external delivery"),
          new("servers", () => { window.W10HostFixture(ShellPage.Servers, ServersParityFixture.Create(windowHandle: window.WindowHandle)); return Task.CompletedTask; }, "existing read-only in-memory servers fixture"),
          new("server-apps", () => { window.W10HostFixture(ShellPage.Servers, ServersParityFixture.Create("Apps", window.WindowHandle)); return Task.CompletedTask; }, "existing read-only in-memory servers fixture"),
          new("server-files", () => { window.W10HostFixture(ShellPage.Servers, ServersParityFixture.Create("Files", window.WindowHandle)); return Task.CompletedTask; }, "existing read-only in-memory servers fixture"),
          new("receiver", () => { window.W10HostFixture(ShellPage.Receiver, ReceiverParityFixture.Inbox()); return Task.CompletedTask; }, "existing read-only in-memory Receiver fixture"),
          new("artifacts", () => { window.W10HostFixture(ShellPage.Artifacts, ReceiverParityFixture.Artifacts()); return Task.CompletedTask; }, "existing read-only in-memory artifact fixture")
        };
        foreach (var section in new[] { "Chat", "Desk", "Playbook", "History" })
        {
          var route = section;
          plans.Add(new("hoot-" + route.ToLowerInvariant(), async () => {
            window.Model.Page = ShellPage.Hoot; await Settle();
            Invoke(window.Frame, "hoot.section." + route.ToLowerInvariant(), automationId: true);
          }, "real fresh signed-out Hoot runtime; no turn or refresh"));
        }
        foreach (var category in SettingsNavigation.Categories)
        {
          var route = category.Id;
          plans.Add(new("settings-" + route, () => window.W10SettingsAsync(route), "real floating Settings panel in private scratch root"));
        }
        plans.Add(new("settings-accounts", () => window.W10SettingsAsync("accounts"), "real floating Settings Who uses what tab in private scratch root"));
        planned = plans.Count * 2; Stage("plans-ready");
        await Manifest();
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
          Stage("before-theme-browser-reset-" + theme);
          await window.W10ShowBrowserAsync(browserId);
          if (window.Browser.IsRecording) await window.Browser.ExecuteAsync("record");
          await window.Browser.Core.PerformAsync(browserId, TerminalDeck.Core.Browser.BrowserPageAction.RecordClear, JsonSerializer.SerializeToElement(new { }));
          if (Tree(window.Frame).OfType<ButtonBase>().Any(b => IsShown(b, window.Frame) && AutomationProperties.GetName(b) == "Hide recorded steps"))
            Invoke(window.Frame, "Hide recorded steps");
          await window.Browser.NavigateForProofAsync("https://start.deck.invalid/index.html"); Stage("after-theme-browser-reset-" + theme);
          foreach (var plan in plans)
          {
            var suffix = theme.ToString().ToLowerInvariant();
            var label = plan.Name + "-" + suffix;
            try
            {
              Stage("before-close-settings-" + label); window.W10CloseSettings(); Stage("after-close-settings-" + label);
              Stage("before-theme-" + label); window.SetTheme(theme); Stage("after-theme-" + label);
              Stage("before-page-prepare-" + label); await plan.Prepare().WaitAsync(TimeSpan.FromSeconds(45)); Stage("after-page-prepare-" + label);
              window.Model.Notice = "";
              Stage("before-page-layout-" + label); await Settle(); window.Frame.UpdateLayout(); Stage("after-page-layout-" + label);
              foreach (var assertion in window.W10ShellAssertions(plan.Name.StartsWith("settings-", StringComparison.Ordinal)))
                Check(label + ": " + assertion.Key, assertion.Value);
              Check(label + ": nonempty visible page", Tree(window.Frame).OfType<TextBlock>().Any(t => IsShown(t, window.Frame) && !string.IsNullOrWhiteSpace(t.Text)));
              if (plan.Name.StartsWith("browser", StringComparison.Ordinal))
              {
                var named = Tree(window.Frame).OfType<ButtonBase>().Where(b => IsShown(b, window.Frame)).Select(AutomationProperties.GetName).ToArray();
                Check(label + ": retained browser dock actions are visible", new[] { "Inspect", "Size", "Send", "Recorded steps" }.All(named.Contains) && (named.Contains("Record") || named.Contains("Stop recording")));
              }
              if (plan.Name is "browser-recording" or "browser-recorded")
                Check(label + ": inline flow actions are visible", Tree(window.Frame).OfType<Button>().Where(b => IsShown(b, window.Frame)).Any(b => b.Content as string == "Copy"));
              Stage("before-page-capture-" + label);
              var frame = await CaptureAsync(window.Frame, output, plan.Name, suffix, plan.DataMode, Stage);
              Stage("after-page-capture-" + label);
              frames.Add(frame);
              Check(label + ": full client frame saved", frame.Width > 600 && frame.Height > 400 && File.Exists(frame.Path));
              if (plan.Name.StartsWith("browser", StringComparison.Ordinal) || plan.Name is "sessions" or "sessions-split")
                Check(label + ": actual WebView2 pixels composed", frame.WebViewsComposed > 0);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            { Diagnose(label, ex); failed.Add(label + " at " + stage + ": " + ex.GetType().Name + " 0x" + ex.HResult.ToString("X8")); }
            await Manifest();
          }
        }
        window.W10CloseSettings();
        Stage("before-window-actions"); await window.W10ActionsAsync(terminal.Id, chat.Definition.Id, browserId, Check); Stage("after-window-actions");
        Check("No provider terminal session started", window.Runtime.Sessions.Count == 0);
        Check("No agent run started", window.Runtime.Agents.Runs().Count == 0);
        Check("No task run or mention created", window.Runtime.Tasks.Runs().Count == 0 && window.Runtime.Tasks.List(new(Status: "all")).All(t => window.Runtime.Tasks.Mentions(t.Id).Count == 0));
        Check("All accounts remain signed out", window.Runtime.Accounts.List().All(a => !a.SignedIn));
        Check("No chat message sent", window.Runtime.Chats.List().All(c => c.Messages.Length == 0));
        Check("No Hoot turn requested", window.Runtime.Hoot.Read().Turns.Length == 0);
        Check("Every planned frame captured", frames.Count == planned);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      { Diagnose("Preparation", ex); failed.Add("Preparation stopped at " + stage + ": " + ex.GetType().Name + " 0x" + ex.HResult.ToString("X8")); }
      finally
      {
        await Manifest();
        await File.WriteAllTextAsync(Path.Combine(output, "complete.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, captured = frames.Count, planned, passed = passed.Count, failed = failed.Count }));
        if (Environment.GetEnvironmentVariable("TD_W10_PROOF_EXIT") == "1") window.Close();
      }
    }

    private static void RequireScratch(AppDataRoot root, string output)
    {
      var named = Environment.GetEnvironmentVariable("TD_W10_PROOF_ROOT");
      var prefix = @"C:\TD-W10Proof\";
      var folder = Path.GetFileName(Path.GetDirectoryName(root.DirectoryPath));
      if (!OperatingSystem.IsWindows() || !root.DirectoryPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ||
          Path.GetFileName(root.DirectoryPath) != "data" || !Guid.TryParse(folder, out _) || named is null || !Path.GetFullPath(named).Equals(root.DirectoryPath, StringComparison.OrdinalIgnoreCase) ||
          !Path.GetFullPath(output).StartsWith(root.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
          !File.Exists(Path.Combine(root.DirectoryPath, ".w10-proof-allow")) ||
          File.ReadAllText(Path.Combine(root.DirectoryPath, ".w10-proof-allow")).Trim() != "W10 SCRATCH ONLY" ||
          new[] { "TD_SHELL_PROOF", "TD_SETTINGS_PROOF", "TD_PROJECTS_AGENTS_PARITY", "TD_W7_PROOF", "TD_INTEGRATION_PROOF", "TD_UI_PROOF_DIR", "TD_W9_PROOF" }.Any(key => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable(key))))
        throw new InvalidOperationException("W10 proof requires its own explicitly marked new Windows scratch root and no competing proof runner.");
    }
    private static void RequireFresh(ShellWindow window)
    {
      var runtime = window.Runtime;
      if (runtime.Sessions.Count != 0 || runtime.Chats.List().Count != 0 || runtime.Agents.List().Count != 0 ||
          runtime.Accounts.List().Count != 3 || runtime.Accounts.List().Any(a => a.SignedIn || a.Email is not null || a.CredentialReference is not null) || runtime.Projects.List().Count != 1 ||
          runtime.Tasks.List(new(Status: "all")).Count != 0 || runtime.Tasks.Runs().Count != 0 || runtime.Hoot.Read().Turns.Length != 0)
        throw new InvalidOperationException("W10 proof fixture writes require a fresh empty runtime.");
    }
    private static Task Settle() => Task.Delay(350);
    private static async Task Until(Func<bool> condition)
    {
      var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
      while (!condition()) { if (DateTimeOffset.UtcNow >= deadline) throw new TimeoutException("The local proof state did not settle."); await Task.Delay(80); }
    }
    private static void Invoke(DependencyObject root, string name, bool automationId = false)
    {
      var button = Tree(root).OfType<ButtonBase>().Where(b => root is FrameworkElement frame && IsShown(b, frame)).Single(b => (automationId ? AutomationProperties.GetAutomationId(b) : AutomationProperties.GetName(b)) == name);
      if (button is ToggleButton { IsChecked: true }) return;
      var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button);
      if (peer?.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) invoke.Invoke();
      else if (peer?.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle) toggle.Toggle();
      else throw new InvalidOperationException("The named view switch has no automation action.");
    }
    internal static IEnumerable<DependencyObject> Tree(DependencyObject node)
    {
      yield return node;
      for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
        foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child;
    }
    private static bool IsShown(FrameworkElement element, FrameworkElement root)
    {
      if (element.ActualWidth < 2 || element.ActualHeight < 2) return false;
      for (DependencyObject? node = element; node is not null; node = VisualTreeHelper.GetParent(node))
      {
        if (node is UIElement ui && (ui.Visibility != Visibility.Visible || ui.Opacity == 0)) return false;
        if (ReferenceEquals(node, root)) return true;
      }
      return false;
    }
    internal static async Task<FrameResult> CaptureAsync(FrameworkElement root, string output, string name, string theme, string dataMode, Action<string> stage)
    {
      root.UpdateLayout();
      var replacements = new List<Replacement>();
      try
      {
        foreach (var view in Tree(root).OfType<WebView2>().Where(v => IsShown(v, root)).ToArray())
        {
          if (view.CoreWebView2 is null || view.Parent is not Panel parent) throw new InvalidOperationException("A visible WebView2 cannot be captured.");
          stage("before-webview-preview-" + name + "-" + theme + "-" + replacements.Count);
          using var png = new InMemoryRandomAccessStream();
          async Task Preview() => await view.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, png);
          await Preview().WaitAsync(TimeSpan.FromSeconds(12));
          stage("after-webview-preview-" + name + "-" + theme + "-" + replacements.Count);
          png.Seek(0); var source = new BitmapImage(); await source.SetSourceAsync(png);
          stage("after-webview-bitmap-source-" + name + "-" + theme + "-" + replacements.Count);
          var image = new Image { Source = source, Stretch = Stretch.Fill, Margin = view.Margin,
            HorizontalAlignment = view.HorizontalAlignment, VerticalAlignment = view.VerticalAlignment,
            Width = view.Width, Height = view.Height, MinWidth = view.MinWidth, MinHeight = view.MinHeight };
          Grid.SetRow(image, Grid.GetRow(view)); Grid.SetColumn(image, Grid.GetColumn(view));
          Grid.SetRowSpan(image, Grid.GetRowSpan(view)); Grid.SetColumnSpan(image, Grid.GetColumnSpan(view));
          var index = parent.Children.IndexOf(view); parent.Children.RemoveAt(index); parent.Children.Insert(index, image);
          replacements.Add(new(parent, index, view, image));
          stage("after-webview-substitution-" + name + "-" + theme + "-" + replacements.Count);
        }
        stage("before-render-target-" + name + "-" + theme);
        root.UpdateLayout();
        var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(root);
        stage("after-render-target-" + name + "-" + theme);
        if (bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0) throw new InvalidOperationException("The client frame rendered no pixels.");
        stage("before-render-pixels-" + name + "-" + theme);
        var buffer = await bitmap.GetPixelsAsync(); stage("after-render-pixels-" + name + "-" + theme); var pixels = new byte[checked((int)buffer.Length)];
        using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
        using var encoded = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, encoded);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
        await encoder.FlushAsync();
        using var pngReader = new DataReader(encoded.GetInputStreamAt(0)); await pngReader.LoadAsync(checked((uint)encoded.Size));
        var bytes = new byte[checked((int)encoded.Size)]; pngReader.ReadBytes(bytes);
        stage("before-frame-write-" + name + "-" + theme);
        var path = Path.Combine(output, name + "-" + theme + ".png"); await File.WriteAllBytesAsync(path, bytes);
        stage("after-frame-write-" + name + "-" + theme);
        return new(name, theme, path, bitmap.PixelWidth, bitmap.PixelHeight, replacements.Count, dataMode, DateTimeOffset.UtcNow);
      }
      finally
      {
        foreach (var item in replacements.AsEnumerable().Reverse())
        { item.Parent.Children.Remove(item.Pixels); item.Parent.Children.Insert(Math.Min(item.Index, item.Parent.Children.Count), item.View); }
        root.UpdateLayout();
      }
    }
  }
}

namespace TerminalDeck.App.Views
{
  public sealed partial class ShellWindow
  {
    // Called only by the marked W10 proof entry point above. These reuse the
    // real host and routes, instead of building a second imitation shell.
    internal void W10SyncSessions() => SyncSessions();
    internal void W10SelectSession(string id)
    {
      SyncSessions(); SelectSessionWindow(Model.Sessions.Single(s => s.Id == id));
      windowState.One(id, workspaceOwner); renderedWindowsStructure = ""; RenderWindows();
    }
    internal async Task W10ShowBrowserAsync(string id)
    {
      Model.Page = ShellPage.Browser; SyncWindows();
      windowState.One(id, "browser"); RevealBrowserWindow(id); await browser.SelectShellWindowAsync(id);
      renderedWindowsStructure = ""; RenderWindows();
    }
    internal Task W10SplitAsync(string terminalId, string browserId)
    {
      W10SelectSession(terminalId); windowState.Split(terminalId, browserId, owner: workspaceOwner);
      renderedWindowsStructure = ""; RenderWindows(); return Task.CompletedTask;
    }
    internal void W10HostFixture(ShellPage page, FrameworkElement fixture)
    {
      Model.Page = page; mainSurface.ReleaseViews(); Workspace.Children.Clear(); Workspace.Children.Add(fixture);
      receiverDrop?.Dispose(); receiverDrop = null;
    }
    internal async Task W10SettingsAsync(string route)
    {
      Model.Page = ShellPage.Settings;
      await (settingsPanel ?? throw new InvalidOperationException("The floating Settings panel is missing.")).SelectAsync(route);
    }
    internal void W10CloseSettings() { if (settingsWindow is not null) CloseSettingsPanel(); }
    internal async Task W10ActionsAsync(string terminalId, string chatId, string browserId, Action<string, bool> check)
    {
      var resources = windowState.Tabs.Where(t => t.Kind != "page")
        .Select(t => (t.Kind == "browser" ? "browser:" : "sessions:") + t.Subject)
        .Append("settings:workspace").Distinct().ToArray();
      var caller = Runtime.CallerAuthority.Provision(Runtime.Door, new("w10-scratch-proof", null, null, AiPermissionMode.Ask,
        ["ui.workspace", "windows.list", "windows.pop_out"], Enum.GetValues<McpTier>(), resources), _ => true);
      async Task<JsonElement> Workspace(object args) => await Runtime.Door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(args));
      try
      {
        W10SelectSession(terminalId);
        await Workspace(new { windowAction = new { action = "rename", windowId = terminalId, title = "W10 retained draft" } });
        check("ui.workspace schema accepts rename and updates the retained title", windowState.Get(terminalId).Title == "W10 retained draft");
        await Workspace(new { windowAction = new { action = "split", windowId = terminalId, otherWindowId = chatId, ownerSessionId = terminalId } });
        await Task.Delay(250);
        check("ui.workspace split hosts both actual retained pages", windowState.Layout(terminalId).Root?.Tabs.Count() == 2 && Verification.W10Proof.Tree(mainSurface).OfType<ContentControl>().Count(c => c.Tag as string == "workspace-view" && c.Content is FrameworkElement) == 2);
        await Workspace(new { windowAction = new { action = "resize", windowId = terminalId, ownerSessionId = terminalId, ratio = 0.37 } });
        check("ui.workspace schema accepts resize and saves the split ratio", Math.Abs((windowState.Layout(terminalId).Root?.Ratio ?? 0) - 0.37) < 0.001);
        await Workspace(new { windowAction = new { action = "one", windowId = terminalId, ownerSessionId = terminalId } });
        var chatView = chatPanes[chatId];
        await Runtime.Door.CallAsync(caller.Id, "windows.pop_out", JsonSerializer.SerializeToElement(new { sessionId = chatId }));
        await Task.Delay(250);
        var chatHost = windowState.Get(chatId).Host;
        check("chat pops into its own native window with the same retained view", chatHost != "main" && detached.TryGetValue(chatHost, out var chatChild) && Verification.W10Proof.Tree(chatChild.Root).Contains(chatView));
        check("chat file picker resolves the child HWND", detached.TryGetValue(chatHost, out var child) && ChatWindowHandle(chatId) == WinRT.Interop.WindowNative.GetWindowHandle(child.Window) && ChatWindowHandle(chatId) != WindowHandle);
        await Runtime.Door.CallAsync(caller.Id, "windows.pop_out", JsonSerializer.SerializeToElement(new { sessionId = chatId, display = "dock" }));
        check("chat docks without replacing its view and restores main HWND", windowState.Get(chatId).Host == "main" && ReferenceEquals(chatPanes[chatId], chatView) && ChatWindowHandle(chatId) == WindowHandle);
        var browserView = browser.ShellView(browserId); var retainedPages = browser.TabCount;
        await Workspace(new { windowAction = new { action = "pop-out", windowId = browserId } });
        await Task.Delay(250);
        var browserHost = windowState.Get(browserId).Host;
        check("browser pops with the same retained WebView wrapper", browserHost != "main" && detached.TryGetValue(browserHost, out var browserChild) && Verification.W10Proof.Tree(browserChild.Root).Contains(browserView) && browser.TabCount == retainedPages);
        await Workspace(new { windowAction = new { action = "dock", windowId = browserId } });
        check("browser docks without opening another page", windowState.Get(browserId).Host == "main" && ReferenceEquals(browser.ShellView(browserId), browserView) && browser.TabCount == retainedPages);
        // The owner is a real, signed-out chat record. Attachment is scratch
        // metadata only; it never starts the chat or grants a website access.
        await browser.Core.AttachAsync(browserId, chatId); browser.ObserveShellPages(); SyncWindows();
        W10SelectSession(chatId);
        await Workspace(new { windowAction = new { action = "pop-session", windowId = chatId } });
        await Task.Delay(250);
        var sessionHosts = windowState.Tabs.Where(t => t.Owner == chatId).Select(t => t.Host).Distinct().ToArray();
        check("pop session moves chat and attached browser together", sessionHosts.Length == 1 && sessionHosts[0] != "main" && windowState.Get(browserId).Host == windowState.Get(chatId).Host);
        await Workspace(new { windowAction = new { action = "dock", windowId = browserId } });
        await Workspace(new { windowAction = new { action = "dock", windowId = chatId } });
        check("all session windows return with unique tab identities", detached.Count == 0 && windowState.Tabs.Select(t => t.Id).Distinct().Count() == windowState.Tabs.Count);
        var shown = await Workspace(new { settingsSection = "accounts", settingsPresentation = "window" });
        check("Settings tool opens the detached Who uses what page", shown.GetProperty("settingsPresentation").GetString() == "window" && settingsWindow is not null && settings.SelectedSection == "Who uses what");
        shown = await Workspace(new { settingsPresentation = "panel" });
        await Task.Delay(200);
        check("Legacy panel tool focuses the same native Settings window", shown.GetProperty("settingsPresentation").GetString() == "window" && settingsWindow is not null && settingsPanel?.SelectedCategory == "coding-ais" && settings.SelectedSection == "Who uses what");
        await Workspace(new { settingsPresentation = "closed" });
        check("Settings tool closes the panel", settingsWindow is null);
      }
      finally
      {
        Runtime.CallerAuthority.Revoke(Runtime.Door, "w10-scratch-proof");
        foreach (var id in windowState.Tabs.Where(t => t.Host != "main").Select(t => t.Id).ToArray()) DockTab(id);
        W10CloseSettings();
      }
    }
    internal IReadOnlyDictionary<string, bool> W10ShellAssertions(bool settingsShown)
    {
      var header = Verification.W10Proof.Tree(WorkspaceHeader).OfType<Button>().Select(AutomationProperties.GetName).ToArray();
      var tabs = windowState.Tabs.Where(t => t.Host == "main").ToArray();
      var hosted = Verification.W10Proof.Tree(Workspace).OfType<ContentControl>().Where(c => c.Tag as string == "workspace-view").ToArray();
      return new Dictionary<string, bool>
      {
        ["one 40 DIP title bar"] = ExtendsContentIntoTitleBar && Math.Abs(TitleBarRow.ActualHeight - 40) < 1,
        ["all retained window tabs appear in the global header"] = WorkspaceHeader.Visibility == Visibility.Visible && tabs.All(t => header.Contains(t.Title)),
        ["native caption space reserved"] = CaptionSpace.ActualWidth >= 138,
        ["legacy browser engine is hidden at 1x1"] = BrowserEngineHost.Width == 1 && BrowserEngineHost.Height == 1 && BrowserEngineHost.Opacity == 0 && !BrowserEngineHost.IsHitTestVisible,
        ["one real workspace host"] = Workspace.Children.Count == 1 && (hosted.Length == 0 || hosted.All(c => c.Content is FrameworkElement)),
        ["no detached native window or island created"] = detached.Count == 0 && (settingsShown || settingsWindow is null),
        ["Hoot lives in the normal sidebar and header"] = windowState.Tabs.Any(t => t.Id == "page:Hoot") && Verification.W10Proof.Tree(NavigationRoutes).OfType<ButtonBase>().Any(b => AutomationProperties.GetName(b) == "Hoot"),
        ["Settings uses its own native window"] = !settingsShown || settingsWindow is not null && settingsPanel!.ActualWidth >= 680
      };
    }
  }
}
