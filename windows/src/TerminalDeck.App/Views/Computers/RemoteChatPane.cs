using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Chat;
using Windows.ApplicationModel.DataTransfer;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.App.Views.Computers;

internal sealed class RemoteChatPane : Grid, IAsyncDisposable
{
  private readonly OtherComputersService service;
  private readonly string computer, session;
  private readonly Action<string> notice;
  private readonly StackPanel messages = new() { Spacing = 14, MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Center };
  private readonly TextBox draft = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64, MaxHeight = 180, MaxLength = 16000, PlaceholderText = "Message the AI on that computer" };
  private readonly Button send = new(), interrupt = new();
  private readonly SortedDictionary<long, JsonElement> events = [];
  private readonly Dictionary<string, RichChatWebView> richMessages = [];
  private readonly ScrollViewer history;
  private string? pendingId, pendingText;
  private bool busy, disposed, sending;
  internal RemoteChatPane(OtherComputersService service, string computer, string session, Action<string> notice)
  {
    this.service = service; this.computer = computer; this.session = session; this.notice = notice;
    RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) }); RowDefinitions.Add(new() { Height = GridLength.Auto });
    history = new ScrollViewer { Content = messages, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled };
    history.SizeChanged += (_, _) => messages.Width = Math.Max(0, Math.Min(760, history.ActualWidth - 40)); Children.Add(history);
    var compose = new StackPanel { Spacing = 6, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
    draft.BorderThickness = new(0); draft.SetResourceReference(Control.BackgroundProperty, "DeckControlBrush"); draft.CornerRadius = new(14); compose.Children.Add(draft);
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
    Chat.ChatAppearance.IconButton(interrupt, "\uE71A", "Stop the current remote answer"); Chat.ChatAppearance.IconButton(send, "\uE74A", "Send message", accent: true);
    actions.Children.Add(interrupt); actions.Children.Add(send); compose.Children.Add(actions); compose.Margin = new(20, 8, 20, 16); SetRow(compose, 1); Children.Add(compose);
    send.Click += async (_, _) => await SendAsync(); interrupt.Click += async (_, _) => await Act(() => service.ChatActionAsync(computer, session, "interrupt"));
    draft.TextChanged += (_, _) => Controls(); draft.KeyDown += async (_, args) =>
    {
      if (args.Key == Windows.System.VirtualKey.Enter && (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift) & Windows.UI.Core.CoreVirtualKeyStates.Down) == 0)
      { args.Handled = true; if (send.IsEnabled) await SendAsync(); }
    };
    service.Frame += Received; service.Changed += Changed;
    Loaded += async (_, _) => await Act(() => service.ChatActionAsync(computer, session, "watch")); Controls();
  }
  private bool Live => !disposed && service.List().Any(c => c.Id == computer && c.State == "Online" && c.Capabilities.Contains("chats")) && service.Services(computer).Sessions.Any(s => RemoteSessionReading.Text(s, "id") == session && RemoteSessionReading.Text(s, "status") != "exited");
  private void Controls()
  {
    draft.IsEnabled = Live; send.IsEnabled = Live && !sending && !string.IsNullOrWhiteSpace(draft.Text);
    interrupt.IsEnabled = Live; interrupt.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
  }
  private async Task Act(Func<Task> action)
  {
    try { await action(); } catch (Exception ex) when (ex is not OutOfMemoryException) { notice(ex.Message); }
  }
  private async Task SendAsync()
  {
    if (!send.IsEnabled) return;
    var text = draft.Text; if (pendingId is null || pendingText != text) { pendingId = Guid.NewGuid().ToString(); pendingText = text; }
    sending = true; Controls(); notice("Sending…");
    try { await service.ChatActionAsync(computer, session, "send", text, clientId: pendingId); if (draft.Text == text) draft.Text = ""; notice(""); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { notice("Delivery was not confirmed. Your message is kept here. " + ex.Message); }
    finally { sending = false; Controls(); }
  }
  private void Changed() => DispatcherQueue.TryEnqueue(() => { Controls(); if (!Live) notice("Reconnecting to that computer…"); });
  private void Received(string computerId, JsonElement frame)
  {
    if (computerId != computer || disposed) return;
    var tag = RemoteSessionReading.Text(frame, "t");
    if (tag == "welcome") { DispatcherQueue.TryEnqueue(async () => await Act(() => service.ChatActionAsync(computer, session, "watch"))); return; }
    if (RemoteSessionReading.Text(frame, "id") != session) return;
    DispatcherQueue.TryEnqueue(() =>
    {
      if (tag == "error") { notice(RemoteSessionReading.Text(frame, "message", "The other computer refused this action.")); return; }
      if (tag != "chats.events") return;
      if (RemoteSessionReading.Field(frame, "reset").ValueKind == JsonValueKind.True) events.Clear();
      foreach (var value in RemoteSessionReading.Rows(frame, "events"))
      {
        var seq = RemoteSessionReading.Field(value, "sequence"); if (seq.ValueKind == JsonValueKind.Number && seq.TryGetInt64(out var number)) events[number] = value;
      }
      busy = RemoteSessionReading.Field(frame, "busy").ValueKind == JsonValueKind.True; Render(); Controls();
    });
  }
  private void Render()
  {
    var bottom = history.ScrollableHeight - history.VerticalOffset < 60;
    var desired = new List<UIElement>();
    foreach (var row in RemoteChatReading.Rows(events.Values))
    {
      var words = new TextBlock { Text = row.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 13 };
      if (row.Kind == "user")
      {
        var bubble = new Border { Child = words, Padding = new(12, 8, 12, 8), CornerRadius = new(14), MaxWidth = 560, HorizontalAlignment = HorizontalAlignment.Right };
        bubble.SetResourceReference(Border.BackgroundProperty, "DeckSidebarSelectionInactiveBrush"); desired.Add(bubble);
        if (row.Text == pendingText) { pendingId = pendingText = null; }
      }
      else if (row.Kind == "approval")
      {
        var body = new StackPanel { Spacing = 8 }; body.Children.Add(words);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var allowed in new[] { false, true })
        {
          var answer = new Button { Content = allowed ? "Allow" : "Deny", IsEnabled = Live };
          answer.Click += async (_, _) => { buttons.IsHitTestVisible = false; await Act(() => service.ChatActionAsync(computer, session, "answer", request: row.Request, approved: allowed)); buttons.IsHitTestVisible = true; }; buttons.Children.Add(answer);
        }
        body.Children.Add(buttons); var card = new Border { Child = body, Padding = new(14), CornerRadius = new(12) }; card.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush"); desired.Add(card);
      }
      else if (row.Kind == "tool") desired.Add(new Expander { Header = row.Title, Content = words, HorizontalAlignment = HorizontalAlignment.Stretch });
      else if (row.Kind == "assistant")
      {
        if (!richMessages.TryGetValue(row.Id, out var rich))
        {
          rich = (RichChatWebView)ChatMarkdownView.Render(row.Text, text => { var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); }, notice);
          richMessages[row.Id] = rich;
        }
        else rich.UpdateHtml(TerminalDeck.Core.Chats.ChatRichContent.Html(row.Text));
        desired.Add(rich);
      }
      else desired.Add(words);
    }
    for (var index = messages.Children.Count - 1; index >= 0; index--) if (!desired.Contains(messages.Children[index])) messages.Children.RemoveAt(index);
    for (var index = 0; index < desired.Count; index++)
    {
      if (index < messages.Children.Count && ReferenceEquals(messages.Children[index], desired[index])) continue;
      messages.Children.Remove(desired[index]); messages.Children.Insert(index, desired[index]);
    }
    if (bottom) DispatcherQueue.TryEnqueue(() => history.ChangeView(null, history.ScrollableHeight, null, true));
  }
  public async ValueTask DisposeAsync()
  {
    if (disposed) return; disposed = true; service.Frame -= Received; service.Changed -= Changed;
    try { await service.ChatActionAsync(computer, session, "unwatch"); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}
