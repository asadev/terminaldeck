using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Hoot;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Views.Hoot;

// This document follows one existing background turn, so Hoot's normal work,
// queue and approval rules remain the only owner of the request.
internal sealed class HootHandoffDocument : Grid, IDisposable
{
  private readonly HootViewModel model;
  private readonly string turnId;
  private readonly TextBlock status = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
  private readonly ProgressBar progress = new() { Height = 2, IsIndeterminate = true };
  private readonly ContentControl content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
  private readonly Button copy = new();
  private RichChatWebView? document;
  private string shown = "";
  private string? failure;
  private readonly string? dataDirectory;
  internal HootHandoffDocument(HootViewModel model, string turnId, Action close, string? dataDirectory)
  {
    this.model = model; this.turnId = turnId; this.dataDirectory = dataDirectory;
    Padding = new(20); RowSpacing = 12; this.SetResourceReference(BackgroundProperty, "DeckCanvasBrush");
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    var bar = new Grid(); bar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    bar.Children.Add(new TextBlock { Text = "Handoff", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    ChatAppearance.IconButton(copy, "\uE8C8", "Copy handoff"); copy.Click += (_, _) => Copy(shown); actions.Children.Add(copy);
    var back = new Button(); ChatAppearance.IconButton(back, "\uE711", "Close handoff"); back.Click += (_, _) => close(); actions.Children.Add(back); SetColumn(actions, 1); bar.Children.Add(actions); Children.Add(bar);
    SetRow(status, 1); Children.Add(status); SetRow(progress, 2); Children.Add(progress);
    var scroll = new ScrollViewer { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled };
    SetRow(scroll, 3); Children.Add(scroll); model.PropertyChanged += Changed; Render();
    AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
  }
  private static void Copy(string text) { var package = new DataPackage(); package.SetText(text); Clipboard.SetContent(package); }
  private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Render();
  private void Render()
  {
    var turn = model.State.Turns.FirstOrDefault(t => t.Id == turnId) ?? model.State.History.SelectMany(h => h.Turns).FirstOrDefault(t => t.Id == turnId);
    if (turn is null) { status.Text = failure ?? "Preparing the handoff…"; return; }
    status.Text = turn.State switch { HootTurnState.Queued => "Waiting for Hoot…", HootTurnState.Dispatching or HootTurnState.Running => "Hoot is writing the handoff…", HootTurnState.Finished => turn.Answer.Length > 0 ? "Handoff ready" : "Hoot finished without writing a handoff.", HootTurnState.Failed => turn.Problem ?? "Hoot could not write this handoff.", HootTurnState.Uncertain => "Hoot's reply is being checked. Open Background turns for its status.", _ => "This handoff was stopped." };
    progress.Visibility = turn.State is HootTurnState.Queued or HootTurnState.Dispatching or HootTurnState.Running ? Visibility.Visible : Visibility.Collapsed;
    copy.IsEnabled = turn.Answer.Length > 0;
    if (shown == turn.Answer) return; shown = turn.Answer;
    if (document is null) { document = (RichChatWebView)ChatMarkdownView.Render(shown, Copy, message => status.Text = message, model.State.Settings?.Folder, dataDirectory); content.Content = document; }
    else document.UpdateHtml(TerminalDeck.Core.Chats.ChatRichContent.Html(shown, model.State.Settings?.Folder));
  }
  internal void Fail(string message) { failure = message; status.Text = message; progress.Visibility = Visibility.Collapsed; }
  public void Dispose() { model.PropertyChanged -= Changed; content.Content = null; }
}
