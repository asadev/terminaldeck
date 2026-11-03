using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Projects;
namespace TerminalDeck.App.Views.Chat;
public sealed partial class ChatPage
{
  private Task ShowChangesAsync()
  {
    var panel = new StackPanel { Spacing = 12 };
    panel.Children.Add(Words("File changes recorded by this chat’s provider. These are recorded operations, not a live Git diff.", 12));
    var changes = ChatRecordedChanges.Read(Model.Snapshot);
    foreach (var change in changes)
    {
      var body = new StackPanel { Spacing = 8 };
      if (change.Diff is { } diff) body.Children.Add(Words(diff, 12));
      else
      {
        body.Children.Add(Words(change.Before is { } before ? "− Reported before text\n" + before : "Before text was not reported.", 12));
        if (change.After is { } after) body.Children.Add(Words("+ Reported after text\n" + after, 12));
        if (change.After is null) body.Children.Add(Words("No structured diff text was reported for this change.", 12));
      }
      if (change.Truncated) body.Children.Add(Words("Preview truncated at 20000 characters per field. Open the source event for the recorded details.", 12));
      var comment = new TextBox { PlaceholderText = "Draft review comment", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 120 };
      body.Children.Add(comment);
      var add = Button("Add review comment to draft", () =>
      {
        if (comment.Text.Length == 0) return Task.CompletedTask;
        Model.Draft += (Model.Draft.Length > 0 ? "\n\n" : "") + "Review " + change.Path + ":\n" + comment.Text; currentDialog?.Hide(); return Task.CompletedTask;
      }); body.Children.Add(add);
      body.Children.Add(Button("Show source event", () =>
      {
        var entry = Model.Snapshot.Events.Single(e => e.Sequence == change.SourceSequence);
        var source = Words(System.Text.Json.JsonSerializer.Serialize(entry, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }), 12);
        body.Children.Add(source); return Task.CompletedTask;
      }));
      var actionStatus = new Notices.CompactNotice();
      body.Children.Add(Button("Reveal project file", async () =>
      {
        await Model.RunAsync(() =>
        {
          var folder = Model.Snapshot.Definition.Cwd;
          var path = Path.IsPathFullyQualified(change.Path) ? Path.GetFullPath(change.Path) : Path.GetFullPath(Path.Combine(folder, change.Path));
          if (!ProjectPaths.Contains(folder, path)) throw new InvalidOperationException("This recorded file is outside the project folder.");
          if (!File.Exists(path)) throw new InvalidOperationException("This recorded file is not available on this PC.");
          var info = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = true }; info.ArgumentList.Add("/select," + path); System.Diagnostics.Process.Start(info); return ValueTask.CompletedTask;
        });
        actionStatus.Text = Model.Error ?? "File shown in Explorer.";
      }));
      body.Children.Add(actionStatus);
      var totals = change.Added.HasValue ? " · +" + change.Added + " / −" + change.Deleted : " · line totals not reported";
      panel.Children.Add(new Expander { Header = change.Path + totals, Content = body, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    }
    if (changes.Count == 0) panel.Children.Add(Words("No structured file changes have been recorded for this chat."));
    return ShowContentAsync("File changes", panel);
  }
}
