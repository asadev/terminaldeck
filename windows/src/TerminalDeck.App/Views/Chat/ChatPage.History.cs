using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Projects;
namespace TerminalDeck.App.Views.Chat;
public sealed partial class ChatPage
{
  private async Task ShowHistoryAsync()
  {
    var body = new StackPanel { Spacing = 12 }; ContentDialog? dialog = null;
    body.Children.Add(Words("Search recorded app conversations. Loading a preview does not resume a coding AI or send a message.", 12));
    var locator = new TextBox { PlaceholderText = "Conversation ID or chat: reference" };
    var query = new TextBox { PlaceholderText = "Search text…" };
    var scope = new ComboBox { Header = "Projects", Items = { navigation?.ProjectFolders is { Count: > 0 } ? "This project" : "This folder", "All projects" }, SelectedIndex = 0 };
    var speaker = new ComboBox { Header = "Speaker", Items = { "Everyone", "You", "Assistant", "Tools" }, SelectedIndex = 0 };
    var filters = new Grid { ColumnSpacing = 8 };
    filters.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); filters.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    filters.Children.Add(scope); SetColumn(speaker, 1); filters.Children.Add(speaker);
    var count = Words("", 12); var results = new StackPanel { Spacing = 12 }; var preview = new StackPanel { Spacing = 8 }; var problem = new Notices.CompactNotice();
    body.Children.Add(locator); var load = Button("Load preview", () => { LoadLocator(); return Task.CompletedTask; }); body.Children.Add(load); body.Children.Add(problem);
    body.Children.Add(query); body.Children.Add(filters); body.Children.Add(count); body.Children.Add(preview);
    var pages = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var previous = new Button { Content = "Previous", MinHeight = 32 }; var next = new Button { Content = "Next", MinHeight = 32 }; pages.Children.Add(previous); pages.Children.Add(next); body.Children.Add(pages); body.Children.Add(results);
    var page = 0;
    void ShowPreview(ChatRecord chat, string text)
    {
      var offset = 0;
      void RenderPreview()
      {
        preview.Children.Clear(); preview.Children.Add(Words(chat.Definition.Title + "\n" + chat.Definition.Cwd + "\nConversation: " + (chat.ConversationId ?? chat.Definition.Id), 12));
        var length = Math.Min(16000, text.Length - offset);
        if (length > 0 && offset + length < text.Length && char.IsHighSurrogate(text[offset + length - 1]) && char.IsLowSurrogate(text[offset + length])) length--;
        var displayed = text.Substring(offset, length); preview.Children.Add(Words(displayed));
        preview.Children.Add(Words((offset + 1) + "–" + (offset + length) + " of " + text.Length + " characters", 12));
        if (offset + length < text.Length) preview.Children.Add(Button("Next excerpt", () => { offset += length; RenderPreview(); return Task.CompletedTask; }));
        if (offset > 0) preview.Children.Add(Button("Back to start", () => { offset = 0; RenderPreview(); return Task.CompletedTask; }));
        preview.Children.Add(Button("Insert displayed excerpt into draft", () => { Model.Draft += (Model.Draft.Length > 0 ? "\n\n" : "") + displayed; dialog?.Hide(); return Task.CompletedTask; }));
        if (navigation is not null) preview.Children.Add(Button("Open saved chat", () => { dialog?.Hide(); navigation.OpenChat(chat.Definition.Id); return Task.CompletedTask; }));
      }
      RenderPreview();
    }
    IEnumerable<ChatRecord> Scoped() => Model.PastChats.Where(c => scope.SelectedIndex == 1 || (navigation?.ProjectFolders is { Count: > 0 } folders ? folders.Any(f => ProjectPaths.Contains(f, c.Definition.Cwd)) : ProjectPaths.Equal(c.Definition.Cwd, Model.Snapshot.Definition.Cwd)));
    void LoadLocator()
    {
      var value = locator.Text.Trim(); if (value.StartsWith("chat:", StringComparison.Ordinal)) value = value[5..];
      var found = Scoped().Where(c => c.Definition.Id == value || c.ConversationId == value).ToArray();
      if (found.Length != 1) { problem.Text = "Choose one recorded chat in the selected project scope."; return; }
      problem.Text = ""; ShowPreview(found[0], ChatText.Export(found[0]));
    }
    void Refresh()
    {
      results.Children.Clear();
      var kind = speaker.SelectedIndex switch { 1 => "user", 2 => "assistant", 3 => "tool", _ => null };
      var rows = Scoped().SelectMany(c => ChatProjection.Rows(c).Where(r => (kind is null || r.Kind == kind) && (query.Text.Length == 0 || (r.Text + " " + r.Details).Contains(query.Text, StringComparison.OrdinalIgnoreCase))).Select(r => (Chat: c, Row: r))).ToArray();
      page = Math.Clamp(page, 0, Math.Max(0, (rows.Length - 1) / 30)); var offset = page * 30;
      count.Text = rows.Length == 0 ? "No matching recorded conversations." : (offset + 1) + "–" + Math.Min(offset + 30, rows.Length) + " of " + rows.Length + " recorded excerpts";
      previous.IsEnabled = page > 0; next.IsEnabled = offset + 30 < rows.Length;
      foreach (var item in rows.Skip(offset).Take(30))
      {
        var text = item.Row.Kind == "tool" ? item.Row.Text + "\n" + item.Row.Details : item.Row.Text;
        var index = query.Text.Length > 0 ? Math.Max(0, text.IndexOf(query.Text, StringComparison.OrdinalIgnoreCase) - 60) : 0;
        var snippet = text.Substring(index, Math.Min(280, text.Length - index));
        var row = new StackPanel { Spacing = 4 }; row.Children.Add(Words(item.Chat.Definition.Title + " · " + item.Row.Kind + "\n" + item.Chat.Definition.Cwd, 12)); row.Children.Add(Words(snippet));
        row.Children.Add(Button("Preview excerpt", () => { ShowPreview(item.Chat, text); return Task.CompletedTask; })); results.Children.Add(row);
      }
    }
    ObserveText(query, () => { page = 0; Refresh(); }); scope.SelectionChanged += (_, _) => { page = 0; Refresh(); }; speaker.SelectionChanged += (_, _) => { page = 0; Refresh(); };
    previous.Click += (_, _) => { page--; Refresh(); }; next.Click += (_, _) => { page++; Refresh(); }; Refresh();
    dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Past chats", Content = new ScrollViewer { Content = body, MaxHeight = 520 }, CloseButtonText = "Done" };
    await ShowChatDialogAsync(dialog);
  }
}
