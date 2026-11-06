using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TerminalDeck.App.Views.Chat;

public sealed partial class ChatPage
{
  private ContentDialog? currentDialog;
  private long renderSerial;
  private bool findNavigationPending;
  private int? searchWindowStart;
  private sealed record CachedRow(ChatRow Row, string Query, bool Stopping, string MediaKey, FrameworkElement Element);
  private readonly Dictionary<string, CachedRow> rowCache = [];
  private readonly HashSet<string> expandedRows = [];
  private void RetainExpansion(Expander view, string key)
  {
    view.IsExpanded = expandedRows.Contains(key);
    view.RegisterPropertyChangedCallback(Expander.IsExpandedProperty, (_, _) => { if (view.IsExpanded) expandedRows.Add(key); else expandedRows.Remove(key); });
  }
  private readonly TextBlock controlFeedback = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
  private readonly Button permission = new() { MaxWidth = 170 };
  private readonly StackPanel searchBar = new() { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
  private readonly TextBox searchBox = new() { PlaceholderText = "Find in conversation", MinWidth = 160, MaxWidth = 300 };
  private readonly TextBlock searchCount = new() { VerticalAlignment = VerticalAlignment.Center };
  private readonly Button unread = new() { Content = "New messages", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center };
  private readonly StackPanel promptSummary = new() { Spacing = 4, Visibility = Visibility.Collapsed };
  private readonly Dictionary<string, FrameworkElement> messageElements = [];
  private IReadOnlyList<ChatMatch> matches = [];
  private int selectedMatch = -1;
  private string? firstUnreadKey;
  private string[] renderedKeys = [];
  private bool renderedBusy;
  private string renderedLastText = "";

  private void SetupConversationTools(StackPanel heading)
  {
    Model.ControlRequested += control =>
    {
      switch (control)
      {
        case "sideQuestion": _ = ShowSideQuestionAsync(); break;
        case "connections": _ = ShowProviderDetailsAsync("Connections", "mcp_servers"); break;
        case "skills": _ = ShowProviderDetailsAsync("Skills", "skills"); break;
        case "instructions": _ = ShowProviderDetailsAsync("Instructions & sources", "instructionSources"); break;
        case "commands": _ = ShowProviderDetailsAsync("Commands", "slash_commands"); break;
        case "editorCopy": _ = OpenPrivateEditorAsync(); break;
        case "commandOutput": _ = ShowCommandOutputAsync(); break;
        case "inspector": _ = ShowInspectorAsync(); break;
        case "history": _ = ShowHistoryAsync(); break;
        case "changes": _ = ShowChangesAsync(); break;
        case "rename": _ = ShowRenameAsync(); break;
        case "model": _ = ShowModelsAsync(); break;
        case "effort": ShowEffort(); break;
        case "account": ShowAccounts(); break;
        case "permission": ShowPermissions(); break;
        case "environment": _ = ShowEnvironmentAsync(); break;
        case "fullPrompt": _ = EditFullPromptAsync(); break;
        case "promptSearch": _ = ShowPromptSearchAsync(); break;
        case "eventLog": _ = ShowEventsAsync(); break;
        case "usage": _ = ShowUsageAsync(); break;
        case "modelTiming": _ = ShowModelTimingAsync(); break;
        case "find": OpenSearch(); break;
      }
    };
    var info = Button("Session info", ShowInspectorAsync);
    ChatAppearance.IconButton(info, "\uE946", "Session info"); // Kept for MCP; hidden in chat.
    var commandOutput = Button("Command output", ShowCommandOutputAsync);
    ChatAppearance.IconButton(commandOutput, "\uE756", "Command output from this chat"); // Kept for MCP; hidden in chat.
    var changes = Button("Changes", ShowChangesAsync);
    ChatAppearance.IconButton(changes, "\uE8EF", "Recorded changes"); // Kept for MCP; hidden in chat.
    foreach (var control in heading.Children.OfType<Button>())
    { control.Width = control.Height = control.MinWidth = control.MinHeight = 26; control.CornerRadius = new CornerRadius(8); }
    var more = new Button { Content = "More", MinHeight = 32 };
    AutomationProperties.SetName(more, "Chat actions");
    var menu = new MenuFlyout();
    void Item(string name, Func<Task> action)
    { var item = new MenuFlyoutItem { Text = name }; item.Click += async (_, _) => await action(); menu.Items.Add(item); }
    Item("Side question…", ShowSideQuestionAsync);
    if (ChatBranchActions.Invoke is not null) Item("Fork, worktree and location…", ShowBranchesAsync);
    Item("Past chats…", ShowHistoryAsync);
    Item("Rename…", ShowRenameAsync);
    Item("Copy complete recorded transcript", () => { CopyText(ChatText.Export(Model.Snapshot)); return Task.CompletedTask; });
    Item("Search recorded prompts…", ShowPromptSearchAsync);
    Item("Environment and permissions…", ShowEnvironmentAsync);
    Item("Provider connections…", () => ShowProviderDetailsAsync("Connections", "mcp_servers"));
    Item("Skills…", () => ShowProviderDetailsAsync("Skills", "skills"));
    Item("Instructions & sources…", () => ShowProviderDetailsAsync("Instructions & sources", "instructionSources"));
    Item("Commands…", () => ShowProviderDetailsAsync("Commands", "slash_commands"));
    Item("Model switch timing…", ShowModelTimingAsync);
    Item("Usage report…", ShowUsageAsync);
    Item("Event log…", ShowEventsAsync);
    Item("Chat shortcuts…", () => ShowTextAsync("Chat shortcuts", "Return — Send or queue a message\nShift+Return — New line\n↑ — Recall previous prompt from an empty composer\n↑ / ↓ — Recall prompts at the end of an unchanged recalled prompt\nCtrl+F — Find in conversation\nCtrl+G / Ctrl+Shift+G — Next / previous match\nCtrl+. — Stop this chat’s active answer\nCtrl+Shift+/ — This shortcut sheet\nEscape — Close conversation search"));
    Item("Find in conversation…", () => { OpenSearch(); return Task.CompletedTask; });
    Item("End chat…", EndChatAsync);
    ChatAppearance.IconButton(more, "\uE712", "Chat actions");
    more.Width = more.Height = more.MinWidth = more.MinHeight = 26; more.CornerRadius = new CornerRadius(8);
    more.Flyout = menu; // Kept for MCP; hidden in chat.
    searchBar.Children.Add(searchBox); searchBar.Children.Add(searchCount);
    searchBar.Children.Add(Button("Previous", () => { MoveMatch(-1); return Task.CompletedTask; }));
    searchBar.Children.Add(Button("Next", () => { MoveMatch(1); return Task.CompletedTask; }));
    searchBar.Children.Add(Button("Close search", () => { CloseSearch(); return Task.CompletedTask; }));
    ObserveText(searchBox, () => { selectedMatch = -1; Render(); MoveMatch(1); });
    searchBox.KeyDown += (_, e) =>
    {
      if (e.Key == VirtualKey.Enter) { MoveMatch(IsKeyPressed(VirtualKey.Shift) ? -1 : 1); e.Handled = true; }
      else if (e.Key == VirtualKey.Escape) { CloseSearch(); e.Handled = true; }
    };
    unread.Click += (_, _) =>
    {
      var key = firstUnreadKey; firstUnreadKey = null; unread.Visibility = Visibility.Collapsed;
      if (key is null) { scroll.ChangeView(null, scroll.ScrollableHeight, null, true); return; }
      findNavigationPending = true;
      if (!messageElements.ContainsKey(key)) { visibleMessages = Math.Max(visibleMessages, Model.Rows.Count - Model.Rows.ToList().FindIndex(r => r.Kind + ":" + r.Id == key)); Render(); }
      ++renderSerial;
      EventHandler<object>? reveal = null;
      reveal = (_, _) =>
      {
        Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= reveal; UpdateLayout(); scroll.UpdateLayout();
        if (messageElements.TryGetValue(key, out var target)) scroll.ChangeView(null, Math.Max(0, target.TransformToVisual(messages).TransformPoint(new Windows.Foundation.Point(0, 0)).Y - scroll.ViewportHeight * 0.2), null, true);
        findNavigationPending = false;
      };
      Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += reveal;
    };
    permission.Click += (_, _) => ShowPermissions();
    AutomationProperties.SetAutomationId(permission, "chat.permission");
    AutomationProperties.SetAutomationId(searchBox, "chat.find");
    AutomationProperties.SetAutomationId(unread, "chat.unread");
    AddHandler(KeyDownEvent, new Microsoft.UI.Xaml.Input.KeyEventHandler(async (_, e) =>
    {
      if (e.Key == VirtualKey.F2) { e.Handled = true; await ShowRenameAsync(); return; }
      if (!IsKeyPressed(VirtualKey.Control)) return;
      if (e.Key == VirtualKey.F) { OpenSearch(); e.Handled = true; }
      else if (e.Key == VirtualKey.G) { if (searchBar.Visibility != Visibility.Visible) OpenSearch(); MoveMatch(IsKeyPressed(VirtualKey.Shift) ? -1 : 1); e.Handled = true; }
      else if (e.Key == (VirtualKey)190 && Model.Snapshot.Busy) { e.Handled = true; await Model.StopAsync(); }
      else if (e.Key == (VirtualKey)191 && IsKeyPressed(VirtualKey.Shift)) { e.Handled = true; await ShowTextAsync("Chat shortcuts", "Return: send/queue · Shift+Return: newline\n↑/↓: prompt history (eligible caret only)\nCtrl+F: find · Ctrl+G / Ctrl+Shift+G: next/previous\nCtrl+.: stop this answer · Escape: close search"); }
    }), true);
  }
  private static bool IsKeyPressed(VirtualKey key) => (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
  private void OpenSearch() { searchBar.Visibility = Visibility.Visible; searchBox.Focus(FocusState.Programmatic); searchBox.SelectAll(); }
  private void CloseSearch() { searchWindowStart = null; searchBar.Visibility = Visibility.Collapsed; searchBox.Text = ""; Render(); composer.Focus(FocusState.Programmatic); }
  private void UpdateSearchMatches()
  {
    matches = searchBar.Visibility == Visibility.Visible ? ChatText.Find(Model.Snapshot, searchBox.Text) : [];
    if (selectedMatch >= matches.Count) selectedMatch = matches.Count - 1;
    searchCount.Text = matches.Count == 0 ? "0 matches" : (selectedMatch + 1) + " of " + matches.Count;
  }
  private void MoveMatch(int direction)
  {
    UpdateSearchMatches(); if (matches.Count == 0) return;
    selectedMatch = selectedMatch < 0 ? direction > 0 ? 0 : matches.Count - 1 : (selectedMatch + direction + matches.Count) % matches.Count;
    var match = matches[selectedMatch]; findNavigationPending = true;
    if (!messageElements.ContainsKey(match.RowId)) { searchWindowStart = Math.Max(0, Model.Rows.ToList().FindIndex(r => r.Kind + ":" + r.Id == match.RowId) - 40); Render(); }
    searchCount.Text = (selectedMatch + 1) + " of " + matches.Count;
    ++renderSerial;
    EventHandler<object>? afterLayout = null;
    afterLayout = (_, _) =>
    {
      Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= afterLayout;
      UpdateLayout(); scroll.UpdateLayout();
      if (messageElements.TryGetValue(match.RowId, out var target))
      {
        var point = target.TransformToVisual(messages).TransformPoint(new Windows.Foundation.Point(0, 0));
        scroll.ChangeView(null, Math.Max(0, point.Y - scroll.ViewportHeight * 0.2), null, true);
      }
      findNavigationPending = false;
    };
    Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += afterLayout;
  }
  private RichTextBlock SearchText(string text)
  {
    var view = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 13.5 };
    view.Blocks.Add(new Paragraph { Inlines = { new Run { Text = text } } });
    var highlighter = new TextHighlighter();
    for (var at = 0; searchBox.Text.Length > 0 && at <= text.Length - searchBox.Text.Length;)
    {
      var found = text.IndexOf(searchBox.Text, at, StringComparison.OrdinalIgnoreCase); if (found < 0) break;
      highlighter.Ranges.Add(new TextRange { StartIndex = found, Length = searchBox.Text.Length }); at = found + searchBox.Text.Length;
    }
    view.TextHighlighters.Add(highlighter); return view;
  }
  private void PrepareUnread(bool nearBottom)
  {
    var keys = Model.Rows.Select(r => r.Kind + ":" + r.Id).ToArray();
    if (nearBottom) { firstUnreadKey = null; unread.Visibility = Visibility.Collapsed; }
    else if (renderedKeys.Length > 0)
    {
      var added = keys.FirstOrDefault(k => !renderedKeys.Contains(k));
      if (added is not null || Model.Snapshot.Busy && renderedBusy && Model.Rows.LastOrDefault()?.Text != renderedLastText)
      { firstUnreadKey ??= added ?? keys.LastOrDefault(); unread.Visibility = Visibility.Visible; }
    }
    renderedKeys = keys; renderedBusy = Model.Snapshot.Busy; renderedLastText = Model.Rows.LastOrDefault()?.Text ?? "";
  }
  private static void CopyText(string text) { var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); }
  private void ShowLinkError(string message) => _ = Model.RunAsync(() => throw new InvalidOperationException(message));
  private async Task<ContentDialogResult> ShowChatDialogAsync(ContentDialog dialog)
  {
    if (currentDialog is not null)
    { await Model.RunAsync(() => throw new InvalidOperationException("Close the open chat dialog before opening another one.")); return ContentDialogResult.None; }
    currentDialog = dialog;
    try { return await dialog.ShowAsync(); }
    finally { currentDialog = null; }
  }
  private Task ShowTextAsync(string caption, string text) => ShowContentAsync(caption, Words(text));
  private async Task ShowContentAsync(string caption, UIElement content)
  {
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = caption, Content = new ScrollViewer { Content = content, MaxHeight = 520, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }, CloseButtonText = "Done" };
    await ShowChatDialogAsync(dialog);
  }
  private async Task EndChatAsync()
  {
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "End this chat?", Content = "The active answer will stop. Queued messages will stay held and recorded history will be kept. Any unsent draft is still in this window.", PrimaryButtonText = "End chat", CloseButtonText = "Keep it open", DefaultButton = ContentDialogButton.Close };
    if (await ShowChatDialogAsync(dialog) == ContentDialogResult.Primary) await Model.EndAsync();
  }
  private void ShowPermissions()
  {
    var menu = new MenuFlyout();
    foreach (var mode in ChatPermissionModes.Supported(Model.Snapshot.Definition.Provider))
    {
      var item = new ToggleMenuFlyoutItem { Text = ChatPermissionModes.Label(mode) + " — " + ChatPermissionModes.Explain(mode), IsChecked = mode == Model.ShownPermission };
      item.Click += async (_, _) => await Model.SetPermissionAsync(mode);
      menu.Items.Add(item);
    }
    menu.ShowAt(permission);
  }
  private async Task ShowRenameAsync()
  {
    var source = Model.Snapshot.Definition.Title;
    var input = new TextBox { Text = source[..Math.Min(source.Length, 40)], MaxLength = 40, Header = "Session title", MinWidth = 240 };
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Rename session", Content = input, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    if (await ShowChatDialogAsync(dialog) == ContentDialogResult.Primary) await Model.RenameAsync(input.Text);
  }
  private async Task ShowModelTimingAsync()
  {
    var reported = ChatProviderSnapshot.Read(Model.Snapshot);
    var saved = Model.Snapshot.Definition.Options.Model is { Length: > 0 } modelId ? modelId : "Not selected";
    var requested = Model.RequestedModel is null ? "No model request in this view" : Model.RequestedModel.Length == 0 ? "Not selected" : Model.RequestedModel;
    var body = new StackPanel { Spacing = 12 };
    body.Children.Add(Words("Requested model: " + requested + "\nSaved model: " + saved + "\nProvider-confirmed applied model: " + (reported.Model ?? "Not reported") + (reported.ModelAt is { } at && at != default ? " · reported " + at.ToLocalTime().ToString("g") : "") + ".\n\nSaved model and effort choices take effect on the next message. Changing these choices reopens the chat worker and keeps the recorded conversation."));
    var open = false;
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Model switch", Content = body, CloseButtonText = "Done" };
    body.Children.Add(Button("Open Chat model control", () => { open = true; dialog.Hide(); return Task.CompletedTask; }));
    await ShowChatDialogAsync(dialog); if (open) await ShowModelsAsync();
  }
  private Task ShowProviderDetailsAsync(string title, string field)
  {
    var reading = ChatProviderSnapshot.Read(Model.Snapshot); var panel = new StackPanel { Spacing = 12 }; var feedback = new Notices.CompactNotice();
    panel.Children.Add(Words("Source: this chat’s provider report. App integrations are separate.", 12));
    if (!reading.Current || reading.Fields is not { } fields || !fields.TryGetProperty(field, out var items) || items.ValueKind != System.Text.Json.JsonValueKind.Array)
      panel.Children.Add(Words("This worker has not reported " + title.ToLowerInvariant() + ". Earlier workers’ reports are kept separate."));
    else
    {
      panel.Children.Add(Words(items.GetArrayLength() + " reported · " + reading.At.ToLocalTime().ToString("g"), 12));
      if (field == "mcp_servers") panel.Children.Add(Words("To reconnect or sign in: " + items.EnumerateArray().Count(item => ChatLineProtocol.S(item, "status") is "failed" or "needs-auth"), 12));
      foreach (var item in items.EnumerateArray())
      {
        var row = new StackPanel { Spacing = 6 };
        var name = item.ValueKind == System.Text.Json.JsonValueKind.String ? item.GetString()! : ChatLineProtocol.S(item, "name");
        if (name.Length == 0) name = ChatLineProtocol.S(item, "id");
        if (name.Length == 0) name = ChatLineProtocol.S(item, "path");
        row.Children.Add(Words(name.Length > 0 ? name : "Recorded entry"));
        foreach (var key in new[] { "status", "description", "path", "source", "authStatus", "argumentHint" })
          if (ChatLineProtocol.S(item, key) is { Length: > 0 } detail) row.Children.Add(Words((key switch { "authStatus" => "Sign-in status", "argumentHint" => "Arguments", "path" => "Path", "source" => "Source", "status" => "Status", _ => "Description" }) + ": " + detail, 12));
        if (field == "instructionSources" && name.Length > 0)
        {
          var path = name;
          row.Children.Add(Button("Open in editor", async () =>
          {
            await Model.RunAsync(() =>
            {
              if (!Path.IsPathFullyQualified(path) || !File.Exists(path)) throw new InvalidOperationException("This recorded instruction file is not available on this PC.");
              OpenTextEditor(path); return ValueTask.CompletedTask;
            }); feedback.Text = Model.Error ?? "Instruction file opened.";
          }));
        }
        if (field == "slash_commands")
        {
          var unavailable = ChatLineProtocol.P(item, "terminalOnly").ValueKind == System.Text.Json.JsonValueKind.True || ChatLineProtocol.P(item, "supportsChat").ValueKind == System.Text.Json.JsonValueKind.False;
          if (unavailable) row.Children.Add(Words("Unavailable in Chat", 12));
          else if (name.Length > 0)
          {
            var command = ChatLineProtocol.S(item, "command"); if (command.Length == 0) command = name.StartsWith('/') ? name : "/" + name;
            row.Children.Add(Button("Prepare command", () => { Model.Draft += (Model.Draft.Length > 0 ? "\n" : "") + command; currentDialog?.Hide(); return Task.CompletedTask; }));
          }
        }
        panel.Children.Add(row);
      }
      if (items.GetArrayLength() == 0) panel.Children.Add(Words("None reported for this chat."));
    }
    panel.Children.Add(feedback); return ShowContentAsync(title, panel);
  }
  private Task ShowEnvironmentAsync()
  {
    var definition = Model.Snapshot.Definition; var provider = ChatProviderSnapshot.Read(Model.Snapshot);
    return ShowTextAsync("Environment and permissions", "AI: " + ChatAppearance.ProviderName(definition.Provider) + "\nAccount: " + Model.AccountName + "\nProject folder: " + definition.Cwd + "\nMode: Chat\nApp choice: " + ChatPermissionModes.Label(definition.PermissionMode) + "\n\nProvider-reported model: " + (provider.Model ?? "Not reported") + "\nProvider-reported sandbox: " + ChatProviderSnapshot.Describe(provider, "sandboxPolicy") + "\nProvider-reported approval policy: " + ChatProviderSnapshot.Describe(provider, "approvalPolicy") + "\nProvider-reported permission mode: " + ChatProviderSnapshot.Describe(provider, "permissionMode") + "\nWorkspace trust: " + ChatProviderSnapshot.Describe(provider, "workspaceTrust") + "\nNetwork policy: " + ChatProviderSnapshot.Describe(provider, "networkAccess") + "\n\nRecorded messages: " + Model.Rows.Count(r => r.Kind is "user" or "assistant") + "\nRecorded tools: " + Model.Rows.Count(r => r.Kind == "tool") + "\nContext usage: Not reported\nMemory owner: Not reported");
  }
  private void UpdatePromptSummary()
  {
    var bytes = ChatText.PromptBytes(Model.Draft); promptSummary.Children.Clear();
    promptSummary.Visibility = bytes > 4096 ? Visibility.Visible : Visibility.Collapsed;
    if (bytes <= 4096) return;
    promptSummary.Children.Add(Words("Large prompt · " + bytes + " / 262144 UTF-8 bytes", 12));
    promptSummary.Children.Add(Button("Edit full prompt…", EditFullPromptAsync));
  }
  private static void OpenTextEditor(string path)
  {
    try
    {
      var editor = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "notepad.exe");
      var launch = new System.Diagnostics.ProcessStartInfo(editor) { UseShellExecute = true }; launch.ArgumentList.Add(path);
      System.Diagnostics.Process.Start(launch);
    }
    catch (System.ComponentModel.Win32Exception) { throw new InvalidOperationException("Windows could not open its text editor. The file and draft are kept."); }
  }
  private Task OpenPrivateEditorAsync(string? text = null, ChatEditorSource? source = null) => Model.RunAsync(async () =>
  {
    var copy = await Model.PrepareEditorCopyAsync(text, source);
    OpenTextEditor(copy.Path);
  });
  private async Task EditFullPromptAsync()
  {
    var source = Model.Draft; var sourceRevision = Model.DraftRevision; var sourceConversation = Model.Snapshot.ConversationId;
    var editor = new TextBox { Text = source, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinWidth = 260, MinHeight = 240, MaxHeight = 480 };
    var count = Words("", 12); var error = new Notices.CompactNotice(); var panel = new StackPanel { Spacing = 8 };
    panel.Children.Add(editor); panel.Children.Add(count); panel.Children.Add(error);
    panel.Children.Add(Button("Open private copy in editor", async () =>
    { await OpenPrivateEditorAsync(editor.Text, new(sourceRevision, sourceConversation)); error.Text = Model.Error ?? "Private copy opened. Save it, then import the saved copy. Files and mention chips stay in this draft."; }));
    panel.Children.Add(Button("Import saved editor copy", async () =>
    {
      await Model.RunAsync(() => Model.ImportEditorCopyAsync());
      if (Model.Error is null) { editor.Text = Model.Draft; source = Model.Draft; sourceRevision = Model.DraftRevision; sourceConversation = Model.Snapshot.ConversationId; }
      error.Text = Model.Error ?? "Saved editor copy imported into the unsent draft.";
    }));
    panel.Children.Add(Button("Discard editor copy", async () =>
    { await Model.RunAsync(() => { Model.DiscardEditorCopy(); return ValueTask.CompletedTask; }); error.Text = Model.Error ?? "Private editor copy discarded. The draft is kept."; }));
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Edit full prompt", Content = panel, PrimaryButtonText = "Apply to draft", CloseButtonText = "Cancel" };
    void Validate() { var bytes = ChatText.PromptBytes(editor.Text); count.Text = bytes + " / 262144 UTF-8 bytes · files stay in the original draft."; dialog.IsPrimaryButtonEnabled = bytes <= ChatText.MaximumPromptBytes && !editor.Text.Contains('\0'); }
    ObserveText(editor, Validate); Validate();
    dialog.PrimaryButtonClick += (_, e) =>
    {
      try { ChatText.ValidatePrompt(editor.Text); } catch (ArgumentException ex) { error.Text = ex.Message; e.Cancel = true; return; }
      if (Model.DraftRevision != sourceRevision || Model.Snapshot.ConversationId != sourceConversation || Model.Snapshot.Ended) { error.Text = "The source draft or chat changed. Close this editor and open the current draft."; e.Cancel = true; return; }
      Model.ApplyDraft(editor.Text, sourceRevision); UpdatePromptSummary();
    };
    await ShowChatDialogAsync(dialog);
  }
  private Task ShowPromptSearchAsync()
  {
    var panel = new StackPanel { Spacing = 8 }; var query = new TextBox { PlaceholderText = "Search recorded user prompts" }; var results = new StackPanel { Spacing = 8 };
    panel.Children.Add(query); panel.Children.Add(results);
    ContentDialog? dialog = null;
    void Refresh()
    {
      results.Children.Clear();
      foreach (var text in ChatText.Prompts(Model.Snapshot).Where(t => t.Contains(query.Text, StringComparison.OrdinalIgnoreCase)))
      {
        var row = new StackPanel { Spacing = 4 }; row.Children.Add(Words(text));
        row.Children.Add(Button("Insert into draft", () => { Model.Draft += (Model.Draft.Length > 0 ? "\n\n" : "") + text; dialog?.Hide(); composer.Focus(FocusState.Programmatic); return Task.CompletedTask; })); results.Children.Add(row);
      }
      if (results.Children.Count == 0) results.Children.Add(Words("No matching prompts."));
    }
    ObserveText(query, Refresh); Refresh();
    dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Recorded prompts", Content = new ScrollViewer { Content = panel, MaxHeight = 480 }, CloseButtonText = "Done" };
    return AwaitDialog();
    async Task AwaitDialog() { await ShowChatDialogAsync(dialog); }
  }
  private Task ShowUsageAsync()
  {
    var panel = new StackPanel { Spacing = 12 };
    panel.Children.Add(Words("Provider-reported token and cost figures. These are separate from account limits and your bill.", 12));
    var reports = Model.Snapshot.Events.Where(e => e.Kind == "usage" && e.Data.HasValue).GroupBy(e => e.Id).Select(g => g.Last()).ToArray();
    foreach (var entry in reports)
    {
      panel.Children.Add(Words(entry.At.ToLocalTime().ToString("g"), 12));
      panel.Children.Add(Words(System.Text.Json.JsonSerializer.Serialize(entry.Data, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }), 12));
    }
    if (reports.Length == 0) panel.Children.Add(Words("No usage figures have been reported for this recorded chat."));
    panel.Children.Add(Words("Repeated updates for the same report are shown once. Cumulative thread totals are not added across turns.", 12));
    return ShowContentAsync("Chat usage report", panel);
  }
  private Task ShowEventsAsync()
  {
    var panel = new StackPanel { Spacing = 8 }; var filter = new TextBox { PlaceholderText = "Search recorded events" }; var results = new StackPanel { Spacing = 8 }; var count = Words("", 12);
    panel.Children.Add(filter); panel.Children.Add(count); var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; panel.Children.Add(actions); panel.Children.Add(results);
    var page = 0;
    var previous = new Button { Content = "Previous", MinHeight = 32 }; var next = new Button { Content = "Next", MinHeight = 32 };
    previous.Click += (_, _) => { page--; Refresh(); }; next.Click += (_, _) => { page++; Refresh(); }; actions.Children.Add(previous); actions.Children.Add(next);
    void Refresh()
    {
      results.Children.Clear(); var events = Model.Snapshot.Events.Where(e => (e.Sequence + " " + e.Id + " " + e.ClientId + " " + e.Kind + " " + e.Text + " " + e.Data?.GetRawText()).Contains(filter.Text, StringComparison.OrdinalIgnoreCase)).ToArray();
      page = Math.Clamp(page, 0, Math.Max(0, (events.Length - 1) / 40)); var offset = page * 40;
      count.Text = events.Length == 0 ? "0 recorded events" : (offset + 1) + "–" + Math.Min(offset + 40, events.Length) + " of " + events.Length + " recorded events";
      previous.IsEnabled = page > 0; next.IsEnabled = offset + 40 < events.Length;
      foreach (var entry in events.Skip(offset).Take(40))
      {
        var text = System.Text.Json.JsonSerializer.Serialize(entry, new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
        var row = new StackPanel { Spacing = 4 }; row.Children.Add(Words(text, 12)); row.Children.Add(Button("Copy record", () => { CopyText(text); return Task.CompletedTask; })); results.Children.Add(row);
      }
      if (events.Length == 0) results.Children.Add(Words("No matching recorded events."));
    }
    ObserveText(filter, () => { page = 0; Refresh(); }); Refresh(); return ShowContentAsync("Event log", panel);
  }
}
