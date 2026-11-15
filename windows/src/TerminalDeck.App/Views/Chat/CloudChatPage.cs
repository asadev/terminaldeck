using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Chat;

/// A session that runs on another of his machines (DESIGN-WINDOWS-CLOUD.md 5, Mac `runs-on-*`): the session's name, ONE
/// secondary line "Runs on Mac mini" (", which is off"), then its chat as the Cloud's readable copy. Windows has no live
/// link to another machine's session yet (no guest chat client), so the page is read only whether that machine is on or
/// off: no message box, no send button, no line saying so. No "Switch to this PC" (left out by decision).
/// New messages arrive by themselves while the page is open (a quiet look every 15 seconds).
public sealed class CloudChatPage : UserControl
{
  private readonly SidebarCloudRow row;
  private readonly Func<CloudChatsSend?> door;
  private readonly StackPanel messages = new() { Spacing = 14, Padding = new(24, 8, 24, 24), MaxWidth = 760 };
  private readonly ScrollViewer scroller;
  private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(15) };
  private readonly SortedDictionary<long, CloudChatLine> lines = [];
  private int? lastEvent;
  private bool reading;

  public CloudChatPage(SidebarCloudRow row, Func<CloudChatsSend?> door)
  {
    this.row = row; this.door = door;
    AutomationProperties.SetAutomationId(this, "cloud.chat");
    var look = CloudChatRules.For(row.Name, row.MachineName, row.MachineOn, liveLink: false);
    var page = new Grid();
    page.RowDefinitions.Add(new() { Height = GridLength.Auto }); page.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    var bar = ChatBar.Frame(false);
    var identity = ChatBar.Identity();
    identity.Children.Add(ChatBar.Title(look.Name));
    var runsOn = new TextBlock { Text = look.RunsOn, FontSize = 12, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis };
    runsOn.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    AutomationProperties.SetAutomationId(runsOn, "cloud.chat.runsOn");
    identity.Children.Add(runsOn);
    bar.Children.Add(identity);
    page.Children.Add(bar);
    messages.HorizontalAlignment = HorizontalAlignment.Stretch;
    scroller = new ScrollViewer { Content = new Border { Child = messages, HorizontalAlignment = HorizontalAlignment.Center }, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    Grid.SetRow(scroller, 1); page.Children.Add(scroller);
    Content = page;
    poll.Tick += async (_, _) => await ReadAsync(newer: true);
    Loaded += async (_, _) => { poll.Start(); await ReadAsync(newer: false); };
    Unloaded += (_, _) => poll.Stop();
  }

  private async Task ReadAsync(bool newer)
  {
    if (reading || door() is not { } send) return;
    reading = true;
    try
    {
      var chat = await CloudSessionsRead.ChatAsync(send, row.Ref, after: newer ? lastEvent : null);
      if (chat is null) return;
      // Asks again from the last event read; a line read twice is kept once (by its sequence).
      if (chat.Count > 0) lastEvent = chat.First + chat.Count - 1;
      var added = false;
      foreach (var line in CloudChatRules.Lines(chat.Events)) added |= lines.TryAdd(line.Sequence, line);
      if (added || !newer) Render();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { reading = false; }
  }

  private void Render()
  {
    var atEnd = scroller.VerticalOffset >= scroller.ScrollableHeight - 24;
    messages.Children.Clear();
    foreach (var line in lines.Values) messages.Children.Add(line.Person ? PersonBubble(line.Text) : AiText(line.Text));
    if (atEnd) DispatcherQueue.TryEnqueueHandled(() => scroller.ChangeView(null, scroller.ScrollableHeight, null, true));
  }

  // The person's message: a soft tinted bubble at the right, as in a local chat.
  private static FrameworkElement PersonBubble(string text)
  {
    var words = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 13 };
    var bubble = new Border { Child = words, Padding = new(12, 7, 12, 7), CornerRadius = new(14), HorizontalAlignment = HorizontalAlignment.Right, MaxWidth = 560 };
    bubble.SetResourceReference(Border.BackgroundProperty, "DeckSidebarSelectionInactiveBrush");
    return bubble;
  }

  // The AI's answer: plain text on the page, no bubble.
  private static FrameworkElement AiText(string text) =>
    new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 13, Margin = new(0, 0, 48, 0) };
}
