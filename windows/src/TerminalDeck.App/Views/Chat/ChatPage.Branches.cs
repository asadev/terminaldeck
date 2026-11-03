using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views.Chat;

public sealed partial class ChatPage
{
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
