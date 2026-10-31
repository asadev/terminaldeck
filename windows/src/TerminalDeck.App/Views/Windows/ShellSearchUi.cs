using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Chats;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task ShowQuickOpenAsync(FrameworkElement target, WorkspaceTab? tab)
  {
    if (tab is not null && Runtime.Sessions.Any(s => s.Definition.Id == tab.Subject && s.Definition.ServerId is not null)) throw new InvalidOperationException("Use this server’s Files page to open remote files.");
    var folder = tab is null ? Model.Selected?.Folder : WindowFolder(tab);
    if (string.IsNullOrEmpty(folder)) folder = Projects.Model.SelectedId is { } project ? Runtime.Projects.Get(project).HomeFolder : null;
    if (string.IsNullOrEmpty(folder)) throw new InvalidOperationException("Choose a project or session folder before Quick Open.");
    var query = new TextBox { PlaceholderText = "Find a file in this folder", MinWidth = 420 }; AutomationProperties.SetName(query, "Find a file");
    var status = new TextBlock { Text = "Looking for files…", Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    var list = new ListView { DisplayMemberPath = "RelativePath", MaxHeight = 400, IsItemClickEnabled = true };
    var content = new StackPanel { Spacing = 12 }; content.Children.Add(query); content.Children.Add(status); content.Children.Add(list);
    var dialog = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Quick Open", Content = content, CloseButtonText = "Close" };
    CancellationTokenSource? pending = null; QuickFile? chosen = null;
    async Task Search()
    {
      pending?.Cancel(); pending?.Dispose(); pending = new(); var ct = pending.Token;
      var text = query.Text; status.Text = "Looking for files…"; list.IsEnabled = false;
      try
      {
        await Task.Delay(120, ct); var files = await Task.Run(() => WorkspaceFiles.Find(folder, text, ct), ct);
        if (ct.IsCancellationRequested) return;
        list.ItemsSource = files; list.SelectedIndex = files.Count > 0 ? 0 : -1;
        status.Text = files.Count == 0 ? "No matching files." : files.Count == 100 ? "First 100 matches. Type more to narrow the list." : folder;
      }
      catch (OperationCanceledException) { }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { status.Text = "This folder could not be read. Previous results are kept; check access and try again."; }
      finally { if (!ct.IsCancellationRequested) list.IsEnabled = true; }
    }
    void Pick() { if (!list.IsEnabled) return; chosen = list.SelectedItem as QuickFile; if (chosen is not null) dialog.Hide(); }
    query.TextChanging += async (_, _) => await Search();
    query.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { Pick(); args.Handled = true; } else if (args.Key == VirtualKey.Down) { list.Focus(FocusState.Keyboard); args.Handled = true; } };
    list.ItemClick += (_, args) => { list.SelectedItem = args.ClickedItem; Pick(); };
    list.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { Pick(); args.Handled = true; } };
    dialog.Opened += async (_, _) => { query.Focus(FocusState.Keyboard); await Search(); };
    try { await ShowShellDialogAsync(dialog); } finally { pending?.Cancel(); pending?.Dispose(); }
    if (chosen is not null)
    {
      var info = new FileInfo(chosen.Path);
      if (info.Length > 1024 * 1024) throw new InvalidOperationException("This file is larger than the 1 MB Quick Open preview limit. Open it from Explorer.");
      var text = await File.ReadAllTextAsync(chosen.Path);
      if (text.Contains('\0')) throw new InvalidOperationException("This file needs a specialised viewer. Open it from Explorer.");
      var preview = new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontFamily = TerminalDeck.App.Views.DeckFonts.Mono, MinWidth = 480, MaxHeight = 480 };
      await ShowShellDialogAsync(new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = chosen.RelativePath, Content = preview, CloseButtonText = "Done" });
    }
  }
  private sealed record TranscriptHit(string SessionId, string Title, string Source, string Text)
  { public string Label => Title + " · " + Source + "\n" + Text; }
  private IEnumerable<TranscriptHit> SearchTranscripts(string query, Func<string, bool>? allowed = null, CancellationToken ct = default)
  {
    if (query.Trim().Length == 0) yield break;
    var count = 0;
    foreach (var chat in Runtime.Chats.List())
    {
      ct.ThrowIfCancellationRequested(); if (allowed?.Invoke(chat.Definition.Id) == false) continue;
      foreach (var entry in chat.Events)
      {
        ct.ThrowIfCancellationRequested(); if (!entry.Text.Contains(query, StringComparison.OrdinalIgnoreCase)) continue;
        yield return new(chat.Definition.Id, chat.Definition.Title, "Saved chat event " + entry.Sequence, Excerpt(entry.Text, query)); if (++count >= 100) yield break;
      }
    }
    foreach (var session in Runtime.Sessions)
    {
      ct.ThrowIfCancellationRequested();
      if (allowed?.Invoke(session.Definition.Id) == false || !session.Replay.Contains(query, StringComparison.OrdinalIgnoreCase)) continue;
      yield return new(session.Definition.Id, session.Definition.Title, "Retained terminal output", Excerpt(session.Replay, query)); if (++count >= 100) yield break;
    }
  }
  private static string Excerpt(string text, string query)
  {
    var at = text.IndexOf(query, StringComparison.OrdinalIgnoreCase); var start = Math.Max(0, at - 60);
    return text.Substring(start, Math.Min(240, text.Length - start)).Replace('\r', ' ').Replace('\n', ' ');
  }
  private async Task ShowSessionSearchAsync(FrameworkElement target)
  {
    var query = new TextBox { PlaceholderText = "Search saved chat events and retained terminal output", MinWidth = 440 }; AutomationProperties.SetName(query, "Search session transcripts");
    var status = new TextBlock { Text = "Enter text to search. Terminal history is limited to retained output.", Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    var results = new ListView { MaxHeight = 400, IsItemClickEnabled = true };
    var form = new StackPanel { Spacing = 12 }; form.Children.Add(query); form.Children.Add(status); form.Children.Add(results);
    var dialog = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Search Sessions", Content = form, CloseButtonText = "Close" };
    string? picked = null;
    CancellationTokenSource? pending = null;
    query.TextChanging += async (_, _) =>
    {
      pending?.Cancel(); pending?.Dispose(); pending = new(); var ct = pending.Token; var text = query.Text;
      results.IsEnabled = false; status.Text = text.Length == 0 ? "Enter text to search." : "Searching session history…";
      try
      {
        await Task.Delay(120, ct); var hits = await Task.Run(() => SearchTranscripts(text, ct: ct).ToArray(), ct);
        if (ct.IsCancellationRequested) return;
        results.Items.Clear();
        foreach (var hit in hits)
        {
          var identity = Model.Sessions.FirstOrDefault(s => s.Id == hit.SessionId);
          var content = identity is null ? (UIElement)new TextBlock { Text = hit.Label } : TerminalDeck.App.Views.Projects.ProjectAgentUi.SessionIdentityRow(identity, hit.Source + " · " + hit.Text);
          results.Items.Add(new ListViewItem { Content = content, Tag = hit });
        }
        results.SelectedIndex = hits.Length > 0 ? 0 : -1;
        status.Text = text.Length == 0 ? "Enter text to search." : hits.Length == 0 ? "No matching transcript text." : hits.Length + " matches · saved chat events and retained terminal output";
      }
      catch (OperationCanceledException) { }
      catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = "Session history could not be read. Previous results are kept; try again."; }
      finally { if (!ct.IsCancellationRequested) results.IsEnabled = true; }
    };
    void Pick() { if (results.IsEnabled && results.SelectedItem is ListViewItem { Tag: TranscriptHit hit }) { picked = hit.SessionId; dialog.Hide(); } }
    results.ItemClick += (_, args) => { results.SelectedItem = args.ClickedItem; Pick(); };
    query.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { Pick(); args.Handled = true; } else if (args.Key == VirtualKey.Down) { results.Focus(FocusState.Keyboard); args.Handled = true; } };
    results.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { Pick(); args.Handled = true; } };
    dialog.Opened += (_, _) => query.Focus(FocusState.Keyboard);
    try { await ShowShellDialogAsync(dialog); } finally { pending?.Cancel(); pending?.Dispose(); }
    if (picked is not null) OpenSession(picked);
  }
  private object InspectorSnapshot(string id)
  {
    var chat = Runtime.Chats.List().FirstOrDefault(c => c.Definition.Id == id);
    if (chat is not null) return new { sessionId = id, source = "Saved events for this chat", chat.Definition.Title, events = chat.Events.TakeLast(200),
      tools = chat.Events.Where(e => e.Kind == "toolCall").GroupBy(e => e.Text).Select(g => new { name = g.Key, count = g.Select(e => e.Id).Distinct().Count() }),
      usage = "Token and cost measurements are not supplied by this chat source." };
    var terminal = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == id) ?? throw new InvalidOperationException("This session is no longer available.");
    return new { sessionId = id, source = "This session’s keeper record and retained terminal output", terminal.Definition.Title, terminal.State, terminal.CreatedAt, terminal.ExitCode,
      outputCharacters = terminal.Replay.Length, usage = "Timeline, token, cost and tool measurements are not supplied by this terminal source." };
  }
  private async Task ShowSessionInspectorAsync(FrameworkElement target, WorkspaceTab? tab)
  {
    var id = tab?.Kind == "browser" ? tab.Owner : tab?.Subject;
    if (id is null || tab?.Kind == "page") throw new InvalidOperationException("Choose a session to inspect.");
    var words = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, MaxWidth = 620 };
    void Read()
    {
      if (Runtime.Chats.List().FirstOrDefault(c => c.Definition.Id == id) is { } chat)
      {
        var tools = chat.Events.Where(e => e.Kind == "toolCall").GroupBy(e => e.Text).Select(g => g.Key + " · " + g.Select(e => e.Id).Distinct().Count());
        words.Text = chat.Definition.Title + "\nSaved events for this chat\n\nUsage\nToken and cost measurements are not supplied by this chat source.\n\nTools\n" +
          (tools.Any() ? string.Join('\n', tools) : "No tool calls recorded.") + "\n\nTimeline\n" +
          (chat.Events.Length == 0 ? "No events recorded yet." : string.Join("\n\n", chat.Events.TakeLast(200).Select(e => e.At.ToLocalTime().ToString("g") + " · " + e.Kind + "\n" + e.Text)));
      }
      else if (Runtime.Sessions.FirstOrDefault(t => t.Definition.Id == id) is { } terminal)
        words.Text = terminal.Definition.Title + "\nThis session’s keeper record and retained terminal output\n\n" + SessionStatus.From(terminal.State.ToString()).Label +
          "\nRetained output: " + terminal.Replay.Length.ToString("N0") + " characters" + (terminal.ExitCode is { } exit ? "\nExit code: " + exit : "") +
          "\n\nTimeline, token, cost and tool measurements are not supplied by this terminal source.";
      else words.Text = "This session is no longer available. Its source could not be read.";
    }
    Read();
    var dialog = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Session Inspector", Content = new ScrollViewer { MaxHeight = 480, Content = words }, PrimaryButtonText = "Refresh", CloseButtonText = "Done" };
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var defer = args.GetDeferral(); args.Cancel = true; words.Text = "Refreshing this session…";
      try { await Runtime.RefreshSessionsAsync(); Read(); } catch (Exception ex) when (ex is not OutOfMemoryException) { words.Text = "The session could not refresh. Try again."; } finally { defer.Complete(); }
    };
    await ShowShellDialogAsync(dialog);
  }
}
