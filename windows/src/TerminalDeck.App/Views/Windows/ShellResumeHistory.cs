using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task ShowResumeHistoryAsync(FrameworkElement target, string? folder, McpCallContext? caller)
  {
    await Runtime.RefreshSessionsAsync();
    var body = new StackPanel { Spacing = 12, MinWidth = 340 }; var query = new TextBox { PlaceholderText = "Find a saved conversation…" };
    var scope = new ComboBox { Header = "Show", Items = { "This folder", "All folders" }, SelectedIndex = string.IsNullOrEmpty(folder) ? 1 : 0 };
    var notice = new TextBlock { Text = "Open a current session or continue a saved AI conversation. No message is sent by opening it.", TextWrapping = TextWrapping.Wrap };
    var rows = new StackPanel { Spacing = 8 }; body.Children.Add(query); body.Children.Add(scope); body.Children.Add(notice); body.Children.Add(rows);
    ContentDialog? dialog = null; var busy = false;
    bool Visible(string id, string cwd, string title) => (caller is null || caller.Has("sessions", id)) && (scope.SelectedIndex == 1 || folder is not null && ProjectPaths.Equal(cwd, folder)) && (query.Text.Length == 0 || (title + " " + cwd).Contains(query.Text, StringComparison.OrdinalIgnoreCase));
    async Task SelectAsync(Func<Task<string>> action)
    {
      if (busy) return; busy = true; notice.Text = "Opening conversation…";
      try
      {
        if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None);
        var id = await action(); await Runtime.RefreshSessionsAsync(); Model.Sync(Runtime.Sessions, Runtime.Chats.List());
        var draft = Model.Sessions.FirstOrDefault(s => s.Id == id) ?? throw new InvalidOperationException("The saved conversation could not be opened.");
        busy = false; dialog?.Hide(); SelectSessionWindow(draft);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex.Message; }
      finally { busy = false; }
    }
    void Row(string title, string detail, string actionLabel, bool enabled, Func<Task<string>> action)
    {
      var row = new Grid { ColumnSpacing = 12 }; row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var words = new StackPanel { Spacing = 2 }; words.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis }); words.Children.Add(new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = .7 }); row.Children.Add(words);
      var open = new Button { Content = actionLabel, IsEnabled = enabled, VerticalAlignment = VerticalAlignment.Center }; open.Click += async (_, _) => await SelectAsync(action); Grid.SetColumn(open, 1); row.Children.Add(open); rows.Children.Add(row);
    }
    void Render()
    {
      rows.Children.Clear();
      foreach (var chat in Runtime.Chats.List().Where(c => Visible(c.Definition.Id, c.Definition.Cwd, c.Definition.Title)).OrderByDescending(c => c.Events.LastOrDefault()?.At).Take(100))
        Row(chat.Definition.Title, chat.Definition.Provider + " · " + chat.Definition.Cwd + (chat.Ended ? " · Saved" : chat.Busy ? " · Working" : " · Open"), chat.Ended ? "Continue" : "Open", !chat.Ended || chat.ConversationId is { Length: > 0 }, async () =>
        {
          if (!chat.Ended) return chat.Definition.Id;
          var account = Runtime.Accounts.Get(chat.Definition.AccountId); if (!account.SignedIn) throw new InvalidOperationException("Sign in to this chat's account in Coding AIs first.");
          if (caller is not null) { caller.Require("accounts", account.Id); caller.Require("folders", chat.Definition.Cwd); }
          var definition = chat.Definition with { Id = Guid.NewGuid().ToString(), AccountHome = account.HomeId };
          if (chat.Definition.AccountHome != account.HomeId)
          {
            var source = new SessionDefinition(chat.Definition.Id, chat.Definition.Provider, chat.Definition.Cwd, chat.Definition.Title, chat.Definition.AccountId, chat.Definition.AccountHome, chat.ConversationId);
            if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None);
            new ConversationFiles(dataRoot).Copy(source, source with { Id = definition.Id, AccountHome = account.HomeId });
          }
          if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None);
          var resumed = await Runtime.Chats.CreateAsync(definition, chat.ConversationId); caller?.NoteSessionStarted(resumed.Definition.Id); return resumed.Definition.Id;
        });
      foreach (var session in Runtime.Sessions.Where(s => s.Definition.Purpose is null && Visible(s.Definition.Id, s.Definition.Cwd, s.Definition.Title)).OrderByDescending(s => s.CreatedAt).Take(100))
        Row(session.Definition.Title, session.Definition.Provider + " · " + session.Definition.Cwd + " · " + session.State.ToString().ToLowerInvariant(), session.State == SessionState.Exited ? "Continue" : "Open", session.State != SessionState.Exited || session.Definition.Provider != "shell" && session.Definition.AccountId is not null, async () =>
        {
          if (session.State != SessionState.Exited) return session.Definition.Id;
          var files = new ConversationFiles(dataRoot); var conversation = files.FindConversation(session); var account = Runtime.Accounts.Get(session.Definition.AccountId!);
          if (!account.SignedIn) throw new InvalidOperationException("Sign in to this session's account in Coding AIs first.");
          if (caller is not null) { caller.Require("accounts", account.Id); caller.Require("folders", session.Definition.Cwd); }
          var definition = session.Definition with { Id = Guid.NewGuid().ToString(), ConversationId = conversation, AccountHome = account.HomeId };
          if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None);
          files.Copy(session.Definition with { ConversationId = conversation }, definition);
          if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None);
          var resumed = (await Runtime.Keeper.CreateAsync(definition)).Session?.Definition.Id ?? throw new IOException("The saved conversation did not start."); caller?.NoteSessionStarted(resumed); return resumed;
        });
      if (rows.Children.Count == 0) rows.Children.Add(new TextBlock { Text = "No saved conversations match this folder and search.", TextWrapping = TextWrapping.Wrap });
    }
    body.Children.Add(ProviderResumeLibrary(folder, caller, SelectAsync));
    query.TextChanged += (_, _) => Render(); scope.SelectionChanged += (_, _) => Render(); Render();
    dialog = new ContentDialog { XamlRoot = target.XamlRoot, RequestedTheme = target.ActualTheme, Title = "Resume a conversation", Content = new ScrollViewer { Content = body, MaxHeight = 540 }, CloseButtonText = "Cancel" };
    dialog.Closing += (_, e) => e.Cancel = busy; await ShowShellDialogAsync(dialog);
  }
}
