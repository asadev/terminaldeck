using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TerminalDeck.App.Views.Notices;

// The anchor takes no space. Its card is a last child of the owning grid,
// spanning the content rows, so neither appearance nor dismissal moves content.
public sealed class CompactNotice : Grid
{
  private readonly TextBlock words = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, MaxWidth = 360 };
  private readonly StackPanel actions = new() { Spacing = 6 };
  private readonly Button dismiss = new() { Content = "Dismiss", FontSize = 11, MinHeight = 24, Padding = new Thickness(6, 2, 6, 2), HorizontalAlignment = HorizontalAlignment.Right };
  private readonly Border card;
  private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
  private Grid? host;
  private readonly List<(FrameworkElement Element, long Token)> visibilityWatches = [];
  private FrameworkElement? scope;
  private string message = "";
  private bool open;
  private bool closable = true;
  private bool autoDismiss = true;
  private UIElement? action;
  private InfoBarSeverity severity;
  public FrameworkElement? Scope { get => scope; set { if (scope == value) return; RemoveCard(); scope = value; Refresh(); } }
  public bool AutoDismiss { get => autoDismiss; set { autoDismiss = value; RestartTimer(); } }
  public bool IsClosable { get => closable; set { closable = value; dismiss.Visibility = value ? Visibility.Visible : Visibility.Collapsed; } }
  public string Message { get => message; set { if (message == value) return; message = value; words.Text = value; Refresh(); RestartTimer(); } }
  public string Text { get => Message; set { Message = value; IsOpen = !string.IsNullOrWhiteSpace(value); } }
  public InfoBarSeverity Severity { get => severity; set { severity = value; AutomationProperties.SetName(card, value + ": " + message); } }
  public UIElement? ActionButton { get => action; set { if (action == value) return; action = value; actions.Children.Clear(); if (value is not null) actions.Children.Add(value); Refresh(); } }
  public bool IsOpen { get => open; set { if (open == value) return; open = value; Refresh(); RestartTimer(); } }
  internal FrameworkElement Surface => card;
  internal bool IsPresented => host is not null && card.Visibility == Visibility.Visible;

  public CompactNotice()
  {
    Width = 0; Height = 0; MinWidth = 0; MinHeight = 0;
    HorizontalAlignment = HorizontalAlignment.Left; VerticalAlignment = VerticalAlignment.Top;
    var body = new StackPanel { Spacing = 6 }; body.Children.Add(words); body.Children.Add(actions); body.Children.Add(dismiss);
    card = new Border { Child = body, CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(12), MaxWidth = 392,
      HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Visibility = Visibility.Collapsed };
    AutomationProperties.SetLiveSetting(card, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
    timer = DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromSeconds(8); timer.IsRepeating = false;
    timer.Tick += (_, _) => { open = false; card.Visibility = Visibility.Collapsed; };
    dismiss.Click += (_, _) => IsOpen = false;
    Loaded += (_, _) => { Refresh(); RestartTimer(); };
    Unloaded += (_, _) => { timer.Stop(); RemoveCard(); };
    ActualThemeChanged += (_, _) => ApplyTheme();
  }
  private void RemoveCard()
  {
    foreach (var watch in visibilityWatches) watch.Element.UnregisterPropertyChangedCallback(VisibilityProperty, watch.Token);
    visibilityWatches.Clear();
    if (host is { } previous) { host = null; previous.SizeChanged -= HostSizeChanged; previous.Children.Remove(card); }
  }
  private void HostSizeChanged(object sender, SizeChangedEventArgs args) => FitCard();
  private void FitCard()
  {
    if (host is null) return;
    var available = Math.Max(96, host.ActualWidth - 24);
    card.MaxWidth = Math.Min(392, available); words.MaxWidth = Math.Max(72, card.MaxWidth - 24);
  }
  private void RestartTimer()
  {
    timer.Stop();
    if (open && IsLoaded && autoDismiss && action is null) timer.Start();
  }
  private void ApplyTheme()
  {
    if (!IsLoaded) return;
    card.RequestedTheme = ActualTheme;
    card.Background = (Brush)TerminalDeck.App.Shell.ShellTheme.Resource(this, "DeckGlassBrush");
    words.Foreground = (Brush)TerminalDeck.App.Shell.ShellTheme.Resource(this, "DeckInkBrush");
  }
  private void Refresh()
  {
    if (!IsLoaded) return;
    if (host is null)
    {
      DependencyObject? parent = scope ?? VisualTreeHelper.GetParent(this);
      if (parent is Border border) parent = border.Child;
      while (parent is not null)
      {
        if (parent is Grid grid && parent != this && grid.ActualHeight > 100 && grid.ActualWidth > 120) { host = grid; break; }
        parent = VisualTreeHelper.GetParent(parent);
      }
      if (host is null) return;
      SetRowSpan(card, Math.Max(1, host.RowDefinitions.Count)); SetColumnSpan(card, Math.Max(1, host.ColumnDefinitions.Count));
      Canvas.SetZIndex(card, 1000); host.Children.Add(card); host.SizeChanged += HostSizeChanged; FitCard(); ApplyTheme();
      DependencyObject? ancestor = this;
      while (ancestor is FrameworkElement element && ancestor != host)
      {
        var token = element.RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => Refresh());
        visibilityWatches.Add((element, token)); ancestor = VisualTreeHelper.GetParent(ancestor);
      }
    }
    card.Visibility = open && !string.IsNullOrWhiteSpace(message) && visibilityWatches.All(w => w.Element.Visibility == Visibility.Visible) ? Visibility.Visible : Visibility.Collapsed;
  }
}
