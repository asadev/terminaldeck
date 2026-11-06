using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Chats;
namespace TerminalDeck.App.Views.Chat;
public sealed partial class ChatPage
{
  private async Task ShowSideQuestionAsync()
  {
    var body = new StackPanel { Spacing = 8 }; var state = Model.SideQuestion;
    body.Children.Add(Words("Prepare and review a context brief, then ask in a separate chat with the same AI, account and permissions. Your main draft stays here.", 12));
    var question = new TextBox { Header = "Side question", Text = state.Read().Question, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 140 };
    var brief = new TextBox { Header = "Context brief", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 160, MaxHeight = 280 };
    var status = Words("", 12); var sources = Words("", 12); var updating = false;
    var copy = new Button { Content = "Copy context brief", MinHeight = 32 };
    var ask = new Button { Content = "Ask in separate chat", MinHeight = 32, IsEnabled = false };
    var stopSide = new Button { Content = "Stop side answer", MinHeight = 32, IsEnabled = false };
    var openSide = new Button { Content = "Open side chat", MinHeight = 32, IsEnabled = false };
    var sideStatus = Words("", 12); var answer = new StackPanel { Spacing = 8 };
    using var watching = new CancellationTokenSource(); string? sideId = null; var sending = false; var sideBusy = false;
    ContentDialog? dialog = null; CancellationTokenSource? sideWatching = null;
    async Task FollowSideAsync(string id, CancellationToken followStop)
    {
      try
      {
        await foreach (var side in Model.WatchSideQuestionAsync(id, followStop))
          DispatcherQueue.TryEnqueue(() =>
          {
            if (followStop.IsCancellationRequested || sideId != id) return;
            sideBusy = side.Busy; stopSide.IsEnabled = sideBusy;
            sideStatus.Text = side.Problem ?? (side.Busy ? "Answering in the side chat…" : side.WaitingSince is not null ? "This side chat needs your approval. Open it to answer." : "Side chat ready. Its conversation is saved separately.");
            answer.Children.Clear();
            foreach (var row in ChatProjection.Rows(side).Where(r => r.Kind == "assistant")) answer.Children.Add(ChatMarkdownView.Render(row.Text, CopyText, text => sideStatus.Text = text, side.Definition.Cwd, Model.DataDirectory));
            Refresh();
          });
      }
      catch (OperationCanceledException) when (followStop.IsCancellationRequested) { }
      catch (Exception ex) when (ex is not OutOfMemoryException) { DispatcherQueue.TryEnqueue(() => sideStatus.Text = ex.Message); }
    }
    void Refresh()
    {
      updating = true; var current = state.Read();
      if (question.Text != current.Question) question.Text = current.Question;
      if (brief.Text != current.Brief?.Text) brief.Text = current.Brief?.Text ?? "";
      var sameSource = current.Brief?.ConversationId == Model.Snapshot.ConversationId;
      var valid = current.Brief is { } prepared && prepared.QuestionRevision == current.Revision && sameSource;
      brief.IsEnabled = copy.IsEnabled = valid; ask.IsEnabled = valid && !sending && !sideBusy;
      status.Text = current.Brief is null ? "Prepare a brief to see recorded context." : valid ? "Prepared from recorded context. Review or edit it before copying." : sameSource ? "Question changed. Prepare a new brief before copying." : "The source conversation changed. Prepare a new brief before copying.";
      sources.Text = current.Brief is { } b ? "Source IDs: " + string.Join(", ", b.Sources.Select(s => s.Id + " through " + s.ThroughSequence)) : "";
      updating = false;
    }
    ObserveText(question, () =>
    {
      if (updating) return;
      try { state.SetQuestion(question.Text); Refresh(); } catch (ArgumentException ex) { status.Text = ex.Message; copy.IsEnabled = brief.IsEnabled = false; }
    });
    ObserveText(brief, () =>
    {
      if (updating || state.Read().Brief is not { } current) return;
      try { state.EditBrief(brief.Text, current.TextRevision); } catch (Exception ex) when (ex is InvalidOperationException or ArgumentException) { status.Text = ex.Message; copy.IsEnabled = false; }
    });
    body.Children.Add(question);
    body.Children.Add(Button("Prepare context brief", () => { try { state.Prepare(Model.Snapshot); Refresh(); } catch (ArgumentException ex) { status.Text = ex.Message; } return Task.CompletedTask; }));
    body.Children.Add(status); body.Children.Add(brief); body.Children.Add(sources); body.Children.Add(copy);
    body.Children.Add(ask); body.Children.Add(stopSide); body.Children.Add(openSide); body.Children.Add(sideStatus); body.Children.Add(answer);
    ask.Click += async (_, _) =>
    {
      sending = true; ask.IsEnabled = false; sideStatus.Text = "Starting a separate chat…";
      try
      {
        var side = await Model.CreateSideQuestionAsync(watching.Token); sideId = side.Definition.Id; openSide.IsEnabled = navigation is not null;
        sideWatching?.Cancel(); sideWatching?.Dispose(); sideWatching = CancellationTokenSource.CreateLinkedTokenSource(watching.Token);
        _ = FollowSideAsync(sideId, sideWatching.Token); await Model.SendSideQuestionAsync(sideId, watching.Token);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { sideStatus.Text = ex.Message + (sideId is null ? "" : " Open the saved side chat before retrying."); }
      finally { sending = false; Refresh(); }
    };
    stopSide.Click += async (_, _) => { if (sideId is not { } id) return; stopSide.IsEnabled = false; try { await Model.StopSideQuestionAsync(id); sideStatus.Text = "Stop requested."; } catch (Exception ex) when (ex is not OutOfMemoryException) { sideStatus.Text = ex.Message; } };
    openSide.Click += (_, _) => { if (sideId is { } id && navigation is not null) { dialog?.Hide(); navigation.OpenChat(id); } };
    copy.Click += (_, _) => { if (question.Text != state.Read().Question || brief.Text != state.Read().Brief?.Text) { status.Text = "Prepare or shorten the current brief before copying."; return; } try { CopyText(state.ForCopy(Model.Snapshot)); status.Text = "Context brief copied. Nothing was sent."; } catch (InvalidOperationException ex) { status.Text = ex.Message; } };
    void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) { if (args.PropertyName is nameof(ChatViewModel.SideQuestion) or nameof(ChatViewModel.Snapshot)) Refresh(); }
    Model.PropertyChanged += Changed; Refresh();
    dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Side question", Content = new ScrollViewer { Content = body, MaxHeight = 520 }, CloseButtonText = "Return to main chat" };
    try { await ShowChatDialogAsync(dialog); } finally { watching.Cancel(); sideWatching?.Dispose(); Model.PropertyChanged -= Changed; }
  }
}
