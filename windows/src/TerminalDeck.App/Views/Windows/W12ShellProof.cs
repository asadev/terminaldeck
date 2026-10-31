using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RunW12ShellProofAsync()
  {
    var output = Environment.GetEnvironmentVariable("TD_W12_SHELL_PROOF")!;
    var marker = Path.Combine(dataRoot.DirectoryPath, ".w12-shell-allow");
    if (!dataRoot.DirectoryPath.StartsWith(@"C:\TD-W12Shell\", StringComparison.OrdinalIgnoreCase) || !File.Exists(marker) || File.ReadAllText(marker).Trim() != "W12 SHELL SCRATCH ONLY" || !Path.GetFullPath(output).StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("W12 needs a marked, isolated scratch root.");
    Directory.CreateDirectory(output);
    var passed = new List<string>(); var failed = new List<string>(); var frames = new List<object>();
    var stage = "entry"; string? scratchSession = null;
    void Stage(string value) { stage = value; File.WriteAllText(Path.Combine(output, "stage.txt"), value); }
    void Check(string name, bool ok) { (ok ? passed : failed).Add(name); }
    async Task VisibleTerminalsReady()
    {
      Root.UpdateLayout(); foreach (var child in detached.Values) child.Root.UpdateLayout(); await Task.Delay(40);
      var surfaces = new[] { mainSurface }.Concat(detached.Values.Select(child => child.Surface));
      await Task.WhenAll(surfaces.SelectMany(surface => ProofTree(surface).OfType<SessionPane>()).Where(pane => pane.Draft.Presentation == SessionPresentation.Terminal).Select(pane => pane.Ready)).WaitAsync(TimeSpan.FromSeconds(30));
    }
    async Task Capture(FrameworkElement root, string name)
    {
      Model.Notice = ""; await Task.Delay(180); root.UpdateLayout(); await VisibleTerminalsReady();
      try { frames.Add(await Verification.W10Proof.CaptureAsync(root, output, name, root.ActualTheme.ToString().ToLowerInvariant(), (name.StartsWith("browser-loading", StringComparison.Ordinal) ? "Real loading component in a readiness fixture; not a delayed backend trace" : "Synthetic drafts, a real signed-out chat record and retained local start page; no provider process or message"), Stage)); }
      catch (TimeoutException) { failed.Add(name + ": native WebView capture timed out; no replacement image was accepted."); }
    }
    try
    {
      await Ready; Stage("fixtures"); Model.Notice = "";
      Check("native popup lookup leaves shortcuts available without a dialog", !IsShellModalOpen(Root.XamlRoot));
      foreach (var page in browser.Core.Read().Tabs.ToArray()) await browser.Core.CloseAsync(page.Id);
      SyncWindows(); AppWindow.Resize(new(1280, 840)); await Capture(Root, "tabs-count-1");
      var folder = Path.Combine(Path.GetDirectoryName(dataRoot.DirectoryPath)!, "fixture-project"); Directory.CreateDirectory(folder);
      var project = Runtime.Projects.Create("Shell review", folder);
      var a = Model.AddDraft("codex", folder, SessionPresentation.Terminal); a.Rename("Release review"); a.SetAppearance("Shell review", null, "Reviewer");
      SelectSessionWindow(a); await Capture(Root, "tabs-count-2");
      var chatRecord = await Runtime.Chats.CreateAsync("claude", folder, Runtime.Accounts.List("claude").Single().Id); SyncSessions();
      var b = Model.Sessions.Single(row => row.Id == chatRecord.Definition.Id); b.Rename("Layout checks"); b.SetAppearance("Shell review", null, "Designer");
      windowState.Rename(b.Id, "Layout checks");
      SelectSessionWindow(a); await VisibleTerminalsReady();
      await CreateWindowAsync(a.Id, "browser"); var browserId = windowState.Tabs.Last(t => t.Kind == "browser").Id;
      for (var i = 0; i < 18; i++)
      {
        var row = Model.AddDraft(i % 2 == 0 ? "codex" : "claude", folder, SessionPresentation.Terminal); row.Rename("Review " + (i + 3));
        if (windowState.Tabs.Count(t => t.Host == "main") == 10) await Capture(Root, "tabs-count-10");
      }
      SelectSessionWindow(a); SyncWindows();
      Check("20 session tabs and one browser stay retained", windowState.Tabs.Count(t => t.Kind is "terminal" or "chat") == 20 && windowState.Tabs.Any(t => t.Id == browserId));
      var resources = windowState.Tabs.Where(tab => tab.Kind != "page")
        .Select(tab => (tab.Kind == "browser" ? "browser:" : "sessions:") + tab.Subject).Append("settings:workspace").Distinct().ToArray();
      var caller = Runtime.CallerAuthority.Provision(Runtime.Door, new("w12-shell-proof", null, null, AiPermissionMode.Ask,
        ["windows.list", "windows.pop_out", "ui.workspace", "shell.read"], [McpTier.Read, McpTier.Act], resources), _ => true);
      using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
      var rpcId = 0;
      async Task<JsonElement> Rpc(McpRegistration registration, string method, object args)
      {
        using var request = new HttpRequestMessage(HttpMethod.Post, tools!.Address);
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", registration.Token);
        request.Content = new StringContent(JsonSerializer.Serialize(new { jsonrpc = "2.0", id = ++rpcId, method, @params = args }), System.Text.Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request); response.EnsureSuccessStatusCode();
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        if (body.RootElement.TryGetProperty("error", out _)) throw new InvalidOperationException("The scratch MCP request was refused at the protocol boundary.");
        return body.RootElement.GetProperty("result").Clone();
      }
      await Rpc(caller, "initialize", new { protocolVersion = "2025-03-26" });
      var wireRead = await Rpc(caller, "tools/call", new { name = "shell_read", arguments = new { kind = "sidebar" } });
      Check("authenticated MCP HTTP caller reaches shell reads", !wireRead.GetProperty("isError").GetBoolean());
      var sidebarBefore = sidebarVisible;
      var wireChange = await Rpc(caller, "tools/call", new { name = "ui_workspace", arguments = new { shellCommand = "sidebar" } });
      Check("connected caller uses granted shell command without owner impersonation", !wireChange.GetProperty("isError").GetBoolean() && sidebarVisible != sidebarBefore);
      await Rpc(caller, "tools/call", new { name = "ui_workspace", arguments = new { shellCommand = "sidebar" } });
      var scoped = Runtime.CallerAuthority.Provision(Runtime.Door, new("w12-scoped-proof", a.Id, null, AiPermissionMode.Ask,
        ["ui.workspace"], [McpTier.Read, McpTier.Act], ["settings:workspace", "sessions:" + a.Id]), _ => true);
      await Rpc(scoped, "initialize", new { protocolVersion = "2025-03-26" });
      var refused = await Rpc(scoped, "tools/call", new { name = "ui_workspace", arguments = new { windowAction = new { action = "select", windowId = b.Id } } });
      Check("authenticated scoped caller cannot select another session", refused.GetProperty("isError").GetBoolean());
      Runtime.CallerAuthority.Revoke(Runtime.Door, "w12-scoped-proof");
      var read = await Runtime.Door.CallAsync(caller.Id, "shell.read", JsonSerializer.SerializeToElement(new { kind = "sidebar" }));
      Check("read tool reaches the integrated door and returns all eight scoped pages", read.GetProperty("pages").GetArrayLength() == 8);
      foreach (var page in SidebarState.Catalogue)
        await Runtime.Door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { sidebarAction = new { action = "pin-page", pageId = page.Id, pinned = true } }));
      Check("all More pins update the rail and Projects section", PinnedPageRows.Children.Count == 7 && ProjectsSection.Visibility == Visibility.Visible);
      sidebar.Pin("Tasks", false); sidebar.MovePage("Mcp", "Agents");
      Check("one pin toggles independently and order changes", !sidebar.Pinned("Tasks") && sidebar.Read.Pages[0] == "Mcp" && sidebar.Pinned("Agents"));
      sidebar.PinSession(b.Id, true); Check("session pins do not alter page pins or duplicate rows", sidebarSessions[0].Id == b.Id && sidebarSessions.Select(r => r.Id).Distinct().Count() == sidebarSessions.Count);
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        SetTheme(theme); Stage("tabs-" + theme);
        foreach (var width in new[] { 800, 1280, 1700 })
        {
          AppWindow.Resize(new(width, 840)); await Task.Delay(200); Root.UpdateLayout();
          var chips = ProofTree(mainSurface.Header).OfType<Grid>().Where(g => g.Height == 35 && g.CornerRadius.TopLeft == 6).ToArray();
          var origin = WorkspaceHeader.TransformToVisual(Root).TransformPoint(new(0, 0)).X;
          Check(theme + " " + width + " every tab has a finite visible share", chips.Length == windowState.Tabs.Count(t => t.Host == "main") && chips.All(g => g.ActualWidth > 0 && double.IsFinite(g.ActualWidth)));
          Check(theme + " " + width + " strip starts after sidebar", origin >= SidebarColumn.ActualWidth);
          Check(theme + " " + width + " no strip ScrollViewer or trailing window menu", !ProofTree(mainSurface.Header).OfType<ScrollViewer>().Any() && !ProofTree(mainSurface.Header).OfType<Button>().Any(button => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(button) == "Window actions"));
          await Capture(Root, "tabs-" + width);
        }
        sidebar.Geometry(340, false); await Capture(Root, "sidebar-hidden"); sidebar.Geometry(264, true);
        AppWindow.Resize(new(1280, 840));
        windowState.Split(a.Id, browserId); windowState.Split(browserId, b.Id, true, a.Id); SelectSessionWindow(a);
        Stage("split-" + theme); await VisibleTerminalsReady();
        Check(theme + " nested split retains three native view owners", ProofTree(mainSurface).OfType<ContentControl>().Count(c => c.Tag as string == "workspace-view" && c.Content is not null) == 3);
        windowState.Focus(b.Id, a.Id); FocusWindow(a.Id, b.Id); Check(theme + " focused split session selects its own sidebar row", SessionList.SelectedItem == b);
        await Capture(Root, "split");
        var arrangement = windowState.Layout(a.Id).Root; windowState.One(b.Id, a.Id); Check(theme + " restore split preserves arrangement", windowState.RestoreSplit(a.Id) && windowState.Layout(a.Id).Root == arrangement);
        windowState.EmptySplit(a.Id, owner: a.Id); var emptyPane = windowState.Layout(a.Id).Root!.EmptyIds.Single(); windowState.FocusEmpty(a.Id, "main", emptyPane); mainSurface.FocusInput(emptyPane);
        Check(theme + " empty pane keeps its own focus target", SessionList.SelectedItem is null && windowState.Layout(a.Id).ActiveEmpty == emptyPane);
        await Task.Delay(250); Root.UpdateLayout();
        Check(theme + " empty pane retains focus after native layout settles", SessionList.SelectedItem is null && windowState.Layout(a.Id).ActiveEmpty == emptyPane);
        await Capture(Root, "empty-pane"); windowState.ClosePane(a.Id, "main", emptyPane);
        Check(theme + " closing empty pane preserves underlying arrangement", windowState.Layout(a.Id).Root == arrangement);
        MorePages_Click(this, new()); await Capture(Root, "more-pins");
        var moreContent = (FrameworkElement)morePagesFlyout!.Content; morePagesFlyout.Content = null;
        var menuHost = new Border { Child = moreContent, Width = 280, Padding = new(12), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new(16), CornerRadius = new(12) };
        menuHost.SetResourceReference(Border.BackgroundProperty, "DeckGlassBrush"); Grid.SetColumnSpan(menuHost, 2); Grid.SetRowSpan(menuHost, 2); Root.Children.Add(menuHost);
        try
        {
          await Task.Delay(100); menuHost.UpdateLayout();
          var pins = ProofTree(moreContent).OfType<ToggleButton>().Where(pin => pin.Tag is string).ToArray();
          Check(theme + " every More page has an independent accessible pin", pins.Length == 8 && pins.All(pin => pin.IsTabStop && AutomationProperties.GetName(pin).Length > 0));
          var pin = pins[0]; var pageId = (string)pin.Tag; var beforePin = sidebar.Pinned(pageId); var beforePage = Model.Page;
          var toggle = (IToggleProvider)new ToggleButtonAutomationPeer(pin).GetPattern(PatternInterface.Toggle);
          toggle.Toggle(); Check(theme + " actual pin control updates state without navigating", sidebar.Pinned(pageId) != beforePin && Model.Page == beforePage); toggle.Toggle();
          var persisted = new TerminalDeck.Core.Storage.JsonStateStore<SidebarSaved>(dataRoot, "sidebar").Load();
          Check(theme + " sidebar order and pin choices are persisted on disk", persisted is not null && persisted.Pages.SequenceEqual(sidebar.Read.Pages) && persisted.SessionPins.SequenceEqual(sidebar.Read.SessionPins));
          await Capture(menuHost, "more-menu");
        }
        finally { Root.Children.Remove(menuHost); menuHost.Child = null; morePagesFlyout.Content = moreContent; }
        ShowSettingsPanel(); await Task.Delay(180);
        var settingsIdentity = settingsWindow; ShowSettingsPanel();
        Check(theme + " repeated Settings opens focus the same native window", ReferenceEquals(settingsIdentity, settingsWindow));
        Check(theme + " Settings is one native window with no overlay or pop-out button", settingsWindow is not null && !ProofTree(settingsPanel!).OfType<Button>().Any(button => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(button).Contains("own window", StringComparison.Ordinal)));
        await Capture(settingsWindowRoot!, "settings");
        var sized = await Runtime.Door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsBounds = new { x = 20, y = 20, width = 720, height = 520 } }));
        Check(theme + " Settings bounds tool changes the real native window", Math.Abs(sized.GetProperty("settingsBounds").GetProperty("Width").GetDouble() - 720) < 2 && settingsWindow!.AppWindow.Size.Width == (int)Math.Round(720 * WindowScale(settingsWindow)));
        await Capture(settingsWindowRoot!, "settings-sized"); CloseSettingsPanel();
        foreach (var destination in new[] { ShellPage.Devices, ShellPage.Mcp })
        {
          OpenSidebarPage(destination.ToString()); await Task.Delay(100); Root.UpdateLayout();
          Check(theme + " " + destination + " opens its retained main-page editor", ProofTree(Root).Contains(ConnectionPage(destination)));
          await Capture(Root, "page-" + destination.ToString().ToLowerInvariant());
        }
        SelectSessionWindow(a);
      }
      Stage("loading-states");
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        SetTheme(theme); var loader = new WorkspaceLoadingView(browser: true); Grid.SetColumn(loader, 1); Grid.SetRow(loader, 1); Root.Children.Add(loader);
        try { await Capture(loader, "browser-loading"); } finally { Root.Children.Remove(loader); }
      }
      Stage("grouped-window-focus");
      var auxiliary = Model.AddDraft("shell", folder, SessionPresentation.Terminal); windowState.Adopt(auxiliary.Id, a.Id); SelectSessionWindow(auxiliary); FocusWindow(a.Id, auxiliary.Id);
      Check("a grouped terminal keeps its owning sidebar session selected", SessionList.SelectedItem == a);
      await CloseWindowAsync(auxiliary.Id); Model.CloseDraft(auxiliary); SelectSessionWindow(a);
      Stage("page-pop-out"); Model.Page = ShellPage.Agents; var agentPage = Agents;
      var pagePop = await Rpc(caller, "tools/call", new { name = "ui_workspace", arguments = new { windowAction = new { action = "pop-out", windowId = "page:Agents" } } });
      Check("authenticated MCP page pop-out reaches the real window controller", !pagePop.GetProperty("isError").GetBoolean());
      var agentHost = windowState.Get("page:Agents").Host;
      await Task.Delay(100); detached[agentHost].Root.UpdateLayout(); Root.UpdateLayout();
      Check("page pop-out moves the same retained page", agentHost != "main" && ProofTree(detached[agentHost].Root).Contains(agentPage) && !ProofTree(Root).Contains(agentPage));
      await Capture(detached[agentHost].Root, "detached-agents");
      ShellProofNative.SendMessage(WindowHandle, 0x112, new(0xF060), 0); await Task.Delay(60);
      Check("closing main keeps the detached editor and shared runtime alive", mainWindowHidden && !closingShell && detached.ContainsKey(agentHost) && ReferenceEquals(Agents, agentPage));
      await Rpc(caller, "tools/call", new { name = "ui_workspace", arguments = new { windowAction = new { action = "dock", windowId = "page:Agents" } } }); await Task.Delay(100); Root.UpdateLayout();
      Check("move back reveals the same main window", !mainWindowHidden && AppWindow.IsVisible);
      Check("return page keeps one editor in main", ProofTree(Root).Count(node => ReferenceEquals(node, agentPage)) == 1);
      Stage("browser-pop-out"); SelectSessionWindow(a); var wrapper = browser.ShellView(browserId);
      var browserPop = await Rpc(caller, "tools/call", new { name = "windows_pop_out", arguments = new { sessionId = browserId } });
      Check("authenticated MCP browser pop-out reaches the retained page", !browserPop.GetProperty("isError").GetBoolean());
      var browserHost = windowState.Get(browserId).Host;
      await Task.Delay(100); detached[browserHost].Root.UpdateLayout(); Root.UpdateLayout();
      Check("browser pop-out moves retained wrapper without a second page", ProofTree(detached[browserHost].Root).Contains(wrapper) && !ProofTree(Root).Contains(wrapper));
      await Capture(detached[browserHost].Root, "detached-browser"); await Rpc(caller, "tools/call", new { name = "windows_pop_out", arguments = new { sessionId = browserId, display = "dock" } });
      await CloseWindowAsync(b.Id); SyncWindows(); Check("closing a tab stays closed through a runtime sync and keeps sidebar session", !windowState.Tabs.Any(t => t.Id == b.Id) && sidebarSessions.Contains(b));
      Check("closed tab remains closed in persisted restart model", new WorkspaceState(new(windowState.Tabs.ToArray(), windowState.Layouts.ToArray(), [b.Id])).IsClosed(b.Id));
      Stage("layout-save-failure");
      var stateFile = Path.Combine(dataRoot.DirectoryPath, "state", "shell-windows.json"); var attributes = File.GetAttributes(stateFile); var beforeWindows = detached.Count; var refusedSave = false;
      try
      {
        File.SetAttributes(stateFile, attributes | FileAttributes.ReadOnly);
        try { PopTab(a.Id); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { refusedSave = true; }
        Check("failed layout save rolls back ownership and leaves no ghost window", refusedSave && windowState.Get(a.Id).Host == "main" && detached.Count == beforeWindows);
      }
      finally { File.SetAttributes(stateFile, attributes); }
      Stage("scratch-shell-survival");
      var shell = await Runtime.StartShellForProjectAsync(folder, project.Id); scratchSession = shell.Definition.Id; SyncSessions();
      var live = Model.Sessions.Single(s => s.Id == shell.Definition.Id); SelectSessionWindow(live);
      Root.UpdateLayout(); await sessionPanes[live.Id].Ready.WaitAsync(TimeSpan.FromSeconds(30));
      var before = Runtime.Sessions.Single(s => s.Definition.Id == live.Id);
      await sessionPanes[live.Id].InputForProofAsync("Write-Output 'W12-SHELL-SURVIVAL'");
      await Task.Delay(400); await Runtime.RefreshSessionsAsync();
      PopTab(live.Id); var liveHost = windowState.Get(live.Id).Host;
      var after = Runtime.Sessions.Single(s => s.Definition.Id == live.Id);
      Check("scratch PowerShell keeps process lease and creation identity after pop-out", before.LeaseIdentity is not null && before.LeaseIdentity == after.LeaseIdentity && before.CreationKey == after.CreationKey);
      await Capture(detached[liveHost].Root, "detached-live-shell"); DockTab(live.Id);
      await CloseWindowAsync(live.Id); await Runtime.RefreshSessionsAsync();
      Check("closing the scratch PowerShell tab leaves its keeper process running", Runtime.Sessions.Any(s => s.Definition.Id == live.Id && s.State == TerminalDeck.Core.Sessions.SessionState.Running));
      SelectSessionWindow(live); await Runtime.RefreshSessionsAsync();
      Check("reopening the scratch shell returns the same process and retained output", Runtime.Sessions.Single(s => s.Definition.Id == live.Id).LeaseIdentity == before.LeaseIdentity && Runtime.Sessions.Single(s => s.Definition.Id == live.Id).Replay.Contains("W12-SHELL-SURVIVAL", StringComparison.Ordinal));
      Stage("terminal-key-pass-through");
      await sessionPanes[live.Id].InputForProofAsync("Write-Output 'W12-KEYS-READY'; [Console]::TreatControlCAsInput=$true; $first=[Console]::ReadKey($true); $second=[Console]::ReadKey($true); Write-Output ('W12-KEYS:'+[int]$first.KeyChar+','+[int]$second.KeyChar); [Console]::TreatControlCAsInput=$false");
      await Task.Delay(400);
      var web = ProofTree(sessionPanes[live.Id]).OfType<WebView2>().Single();
      foreach (var type in new[] { "keyDown", "keyUp" }) await web.CoreWebView2.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", JsonSerializer.Serialize(new { type, key = "c", code = "KeyC", windowsVirtualKeyCode = 67, modifiers = 2 }));
      foreach (var type in new[] { "keyDown", "keyUp" }) await web.CoreWebView2.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", JsonSerializer.Serialize(new { type, key = "Escape", code = "Escape", windowsVirtualKeyCode = 27 }));
      await Task.Delay(500); await Runtime.RefreshSessionsAsync();
      Check("Ctrl+C and Escape pass from the focused retained terminal to its own ConPTY", Runtime.Sessions.Single(s => s.Definition.Id == live.Id).Replay.Contains("W12-KEYS:3,27", StringComparison.Ordinal));
      Stage("shell-read-dialogs");
      async Task<ContentDialog> DialogReady(string? title = null)
      {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
        while (shellDialog is null || title is not null && shellDialog.Title?.ToString() != title)
        { if (DateTimeOffset.UtcNow > deadline) throw new TimeoutException("The scratch dialog did not open."); await Task.Delay(20); }
        await Task.Delay(80); Root.UpdateLayout(); return shellDialog;
      }
      async Task UiResult(Func<bool> ready)
      {
        var until = DateTimeOffset.UtcNow.AddSeconds(10);
        while (!ready()) { if (DateTimeOffset.UtcNow > until) throw new TimeoutException("The current query did not finish."); await Task.Delay(20); }
      }
      var paletteTask = ShowCommandPaletteAsync(Root, "main"); var palette = await DialogReady("Command Palette");
      var query = ProofTree((DependencyObject)palette.Content).OfType<TextBox>().Single();
      var choices = ProofTree((DependencyObject)palette.Content).OfType<ListView>().Single();
      query.Text = "no-command-matches-w12"; await UiResult(() => choices.Items.Count == 0); Check("palette shows a real empty result", choices.Items.Count == 0);
      query.Text = "Inspector"; await UiResult(() => choices.Items.Count == 1 && choices.SelectedItem is ShellCommand { Id: "inspector" }); Check("palette filters actual command catalogue", choices.Items.Count == 1 && choices.SelectedItem is ShellCommand { Id: "inspector" });
      await Capture(palette, "command-palette"); palette.Hide(); await paletteTask;
      File.WriteAllText(Path.Combine(folder, "w12-first.txt"), "First fixture file");
      var quickTask = ShowQuickOpenAsync(Root, windowState.Get(live.Id)); var quick = await DialogReady("Quick Open");
      var fileQuery = ProofTree((DependencyObject)quick.Content).OfType<TextBox>().Single();
      var files = ProofTree((DependencyObject)quick.Content).OfType<ListView>().Single();
      File.WriteAllText(Path.Combine(folder, "w12-new.txt"), "W12 quick open preview"); fileQuery.Text = "w12-new";
      var fileDeadline = DateTimeOffset.UtcNow.AddSeconds(10);
      while (files.Items.Count != 1 || files.Items[0] is not QuickFile { RelativePath: "w12-new.txt" })
      { if (DateTimeOffset.UtcNow > fileDeadline) throw new TimeoutException("Quick Open did not refresh its results."); await Task.Delay(20); }
      Check("Quick Open sees a file added after opening the picker", true);
      await Capture(quick, "quick-open"); files.UpdateLayout();
      if (files.ContainerFromItem(files.Items[0]) is not ListViewItem fileContainer) throw new InvalidOperationException("The Quick Open row was not realized.");
      if (new ListViewItemAutomationPeer(fileContainer).GetPattern(PatternInterface.Invoke) is not IInvokeProvider fileInvoke) throw new InvalidOperationException("The Quick Open row has no native invoke action.");
      fileInvoke.Invoke();
      var preview = await DialogReady("w12-new.txt");
      Check("Quick Open invokes the actual readonly file preview", preview.Content is TextBox { IsReadOnly: true, Text: "W12 quick open preview" });
      await Capture(preview, "file-preview"); preview.Hide(); await quickTask;
      var searchTask = ShowSessionSearchAsync(Root); var search = await DialogReady("Search Sessions");
      var sessionQuery = ProofTree((DependencyObject)search.Content).OfType<TextBox>().Single(); sessionQuery.Text = "W12-SHELL-SURVIVAL";
      await UiResult(() => ProofTree((DependencyObject)search.Content).OfType<ListView>().Single().Items.Count > 0);
      Check("session search uses real retained terminal output", ProofTree((DependencyObject)search.Content).OfType<ListView>().Single().Items.Count > 0);
      await Capture(search, "session-search"); search.Hide(); await searchTask;
      var inspectorTask = ShowSessionInspectorAsync(Root, windowState.Get(live.Id)); var inspector = await DialogReady("Session Inspector");
      Check("inspector names its actual source and unknown measurements", ProofTree((DependencyObject)inspector.Content).OfType<TextBlock>().Any(text => text.Text.Contains("keeper record", StringComparison.Ordinal) && text.Text.Contains("not supplied", StringComparison.Ordinal)));
      await Capture(inspector, "session-inspector"); inspector.Hide(); await inspectorTask;
      var shortcutsTask = ShowShortcutsAsync(Root); var shortcuts = await DialogReady("Keyboard Shortcuts");
      await Capture(shortcuts, "shortcuts"); shortcuts.Hide(); await shortcutsTask;
      await Runtime.Chats.EndAsync(b.Id); SyncSessions();
      Check("ended chat is archived separately without reopening its closed tab", archivedSessions.Any(row => row.Id == b.Id) && !windowState.Tabs.Any(tab => tab.Id == b.Id));
      var senderTask = ReviewBrowserSendAsync("W12 browser draft", null, a.Id, Root.XamlRoot); var sender = await DialogReady("Send browser context");
      var sendDraft = ProofTree((DependencyObject)sender.Content).OfType<TextBox>().Single(); sendDraft.Text = "W12 edited unsent browser draft";
      Check("browser review keeps sending disabled without an available AI", !sender.IsPrimaryButtonEnabled);
      await Capture(sender, "browser-send-empty"); sender.Hide(); Check("browser review cancellation does not claim delivery", !await senderTask);
      senderTask = ReviewBrowserSendAsync("W12 browser draft", null, a.Id, Root.XamlRoot); sender = await DialogReady("Send browser context");
      Check("browser review restores the edited unsent draft", ProofTree((DependencyObject)sender.Content).OfType<TextBox>().Single().Text == "W12 edited unsent browser draft"); sender.Hide(); await senderTask;
      await Runtime.StopAsync(live.Id);
      Runtime.CallerAuthority.Revoke(Runtime.Door, "w12-shell-proof");
      Stage("complete");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add(stage + ": " + ex); }
    finally
    {
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, stage, passed, failed, frames, limitations = new[] { "Synthetic drafts, one signed-out chat record and one disposable PowerShell in the marked scratch folder. No provider commands, sign-in, spend or live-data edits.", "Rendered native controls with actual WebView capture substitution; OS caption and real pointer/keyboard/DPI interactions are not established by these frames.", "More frames host the real menu content inside the scratch window; native popup placement/focus remains unverified." } }, new JsonSerializerOptions { WriteIndented = true }));
      if (scratchSession is not null)
      {
        try { await Runtime.StopAsync(scratchSession); } catch (Exception ex) when (ex is not OutOfMemoryException) { UiRecovery.Log("W12 owned shell cleanup", ex); }
      }
      closingShell = true; Close();
    }
  }
}
