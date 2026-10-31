using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Views.Chat;

public sealed partial class ChatPage
{
  internal void ShowAccountPicker(FrameworkElement? anchor = null) => ShowAccounts(anchor);

  private Task ShowCommandOutputAsync()
  {
    var limit = 40;
    var body = new StackPanel { Spacing = 12 };
    var entries = new StackPanel { Spacing = 8 };
    var count = Words("", 12);
    body.Children.Add(Words("Command output already recorded in this chat. Refresh reads the saved conversation.", 12));
    body.Children.Add(Button("Refresh", async () => { await Model.RefreshRecordedAsync(); Read(); }));
    body.Children.Add(count); body.Children.Add(entries);
    void Read()
    {
      entries.Children.Clear();
      var rows = Model.Rows.Where(IsCommandOutput).ToArray();
      count.Text = rows.Length + " recorded commands";
      if (rows.Length > limit) entries.Children.Add(Button("Show earlier commands", () => { limit += 40; Read(); return Task.CompletedTask; }));
      foreach (var row in rows.TakeLast(limit))
      {
        var output = Words(row.Details, 12); output.FontFamily = TerminalDeck.App.Views.DeckFonts.Mono;
        entries.Children.Add(new Expander { Header = row.Text + (row.Waiting ? " · Working…" : " · " + row.Status), Content = output, HorizontalAlignment = HorizontalAlignment.Stretch });
      }
      if (rows.Length == 0) entries.Children.Add(Words("No command output has been recorded in this chat."));
    }
    Read(); return ShowContentAsync("Command output", body);
  }

  private static bool IsCommandOutput(ChatRow row)
  {
    if (row.Kind != "tool") return false;
    var name = row.Text.Split('.').Last().ToLowerInvariant();
    if (name is "bash" or "exec_command" or "shell_command" or "run_shell_command" or "commandexecution" or "command_execution") return true;
    try
    {
      using var input = JsonDocument.Parse(row.Input);
      return input.RootElement.ValueKind == JsonValueKind.Object &&
        (input.RootElement.TryGetProperty("command", out _) || input.RootElement.TryGetProperty("cmd", out _));
    }
    catch (JsonException) { return false; }
  }
}
