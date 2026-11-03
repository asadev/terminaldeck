using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed class SessionStatusMark : Grid
{
  private readonly Microsoft.UI.Xaml.Shapes.Ellipse dot = new() { Width = 7, Height = 7, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
  public static readonly DependencyProperty StateProperty = DependencyProperty.Register(nameof(State), typeof(string), typeof(SessionStatusMark), new PropertyMetadata("draft", Changed));
  public static readonly DependencyProperty UnreadProperty = DependencyProperty.Register(nameof(Unread), typeof(bool), typeof(SessionStatusMark), new PropertyMetadata(false, Changed));
  public static readonly DependencyProperty OnAccentProperty = DependencyProperty.Register(nameof(OnAccent), typeof(bool), typeof(SessionStatusMark), new PropertyMetadata(false, Changed));
  public bool OnAccent { get => (bool)GetValue(OnAccentProperty); set => SetValue(OnAccentProperty, value); }
  public static readonly DependencyProperty OnlyUnreadProperty = DependencyProperty.Register(nameof(OnlyUnread), typeof(bool), typeof(SessionStatusMark), new PropertyMetadata(false, Changed));
  public bool OnlyUnread { get => (bool)GetValue(OnlyUnreadProperty); set => SetValue(OnlyUnreadProperty, value); }
  public string State { get => (string)GetValue(StateProperty); set => SetValue(StateProperty, value); }
  public bool Unread { get => (bool)GetValue(UnreadProperty); set => SetValue(UnreadProperty, value); }
  public SessionStatusMark() { Width = 12; Height = 14; Children.Add(dot); ActualThemeChanged += (_, _) => Refresh(); Loaded += (_, _) => Refresh(); }
  private static void Changed(DependencyObject sender, DependencyPropertyChangedEventArgs _) => ((SessionStatusMark)sender).Refresh();
  private void Refresh()
  {
    var status = SessionStatus.From(State);
    Visibility = OnlyUnread && !Unread ? Visibility.Collapsed : Visibility.Visible;
    // A live keeper process is not evidence that its AI is busy.
    var brush = State.ToLowerInvariant() is "running" or "chat" or "ready" or "draft" ? "DeckSecondaryInkBrush" : status.Brush;
    dot.Fill = (Brush)ShellTheme.Resource(this, OnAccent ? "DeckSidebarSelectionInkBrush" : Unread ? "AccentFillColorDefaultBrush" : brush);
    var name = status.Label + (Unread ? " · Unread output" : ""); AutomationProperties.SetName(this, name); ToolTipService.SetToolTip(this, name);
  }
}
