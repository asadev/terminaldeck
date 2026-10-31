using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private ContentDialog? shellDialog;
  private bool ShellModalOpen => IsShellModalOpen(Root.XamlRoot);
  private bool IsShellModalOpen(XamlRoot root)
  {
    if (taskPopupOverlay?.XamlRoot == root || shellDialog?.XamlRoot == root || accountSheet?.XamlRoot == root || TerminalDeck.App.Views.Agents.NewSessionPicker.ActiveDialogForProof?.XamlRoot == root) return true;
    var popups = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(root);
    for (var index = 0; index < popups.Count; index++)
      if (popups[index].Child is { } child && ProofTree(child).OfType<ContentDialog>().Any()) return true;
    return false;
  }
  private bool swarm;
  private readonly Dictionary<string, double> viewZoom = [];
  private WorkspaceTab? FocusedTab(string host = "main")
  {
    var layout = host == "main" ? windowState.Layout(Scope) : detached.TryGetValue(host, out var child) ? windowState.Layout(child.Owner, host) : null;
    var active = layout?.ActiveEmpty is null ? layout?.Active : null;
    return windowState.Tabs.FirstOrDefault(t => t.Id == active);
  }
  private void InitializeShellCommands(FrameworkElement target, string host = "main")
  {
    // OEM chords such as Ctrl+/ are listed in our shortcut sheet. WinUI's
    // automatic tooltip formatter cannot name those virtual keys reliably.
    target.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
    foreach (var command in ShellCommands.All.Where(c => c.Shortcut.Length > 0))
      Install(command.Id, command.Shortcut);
    Install("quick-open", "Ctrl+Shift+O"); Install("palette", "Ctrl+Shift+P");
    // Ctrl+B belongs to terminal/readline; the sidebar alias is only for native controls.
    var sidebarAlias = new KeyboardAccelerator { Key = VirtualKey.B, Modifiers = VirtualKeyModifiers.Control };
    sidebarAlias.Invoked += (_, args) =>
    {
      var focused = FocusManager.GetFocusedElement(target.XamlRoot);
      if (focused is WebView2 || focused is TextBox) return;
      SidebarToggle_Click(this, new()); args.Handled = true;
    };
    target.KeyboardAccelerators.Add(sidebarAlias);
    void Install(string id, string chord)
    {
      var key = chord.Split('+')[^1];
      var code = key switch { "F2" => 113, "," => 188, "\\" => 220, "/" => 191, "=" => 187, "-" => 189, _ => key.Length == 1 ? char.ToUpperInvariant(key[0]) : 0 };
      var shortcut = new KeyboardAccelerator { Key = (VirtualKey)code, Modifiers = (chord.Contains("Ctrl", StringComparison.Ordinal) ? VirtualKeyModifiers.Control : VirtualKeyModifiers.None) | (chord.Contains("Shift", StringComparison.Ordinal) ? VirtualKeyModifiers.Shift : VirtualKeyModifiers.None) };
      shortcut.Invoked += async (_, args) =>
      {
        args.Handled = true;
        if (IsShellModalOpen(target.XamlRoot)) return;
        await RunShellCommandGuardedAsync(id, host);
      };
      target.KeyboardAccelerators.Add(shortcut);
    }
  }
  private async Task RunShellCommandGuardedAsync(string id, string host = "main")
  {
    try { await RunShellCommandAsync(id, host); }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { Model.Notice = ex is ArgumentException or InvalidOperationException or IOException ? ex.Message : "The command could not finish. Try again."; }
  }
  private async Task RunShellCommandAsync(string id, string host = "main", TerminalDeck.Core.Mcp.McpCallContext? caller = null)
  {
    var tab = FocusedTab(host);
    var target = host == "main" ? Root : detached[host].Root;
    switch (id)
    {
      case "new-session": NewSession_Click(this, new()); break;
      case "new-chat": await CreateWindowAsync(tab?.Owner ?? "", "chat", host); break;
      case "settings": ShowSettingsPanel(); break;
      case "rename-session":
        if (tab is null || tab.Kind == "page") throw new InvalidOperationException("Choose a session or browser tab to rename.");
        await RenameWindowAsync(tab.Id); break;
      case "session-delete-confirmation":
        var ask = new ToggleSwitch { Header = "Ask before deleting open sessions", IsOn = sidebar.Read.ConfirmDelete };
        var confirm = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Deleting sessions", Content = ask, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await ShowShellDialogAsync(confirm) == ContentDialogResult.Primary) sidebar.AskBeforeDelete(ask.IsOn); break;
      case "sidebar": SidebarToggle_Click(this, new()); break;
      case "palette": await ShowCommandPaletteAsync(target, host); break;
      case "quick-open": await ShowQuickOpenAsync(target, tab); break;
      case "search-sessions": await ShowSessionSearchAsync(target); break;
      case "inspector": await ShowSessionInspectorAsync(target, tab); break;
      case "split": await ShowSplitPickerAsync(target, tab, host); break;
      case "one-pane":
        if (tab is null) break;
        var owner = ManualLayoutOwner(tab);
        if (windowState.Layout(owner, host).Root?.Tab is null) windowState.One(tab.Id, owner, host); else windowState.RestoreSplit(owner, host); break;
      case "swarm": ShowSwarm(); break;
      case "actual-size": case "zoom-in": case "zoom-out": await ZoomFocusedViewAsync(target, tab, id); break;
      case "open-project": Model.Page = ShellPage.Projects; await Projects.OpenProjectPickerAsync(); break;
      case "project-overview":
        var project = tab is null || tab.Kind == "page" ? Projects.Model.SelectedId : Runtime.Projects.Resolve(null, WindowFolder(tab));
        if (project is null) throw new InvalidOperationException("Choose a project or one of its sessions first.");
        Projects.OpenProject(project, "Overview"); Model.Page = ShellPage.Projects; break;
      case "artifacts": Model.Page = ShellPage.Artifacts; break;
      case "files": Model.Page = ShellPage.Files; break;
      case "source-control": Model.Page = ShellPage.SourceControl; break;
      case "github": Model.Page = ShellPage.GitHub; break;
      case "return-windows": if (tab is not null) DockOwner(tab.Owner); break;
      case "shortcuts": await ShowShortcutsAsync(target); break;
      case "help": await ShowHelpAsync(target); break;
      case "diagnostics": await ShowDiagnosticsAsync(target); break;
      case "retry-connection": await RetryShellConnectionAsync(); break;
      case "show-log": await OpenShellLogAsync(); break;
      case "about": await OpenSettingsAsync("about"); break;
      case "report":
        if (!await Launcher.LaunchUriAsync(new Uri("https://terminaldeck.dev/support.html"))) throw new InvalidOperationException("The support page could not open. Try again."); break;
      case "resume":
        var folder = tab is null ? Model.Selected?.Folder : WindowFolder(tab);
        var recent = Model.Sessions.LastOrDefault(s => s.Folder == folder && !sidebar.Read.HiddenSessions.Contains(s.Id) && s.State is not ("ended" or "exited"));
        if (recent is null) throw new InvalidOperationException("No open conversation can be resumed in this folder. Saved provider history is not available here yet.");
        SelectSessionWindow(recent); break;
      case "exit": closingShell = true; Close(); break;
      case "stop-exit":
        var answer = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Stop all and exit?", Content = "This stops every running terminal and ends open chats in this app’s data folder. Project files and saved conversation history stay on disk.", PrimaryButtonText = "Stop all and exit", CloseButtonText = "Keep working", DefaultButton = ContentDialogButton.Close };
        if (await ShowShellDialogAsync(answer) != ContentDialogResult.Primary) break;
        foreach (var row in Runtime.Sessions.Where(s => s.State is TerminalDeck.Core.Sessions.SessionState.Running or TerminalDeck.Core.Sessions.SessionState.Starting))
        { if (caller is not null) { caller.Require("sessions", row.Definition.Id); await caller.EnsureCurrentAsync(CancellationToken.None); } await Runtime.StopAsync(row.Definition.Id); }
        foreach (var chat in Runtime.Chats.List().Where(c => !c.Ended))
        { if (caller is not null) { caller.Require("sessions", chat.Definition.Id); await caller.EnsureCurrentAsync(CancellationToken.None); } await Runtime.Chats.EndAsync(chat.Definition.Id); }
        closingShell = true; Close(); break;
      default: throw new ArgumentException("Choose a command from the palette.");
    }
  }
  private async Task<ContentDialogResult> ShowShellDialogAsync(ContentDialog dialog)
  {
    if (shellDialog is not null) return ContentDialogResult.None;
    shellDialog = dialog;
    try { return await dialog.ShowAsync(); } finally { shellDialog = null; }
  }
  private async Task ShowCommandPaletteAsync(FrameworkElement target, string host)
  {
    var query = new TextBox { PlaceholderText = "Search commands", MinWidth = 400 }; AutomationProperties.SetName(query, "Search commands");
    var list = new ListView { DisplayMemberPath = "Title", MaxHeight = 400, SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    var empty = new TextBlock { Text = "No matching commands", Visibility = Visibility.Collapsed, Opacity = 0.7 };
    void Search() { var results = ShellCommands.Matching(query.Text).ToArray(); list.ItemsSource = results; list.SelectedIndex = results.Length > 0 ? 0 : -1; empty.Visibility = results.Length == 0 ? Visibility.Visible : Visibility.Collapsed; }
    query.TextChanging += (_, _) => Search(); Search();
    var content = new StackPanel { Spacing = 12 }; content.Children.Add(query); content.Children.Add(list); content.Children.Add(empty);
    var dialog = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Command Palette", Content = content, CloseButtonText = "Close" };
    ShellCommand? picked = null;
    void Pick() { picked = list.SelectedItem as ShellCommand; if (picked is not null && !ShellCommands.Matching(query.Text).Any(command => command.Id == picked.Id)) picked = null; if (picked is not null) dialog.Hide(); }
    list.ItemClick += (_, args) => { list.SelectedItem = args.ClickedItem; Pick(); };
    query.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { Pick(); args.Handled = true; } else if (args.Key == VirtualKey.Down) { list.Focus(FocusState.Keyboard); args.Handled = true; } };
    list.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { Pick(); args.Handled = true; } };
    dialog.Opened += (_, _) => query.Focus(FocusState.Keyboard);
    await ShowShellDialogAsync(dialog);
    if (picked is not null && picked.Id != "palette") await RunShellCommandAsync(picked.Id, host);
  }
  private async Task ShowShortcutsAsync(FrameworkElement target)
  {
    var shortcuts = string.Join('\n', ShellCommands.All.Where(c => c.Shortcut.Length > 0).Select(c => c.Shortcut + "   " + c.Title)) + "\nCtrl+Shift+P   Command Palette\nCtrl+Shift+O   Quick Open\nCtrl+Tab / Ctrl+Shift+Tab   Next / Previous tab\nCtrl+1–9   Select tab\nCtrl+Alt+Left / Right   Previous / Next pane\nCtrl+Alt+Up / Down   Previous / Next sidebar row\nCtrl+W   Close Tab (keeps the process)\nCtrl+C / Escape   Passed to the focused terminal\n\nSettings (when open)\nCtrl+F   Search Settings\nEscape   Close Settings\nTab / Shift+Tab   Move between controls\nArrow keys   Move through categories";
    await ShowTextDialogAsync(target, "Keyboard Shortcuts", shortcuts);
  }
  private Task ShowHelpAsync(FrameworkElement target) => ShowTextDialogAsync(target, "Help", "Start with New session. Use More to open or pin pages. Right-click tabs to split, move or close them. Session actions include Pin, Rename, Attach browser, Stop and Delete. Closing a tab keeps its process. Settings opens in its own window.\n\nCtrl+K opens the Command Palette. Ctrl+/ shows every shortcut. Search for Ask before deleting sessions to turn that confirmation back on.");
  private Task ShowTextDialogAsync(FrameworkElement target, string title, string text) => ShowShellDialogAsync(new ContentDialog
  { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = title, CloseButtonText = "Done", Content = new ScrollViewer { MaxHeight = 480, Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, MaxWidth = 600 } } });
  private async Task ShowDiagnosticsAsync(FrameworkElement target)
  {
    var report = $"Sessions: {Runtime.Sessions.Count}\nChats: {Runtime.Chats?.List().Count ?? 0}\nRelay: {Runtime.Remote.State}\nOpen app windows: {1 + detached.Count}\nLog: logs/errors.log in this app’s data folder\n\nReconnect only refreshes the connection. It does not restart running sessions.";
    var dialog = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Setup & Diagnostics", Content = new TextBlock { Text = report, TextWrapping = TextWrapping.Wrap }, PrimaryButtonText = "Reconnect", CloseButtonText = "Done" };
    if (await ShowShellDialogAsync(dialog) == ContentDialogResult.Primary) { Model.Notice = "Reconnecting…"; await Runtime.ReconnectAsync(); await Runtime.RefreshSessionsAsync(); Model.Notice = "Connected."; }
  }
  private async Task ShowSplitPickerAsync(FrameworkElement target, WorkspaceTab? tab, string host)
  {
    if (tab is null || tab.Kind == "page") throw new InvalidOperationException("Choose a session or browser tab to split.");
    var owner = host == "main" ? Scope : detached[host].Owner;
    var peers = windowState.Tabs.Where(t => t.Host == host && t.Kind != "page" && !(windowState.Layout(owner, host).Root?.Tabs.Contains(t.Id) ?? false)).ToArray();
    if (peers.Length == 0) throw new InvalidOperationException("Open another session or browser tab first.");
    var picker = new ComboBox { ItemsSource = peers, DisplayMemberPath = "Title", SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var direction = new ComboBox { ItemsSource = new[] { "Side by side", "Above and below" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var form = new StackPanel { Spacing = 12 }; form.Children.Add(picker); form.Children.Add(direction);
    var dialog = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Split the Window", Content = form, PrimaryButtonText = "Split", CloseButtonText = "Cancel" };
    if (await ShowShellDialogAsync(dialog) == ContentDialogResult.Primary) { swarm = false; windowState.Split(tab.Id, ((WorkspaceTab)picker.SelectedItem).Id, direction.SelectedIndex == 1, owner, host); }
  }
  private void ShowSwarm()
  {
    swarm = !swarm;
    if (swarm)
    {
      foreach (var row in Model.Sessions.Where(row => row.State is not ("ended" or "exited") && !sidebar.Read.HiddenSessions.Contains(row.Id))) EnsureSessionTab(row);
      var ids = windowState.Tabs.Where(t => t.Kind is "terminal" or "chat" && Model.Sessions.Any(row => row.Id == t.Subject && row.State is not ("ended" or "exited") && !sidebar.Read.HiddenSessions.Contains(row.Id))).Select(t => t.Id).ToArray();
      windowState.Swarm(ids); workspaceOwner = "swarm"; Model.Page = ShellPage.Sessions;
    }
    else { workspaceOwner = Model.Selected is { } row ? windowState.OwnerOf(row.Id) : ""; }
    renderedWindowsStructure = ""; RenderWindows();
    if (FocusedTab() is { } focused) { FocusWindow(swarm ? "swarm" : focused.Owner, focused.Id); mainSurface.FocusInput(focused.Id); }
  }
  private void LeaveSwarm()
  {
    if (!swarm) return;
    var active = FocusedTab(); swarm = false;
    workspaceOwner = active?.Owner ?? (Model.Selected is { } row ? windowState.OwnerOf(row.Id) : "");
    if (active is not null && windowState.Layout(workspaceOwner).Root?.Tabs.Contains(active.Id) != true) windowState.One(active.Id, workspaceOwner);
    renderedWindowsStructure = ""; RenderWindows();
  }
  private string ManualLayoutOwner(WorkspaceTab tab)
  {
    if (tab.Host != "main") return detached[tab.Host].Owner;
    LeaveSwarm(); return windowState.Layout(Scope).Root?.Tabs.Contains(tab.Id) == true ? Scope : tab.Owner;
  }
  private async Task ZoomFocusedViewAsync(FrameworkElement target, WorkspaceTab? tab, string command)
  {
    if (tab is null) throw new InvalidOperationException("Choose a browser, terminal or chat view first.");
    var content = WindowView(tab); var web = ProofTree(content).OfType<WebView2>().FirstOrDefault();
    if (web?.CoreWebView2 is null) throw new InvalidOperationException("The focused view has no web content to zoom.");
    var zoom = command == "actual-size" ? 1 : Math.Clamp(viewZoom.GetValueOrDefault(tab.Id, 1) + (command == "zoom-in" ? 0.1 : -0.1), 0.5, 2);
    await web.CoreWebView2.CallDevToolsProtocolMethodAsync("Emulation.setPageScaleFactor", JsonSerializer.Serialize(new { pageScaleFactor = zoom })); viewZoom[tab.Id] = zoom;
  }
}
