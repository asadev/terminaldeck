using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views.Chat;

public sealed partial class ChatPage
{
  private bool CanBranchMessages() => ChatBranchActions.Invoke is not null && !Model.Snapshot.Busy && !Model.Snapshot.Stopping
    && !Model.Snapshot.Messages.Any(m => m.State is TerminalDeck.Core.Chats.ChatMessageState.Queued or TerminalDeck.Core.Chats.ChatMessageState.Dispatching || TerminalDeck.Core.Chats.ChatSessions.Unconfirmed(Model.Snapshot, m));

  private FrameworkElement MessageActions(TerminalDeck.Core.Chats.ChatRow row)
  {
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2,
      HorizontalAlignment = row.Kind == "user" ? HorizontalAlignment.Right : HorizontalAlignment.Left,
      Margin = new Thickness(row.Kind == "assistant" ? 36 : 0, 0, 0, 0) };
    var recorded = Model.Snapshot.Events.FirstOrDefault(e => e.Id == row.Id && e.Kind is "user" or "message" or "textDelta");
    if (recorded is { At: var at } && at != default)
    {
      var time = Words(at.ToLocalTime().ToString("t"), 10);
      time.VerticalAlignment = VerticalAlignment.Center; time.Margin = new Thickness(0, 0, 6, 0);
      time.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
      ToolTipService.SetToolTip(time, at.ToLocalTime().ToString("F"));
      AutomationProperties.SetName(time, at.ToLocalTime().ToString("F"));
      actions.Children.Add(time);
    }
    else if (row.Kind == "user")
    {
      // Older or failed-before-dispatch records may have no event time. Do not invent one.
      var unknownTime = Words("—", 10); unknownTime.VerticalAlignment = VerticalAlignment.Center;
      AutomationProperties.SetName(unknownTime, "Message time unavailable");
      ToolTipService.SetToolTip(unknownTime, "Message time unavailable");
      unknownTime.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
      unknownTime.Margin = new Thickness(0, 0, 6, 0); actions.Children.Add(unknownTime);
    }
    actions.Children.Add(ChatAppearance.MessageAction("\uE8C8", "Copy message", () =>
    {
      CopyText(Model.Rows.FirstOrDefault(r => r.Id == row.Id && r.Kind == row.Kind)?.Text ?? row.Text);
      return Task.CompletedTask;
    }));
    var rewind = ChatAppearance.MessageAction("\uE7A7", "Rewind to this message", () => BranchMessageAsync(row, true));
    var fork = ChatAppearance.MessageAction("branch", "Fork from this message", () => BranchMessageAsync(row, false));
    rewind.IsEnabled = fork.IsEnabled = recorded is not null && CanBranchMessages();
    if (!rewind.IsEnabled)
    {
      var reason = recorded is null ? "Rewind and Fork need a message recorded in the conversation history." : "Finish this answer and queued messages before rewinding or forking.";
      ToolTipService.SetToolTip(rewind, reason); ToolTipService.SetToolTip(fork, reason);
    }
    actions.Children.Add(rewind); actions.Children.Add(fork);
    return actions;
  }

  private async Task BranchMessageAsync(TerminalDeck.Core.Chats.ChatRow row, bool rewind)
  {
    if (Model.Snapshot.Busy || Model.Snapshot.Stopping) return;
    if (rewind)
    {
      var confirm = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Rewind to this message?", Content = "The complete conversation is kept as a separate saved chat. Files in the project stay as they are.", PrimaryButtonText = "Rewind", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
      if (await ShowChatDialogAsync(confirm) != ContentDialogResult.Primary) return;
    }
    await Model.RunAsync(async () =>
    {
      var invoke = ChatBranchActions.Invoke ?? throw new InvalidOperationException("The chat workspace owner is not connected.");
      var result = await invoke(Model.Id, rewind ? "rewind" : "fork", JsonSerializer.SerializeToElement(new { messageId = row.Id }), CancellationToken.None);
      if (!rewind) navigation?.OpenChat(result.GetProperty("session").GetProperty("id").GetString()!);
    });
  }
  private async Task ShowBranchesAsync()
  {
    var invoke = ChatBranchActions.Invoke ?? throw new InvalidOperationException("The chat workspace owner is not connected.");
    var body = new StackPanel { Spacing = 12, MinWidth = 360 }; var status = Words("Reading this chat's execution location…", 12); var location = Words("", 12);
    var title = new TextBox { Header = "New chat title", Text = "Fork · " + Model.Snapshot.Definition.Title, MaxLength = 120 };
    var through = new ComboBox { Header = "Fork through", HorizontalAlignment = HorizontalAlignment.Stretch }; through.Items.Add(new ComboBoxItem { Content = "Latest finished point", Tag = "" }); through.SelectedIndex = 0;
    foreach (var turn in Model.Snapshot.Events.Where(e => e.Kind == "providerTurnComplete" && e.Id.Length > 0))
    {
      var prompt = Model.Snapshot.Messages.FirstOrDefault(m => m.ClientId == turn.ClientId)?.Text ?? turn.Id; if (prompt.Length > 80) prompt = prompt[..80] + "…";
      through.Items.Add(new ComboBoxItem { Content = prompt, Tag = turn.ClientId ?? turn.Id });
    }
    through.IsEnabled = Model.Snapshot.Definition.Provider == "codex";
    var own = new CheckBox { Content = "Fork into a separate worktree", IsEnabled = Model.Snapshot.Definition.Provider == "codex" };
    var fork = new Button { Content = "Fork conversation", IsEnabled = Model.Snapshot.Definition.Provider is "claude" or "codex" && !Model.Snapshot.Busy };
    ToolTipService.SetToolTip(fork, Model.Snapshot.Definition.Provider == "gemini" ? "This Gemini protocol does not offer conversation forks. Start a fresh worktree chat instead." : "Creates a real provider conversation copy with the same account and settings");
    var fresh = new Button { Content = "New chat in a worktree" };
    var worktrees = new ComboBox { Header = "App-created worktrees reachable from this chat", HorizontalAlignment = HorizontalAlignment.Stretch };
    var inspect = new Button { Content = "Read worktree status", IsEnabled = false }; var confirm = new CheckBox { Content = "Confirm removal of the selected clean, inactive worktree" }; var remove = new Button { Content = "Remove worktree · keep branch", IsEnabled = false };
    var open = new Button { Content = "Open new chat", IsEnabled = false }; string? created = null; var busy = false;
    ContentDialog? dialog = null;
    async Task ActAsync(string action, object options)
    {
      if (busy) return; busy = true; fork.IsEnabled = fresh.IsEnabled = inspect.IsEnabled = remove.IsEnabled = false; status.Text = "Working on " + action.Replace('-', ' ') + "…";
      try
      {
        var result = await invoke(Model.Id, action, JsonSerializer.SerializeToElement(options), CancellationToken.None);
        if (result.TryGetProperty("session", out var child))
        {
          created = child.GetProperty("id").GetString(); open.IsEnabled = navigation is not null;
          status.Text = result.TryGetProperty("warning", out var warning) && warning.ValueKind == JsonValueKind.String ? warning.GetString() ?? "Created." : "Created a separate chat. No message was sent.";
        }
        else status.Text = IntegrationText(result);
        await ReadLocationAsync();
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = ex.Message; }
      finally { busy = false; fork.IsEnabled = Model.Snapshot.Definition.Provider is "claude" or "codex" && !Model.Snapshot.Busy; fresh.IsEnabled = true; inspect.IsEnabled = worktrees.SelectedItem is not null; remove.IsEnabled = confirm.IsChecked == true && worktrees.SelectedItem is not null; }
    }
    async Task ReadLocationAsync()
    {
      var result = await invoke(Model.Id, "location", JsonSerializer.SerializeToElement(new { }), CancellationToken.None);
      location.Text = "This PC · " + result.GetProperty("machine").GetString() + "\n" + result.GetProperty("folder").GetString() + "\nProvider: " + result.GetProperty("provider").GetString();
      var selected = (worktrees.SelectedItem as ComboBoxItem)?.Tag as string; worktrees.Items.Clear();
      foreach (var entry in result.GetProperty("worktrees").EnumerateArray())
      {
        var id = entry.TryGetProperty("sessionId", out var session) && session.ValueKind == JsonValueKind.String ? session.GetString()! : entry.GetProperty("id").GetString()!;
        worktrees.Items.Add(new ComboBoxItem { Content = entry.GetProperty("branch").GetString() + " · " + entry.GetProperty("folder").GetString(), Tag = id });
      }
      worktrees.SelectedItem = worktrees.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == selected) ?? worktrees.Items.FirstOrDefault(); inspect.IsEnabled = worktrees.SelectedItem is not null;
    }
    fork.Click += async (_, _) => await ActAsync("fork", new { title = title.Text, throughTurn = (through.SelectedItem as ComboBoxItem)?.Tag as string, worktree = own.IsChecked == true });
    fresh.Click += async (_, _) => await ActAsync("worktree-chat", new { title = title.Text });
    inspect.Click += async (_, _) => await ActAsync("worktree-status", new { session = (worktrees.SelectedItem as ComboBoxItem)?.Tag as string });
    remove.Click += async (_, _) => { if (confirm.IsChecked == true) await ActAsync("worktree-remove", new { session = (worktrees.SelectedItem as ComboBoxItem)?.Tag as string }); };
    worktrees.SelectionChanged += (_, _) => { confirm.IsChecked = false; inspect.IsEnabled = !busy && worktrees.SelectedItem is not null; remove.IsEnabled = false; };
    confirm.Click += (_, _) => remove.IsEnabled = !busy && confirm.IsChecked == true && worktrees.SelectedItem is not null;
    open.Click += (_, _) => { if (created is { } id && navigation is not null) { dialog?.Hide(); DispatcherQueue.TryEnqueue(() => navigation.OpenChat(id)); } };
    foreach (var item in new UIElement[] { location, title, through, own, fork, fresh, Words("A fresh worktree chat starts without the old conversation. Cleanup refuses uncommitted changes and running sessions, and keeps the Git branch.", 12), worktrees, inspect, confirm, remove, status, open }) body.Children.Add(item);
    dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Fork, worktree and execution location", Content = new ScrollViewer { Content = body, MaxHeight = 560 }, CloseButtonText = "Done" };
    dialog.Closing += (_, e) => e.Cancel = busy;
    dialog.Opened += async (_, _) => { try { await ReadLocationAsync(); if (!busy) status.Text = "Ready."; } catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = ex.Message; } };
    await ShowChatDialogAsync(dialog);
  }
  private static string IntegrationText(JsonElement value)
  {
    var lines = new List<string>();
    foreach (var field in value.EnumerateObject())
    {
      if (field.Name.Equals("sessionId", StringComparison.OrdinalIgnoreCase) || field.Name.Equals("parentSessionId", StringComparison.OrdinalIgnoreCase) || field.Value.ValueKind is JsonValueKind.Null or JsonValueKind.Object or JsonValueKind.Array) continue;
      var text = field.Value.ValueKind == JsonValueKind.True ? "Yes" : field.Value.ValueKind == JsonValueKind.False ? "No" : field.Value.ToString();
      if (text.Length > 4000) text = text[..4000] + "…";
      lines.Add(char.ToUpperInvariant(field.Name[0]) + field.Name[1..] + ": " + text);
    }
    return string.Join('\n', lines);
  }
}
