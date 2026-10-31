using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace TerminalDeck.App.Views.Chat;
public sealed partial class ChatPage
{
  private async Task ShowSideQuestionAsync()
  {
    var body = new StackPanel { Spacing = 8 }; var state = Model.SideQuestion;
    body.Children.Add(Words("A separate provider-side question is not available here yet. Prepare a context brief to ask separately. Nothing is sent and the main draft stays intact.", 12));
    var question = new TextBox { Header = "Side question", Text = state.Read().Question, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 140 };
    var brief = new TextBox { Header = "Context brief", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 160, MaxHeight = 280 };
    var status = Words("", 12); var sources = Words("", 12); var updating = false;
    var copy = new Button { Content = "Copy context brief", MinHeight = 32 };
    void Refresh()
    {
      updating = true; var current = state.Read();
      if (question.Text != current.Question) question.Text = current.Question;
      if (brief.Text != current.Brief?.Text) brief.Text = current.Brief?.Text ?? "";
      var sameSource = current.Brief?.ConversationId == Model.Snapshot.ConversationId;
      var valid = current.Brief is { } prepared && prepared.QuestionRevision == current.Revision && sameSource;
      brief.IsEnabled = copy.IsEnabled = valid;
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
    copy.Click += (_, _) => { if (question.Text != state.Read().Question || brief.Text != state.Read().Brief?.Text) { status.Text = "Prepare or shorten the current brief before copying."; return; } try { CopyText(state.ForCopy(Model.Snapshot)); status.Text = "Context brief copied. Nothing was sent."; } catch (InvalidOperationException ex) { status.Text = ex.Message; } };
    void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) { if (args.PropertyName is nameof(ChatViewModel.SideQuestion) or nameof(ChatViewModel.Snapshot)) Refresh(); }
    Model.PropertyChanged += Changed; Refresh();
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Side question", Content = new ScrollViewer { Content = body, MaxHeight = 520 }, CloseButtonText = "Return to main chat" };
    try { await ShowChatDialogAsync(dialog); } finally { Model.PropertyChanged -= Changed; }
  }
}
