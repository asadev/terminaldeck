using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Usage;

namespace TerminalDeck.App.Views.Usage;

/// The session header's usage control, as on the Mac (NativeUsageBar): the context window as a
/// small strip (only while the figure is fresh) and the account's plan limits behind a ring.
/// Hovering either opens its card; a press pins it; opening the plan card asks for fresh figures.
/// Figures are re-read when the AI's own files change (no polling); a 30 s tick only ages them.
public sealed class UsageMeter : StackPanel
{
  private readonly UsageService usage;
  private readonly string sessionId;
  private readonly string provider;
  private readonly DispatcherQueue queue;
  private readonly Button stripButton = new(), ringButton = new();
  private readonly Grid strip = new() { Width = 36, Height = 5, VerticalAlignment = VerticalAlignment.Center };
  private readonly Border stripFill = new() { CornerRadius = new(2.5), HorizontalAlignment = HorizontalAlignment.Left };
  // The Mac ring: 12 pt frame with a 2 pt line centred on its edge, so it reads 14 across.
  private const double RingSize = 14, RingLine = 2;
  private readonly Grid ring = new() { Width = RingSize, Height = RingSize };
  private Storyboard? pulse;
  private readonly StackPanel contextCard = new() { Spacing = 5, Width = 276 }, planCard = new() { Spacing = 8, Width = 276 };
  private readonly Flyout contextFlyout = new(), planFlyout = new();
  private readonly DispatcherQueueTimer tick;
  private UsageReport? report;
  private ContextReading? context;
  private UsagePanelState panel = UsagePanelState.Shut;
  private bool checking, failed;
  private string? blocked, detail;
  private IDisposable? watch;
  private int version;
  private CancellationTokenSource? cap;

  public UsageMeter(UsageService usage, string sessionId, string provider)
  {
    this.usage = usage; this.sessionId = sessionId; this.provider = provider;
    queue = DispatcherQueue.GetForCurrentThread();
    Orientation = Orientation.Horizontal; Spacing = 6; VerticalAlignment = VerticalAlignment.Center; Margin = new(0, 0, 4, 0);

    var track = new Border { CornerRadius = new(2.5) }; track.SetResourceReference(Border.BackgroundProperty, "DeckDividerBrush");
    strip.Children.Add(track); strip.Children.Add(stripFill);
    Plain(stripButton, strip); stripButton.Visibility = Visibility.Collapsed;
    var capsule = new Border { CornerRadius = new((RingSize + 6) / 2), Padding = new(6, 3, 6, 3), Child = ring };
    capsule.SetResourceReference(Border.BackgroundProperty, "DeckHoverBrush");
    Plain(ringButton, capsule);
    Children.Add(stripButton); Children.Add(ringButton);

    foreach (var (flyout, card) in new[] { (contextFlyout, contextCard), (planFlyout, planCard) })
    {
      flyout.Content = card; flyout.Placement = FlyoutPlacementMode.Bottom;
      flyout.Closed += (_, _) =>
      {
        if (shownPinned == flyout) shownPinned = null;
        // A hover card turning into a pinned one closes first, then opens again in the pinned mode.
        if (reopenPinned == flyout) { reopenPinned = null; queue.TryEnqueue(() => Open(flyout, flyout == planFlyout ? ringButton : stripButton, true)); return; }
        if (panel.Open == (flyout == planFlyout ? UsagePanel.Plan : UsagePanel.Context)) panel = UsagePanelState.Shut;
      };
    }
    // An open card keeps the theme it opened with; close it when the window's theme changes.
    ActualThemeChanged += (_, _) => { if (planFlyout.IsOpen) planFlyout.Hide(); if (contextFlyout.IsOpen) contextFlyout.Hide(); };
    stripButton.PointerEntered += (_, _) => Send(panel.Hover(UsagePanel.Context));
    ringButton.PointerEntered += (_, _) => Send(panel.Hover(UsagePanel.Plan));
    stripButton.Click += (_, _) => Send(panel.Press(UsagePanel.Context));
    ringButton.Click += (_, _) => Send(panel.Press(UsagePanel.Plan));

    tick = queue.CreateTimer(); tick.Interval = TimeSpan.FromSeconds(30); tick.IsRepeating = true; tick.Tick += (_, _) => Render();
    Loaded += (_, _) =>
    {
      watch ??= usage.Watch(sessionId); usage.Changed += OnChanged;
      tick.Start(); Reload();
    };
    Unloaded += (_, _) => { usage.Changed -= OnChanged; watch?.Dispose(); watch = null; tick.Stop(); cap?.Cancel(); Pulse(false); };
    Render();
  }

  private static void Plain(Button button, UIElement content)
  {
    button.Content = content; button.Padding = new(0); button.MinWidth = 0; button.MinHeight = 0; button.BorderThickness = new(0);
    button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); button.VerticalAlignment = VerticalAlignment.Center;
    button.Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"]; button.Width = double.NaN; button.Height = double.NaN;
  }

  // At most one read a second while an AI streams (Mac: once a second while output flows).
  private bool reloadPending;
  private void OnChanged(string id)
  {
    if (id != sessionId) return;
    queue.TryEnqueue(() =>
    {
      if (reloadPending) return; reloadPending = true;
      var once = queue.CreateTimer(); once.Interval = TimeSpan.FromSeconds(1); once.IsRepeating = false;
      once.Tick += (_, _) => { reloadPending = false; Reload(); }; once.Start();
    });
  }

  /// Reads off the UI thread (file reads), then draws. A newer read wins.
  private void Reload()
  {
    var mine = ++version;
    _ = Task.Run(() =>
    {
      UsageReport? nextReport = null; ContextReading? nextContext = null;
      try { nextReport = usage.Read(sessionId); nextContext = usage.Context(sessionId); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException) { }
      queue.TryEnqueue(() => { if (mine != version) return; report = nextReport ?? report; context = nextContext ?? context; Render(); });
    });
  }

  private void Send(UsagePanelState next)
  {
    var before = panel; panel = next;
    if (UsagePanelState.OpensPlan(before, next)) Check(false);
    Show(contextFlyout, stripButton, next.Open == UsagePanel.Context, next.Pinned);
    Show(planFlyout, ringButton, next.Open == UsagePanel.Plan, next.Pinned);
  }
  private Flyout? shownPinned, reopenPinned;
  private void Show(Flyout flyout, FrameworkElement anchor, bool open, bool pinned)
  {
    if (!open) { if (flyout.IsOpen) flyout.Hide(); return; }
    if (flyout.IsOpen && (!pinned || shownPinned == flyout)) return;
    if (flyout.IsOpen) { reopenPinned = flyout; flyout.Hide(); return; }
    Open(flyout, anchor, pinned);
  }
  private void Open(Flyout flyout, FrameworkElement anchor, bool pinned)
  {
    if (anchor.Visibility != Visibility.Visible || anchor.XamlRoot is null) { panel = UsagePanelState.Shut; return; }
    shownPinned = pinned ? flyout : null;
    // The card lives in a popup: give it the window's theme so a dark window never
    // gets a light card (its brushes are resolved from the card's own theme).
    var theme = anchor.ActualTheme;
    if (flyout.FlyoutPresenterStyle?.Setters.OfType<Setter>().FirstOrDefault(s => s.Property == FrameworkElement.RequestedThemeProperty)?.Value is not ElementTheme shown || shown != theme)
    {
      var style = new Style(typeof(FlyoutPresenter));
      if (Application.Current.Resources.TryGetValue(typeof(FlyoutPresenter), out var glass) && glass is Style basedOn) style.BasedOn = basedOn;
      style.Setters.Add(new Setter(FrameworkElement.RequestedThemeProperty, theme));
      flyout.FlyoutPresenterStyle = style;
    }
    if (flyout.Content is FrameworkElement card && card.RequestedTheme != theme) { card.RequestedTheme = theme; Render(); }
    flyout.ShowAt(anchor, new FlyoutShowOptions { Placement = FlyoutPlacementMode.Bottom, ShowMode = pinned ? FlyoutShowMode.Standard : FlyoutShowMode.TransientWithDismissOnPointerMoveAway });
  }

  /// Opening the plan card is the refresh; "Check again" forces past a settled answer.
  private void Check(bool force)
  {
    checking = true; if (force) blocked = null;
    cap?.Cancel(); var mine = cap = new CancellationTokenSource();
    Render();
    _ = Task.Run(async () =>
    {
      UsageProbeOutcome? outcome = null;
      try
      {
        var asking = usage.RefreshAsync(sessionId, force).AsTask();
        if (await Task.WhenAny(asking, Task.Delay(TimeSpan.FromSeconds(UsageBarRules.RefreshCapSeconds), mine.Token)) == asking) outcome = await asking;
      }
      catch (Exception ex) when (ex is OperationCanceledException or IOException or InvalidOperationException) { }
      queue.TryEnqueue(() =>
      {
        if (mine.IsCancellationRequested && outcome is null) return;
        checking = false;
        if (outcome is null) { failed = true; detail = UsageBarRules.GaveUp; Render(); return; }
        detail = outcome.Detail; failed = !outcome.Ok;
        if (outcome.Ok) blocked = null;
        else if (UsageBarRules.Settled(outcome.Kind)) blocked = outcome.Detail;
        Reload();
      });
    });
  }

  private static string AgentName(string provider) => provider switch { "claude" => "Claude Code", "codex" => "Codex", "gemini" => "Gemini CLI", _ => provider };

  private void Render()
  {
    var now = UsageFormat.Now();
    var readouts = (report?.Readings ?? []).Select(r => UsageReadout.Of(r, now)).ToArray();
    var worst = UsageBarRules.Worst(readouts);
    var account = report?.ReportedAccount?.Name;
    var whose = string.Join(" · ", new[] { AgentName(provider), account }.Where(s => !string.IsNullOrEmpty(s)));
    var withheld = report?.Reason == UsageBarRules.ServerWithheld ? report.Reason : null;
    var title = UsageBarRules.Title(readouts, whose, withheld, blocked, report);

    // The strip shows only a figure written just now, as on the Mac.
    var fresh = context is { } c && c.IsFresh(now) && c.Figure() is not null ? c : null;
    if (fresh is not null && fresh.Share is { } share)
    {
      stripButton.Visibility = Visibility.Visible; stripButton.Content = strip;
      stripFill.Width = 36 * share / 100; stripFill.Background = LevelBrush(fresh.Level);
    }
    else if (fresh?.Figure() is { } figure)
    {
      stripButton.Visibility = Visibility.Visible;
      var text = new TextBlock { Text = figure, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
      text.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); stripButton.Content = text;
    }
    else { stripButton.Visibility = Visibility.Collapsed; if (contextFlyout.IsOpen) contextFlyout.Hide(); }
    var summary = fresh?.Summary(now) ?? "Context window";
    AutomationProperties.SetName(stripButton, summary); ToolTipService.SetToolTip(stripButton, null);

    DrawRing(worst?.Percent, worst?.Level ?? UsageLevel.Ok);
    Pulse(checking);
    AutomationProperties.SetName(ringButton, "Plan limits: " + title);

    // Context card.
    contextCard.Children.Clear();
    if (context?.Panel(now) is { } breakdown) ContextSection(contextCard, breakdown);

    // Plan card: whose limits, each window, the check state.
    planCard.Children.Clear();
    if (context is { } any && any.Panel(now) is { } inline && fresh is null) ContextSection(planCard, inline);
    var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
    header.Children.Add(new TextBlock { Text = AgentName(provider), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 13 });
    if (account is not null) header.Children.Add(Secondary(account, 13));
    var note = UsageBarRules.PanelNote(withheld, blocked, failed, detail, report?.Reason, readouts.Length);
    if (note is not null)
    {
      var info = new TextBlock { Text = "", FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
      info.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
      ToolTipService.SetToolTip(info, note); AutomationProperties.SetName(info, "About these plan limits: " + note); header.Children.Add(info);
    }
    planCard.Children.Add(header);
    if (note is not null && readouts.Length == 0) planCard.Children.Add(Secondary(note, 12, wrap: true));
    foreach (var readout in readouts) planCard.Children.Add(WindowRow(readout));
    if (checking) planCard.Children.Add(Secondary("Checking with " + AgentName(provider) + "…", 12));
    if (blocked is not null)
    {
      var again = new Button { Content = "Check again" }; again.Click += (_, _) => Check(true); planCard.Children.Add(again);
    }
  }

  private void DrawRing(double? percent, UsageLevel level)
  {
    ring.Children.Clear();
    // XAML insets an Ellipse's stroke, so the track and the arc share one centre line.
    var track = new Ellipse { Width = RingSize, Height = RingSize, StrokeThickness = RingLine, Opacity = 0.3 };
    track.SetResourceReference(Shape.StrokeProperty, "DeckSecondaryInkBrush"); ring.Children.Add(track);
    var filled = Math.Clamp((percent ?? 0) / 100, 0, 1);
    if (filled <= 0) return;
    if (filled >= 0.999) { ring.Children.Add(new Ellipse { Width = RingSize, Height = RingSize, StrokeThickness = RingLine, Stroke = LevelBrush(level) }); return; }
    // An arc from twelve o'clock, clockwise, on the track's centre line.
    const double centre = RingSize / 2, radius = (RingSize - RingLine) / 2;
    var angle = filled * 2 * Math.PI; var end = new Windows.Foundation.Point(centre + radius * Math.Sin(angle), centre - radius * Math.Cos(angle));
    var figure = new PathFigure { StartPoint = new(centre, centre - radius), IsClosed = false };
    figure.Segments.Add(new ArcSegment { Point = end, Size = new(radius, radius), SweepDirection = SweepDirection.Clockwise, IsLargeArc = filled > 0.5 });
    var geometry = new PathGeometry(); geometry.Figures.Add(figure);
    ring.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = LevelBrush(level), StrokeThickness = RingLine, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
  }

  // While a check runs the ring breathes between full and 55% opacity, as on the
  // Mac (0.8 s ease in-out, repeating). With Windows animations off it just dims.
  private void Pulse(bool on)
  {
    if (!on || !IsLoaded || !new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
    {
      pulse?.Stop(); pulse = null; ring.Opacity = on ? 0.55 : 1; return;
    }
    if (pulse is not null) return;
    var fade = new DoubleAnimation { From = 1, To = 0.55, Duration = TimeSpan.FromSeconds(0.8), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
    Storyboard.SetTarget(fade, ring); Storyboard.SetTargetProperty(fade, nameof(Opacity));
    pulse = new Storyboard(); pulse.Children.Add(fade); pulse.Begin();
  }

  /// "Context window" with the figure, the used/free bar and rows, and the facts.
  private static void ContextSection(Panel host, ContextPanel breakdown)
  {
    var section = new StackPanel { Spacing = 5 };
    section.Children.Add(Row(new TextBlock { Text = "Context window", FontSize = 13 }, new TextBlock { Text = breakdown.Headline, FontSize = 13, Foreground = LevelBrush(breakdown.Level) }));
    if (breakdown.Segments.Count > 0)
    {
      var bar = new Grid { Height = 6, CornerRadius = new(3) };
      foreach (var segment in breakdown.Segments) bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.0001, segment.Width), GridUnitType.Star) });
      for (var i = 0; i < breakdown.Segments.Count; i++)
      {
        var piece = new Border { Margin = new(0, 0, i < breakdown.Segments.Count - 1 ? 1 : 0, 0) };
        if (breakdown.Segments[i].Key == "used") piece.Background = LevelBrush(breakdown.Level); else { piece.SetResourceReference(Border.BackgroundProperty, "DeckDividerBrush"); }
        Grid.SetColumn(piece, i); bar.Children.Add(piece);
      }
      section.Children.Add(bar);
      foreach (var segment in breakdown.Segments)
      {
        var dot = new Ellipse { Width = 6, Height = 6, VerticalAlignment = VerticalAlignment.Center };
        if (segment.Key == "used") dot.Fill = LevelBrush(breakdown.Level); else dot.SetResourceReference(Shape.FillProperty, "DeckSecondaryInkBrush");
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 }; left.Children.Add(dot); left.Children.Add(new TextBlock { Text = segment.Label, FontSize = 12 });
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        right.Children.Add(new TextBlock { Text = segment.Amount, FontSize = 12 });
        var share = Secondary(segment.Share, 12); share.Width = 40; share.TextAlignment = TextAlignment.Right; right.Children.Add(share);
        section.Children.Add(Row(left, right));
      }
    }
    foreach (var fact in breakdown.Facts) section.Children.Add(Row(Secondary(fact.Label, 12), new TextBlock { Text = fact.Value, FontSize = 12 }));
    if (breakdown.Provenance.Length > 0) ToolTipService.SetToolTip(section, breakdown.Provenance);
    host.Children.Add(section);
  }

  /// One plan window: its name, its value, a meter and when it renews.
  private static FrameworkElement WindowRow(UsageReadout readout)
  {
    var row = new StackPanel { Spacing = 3 };
    row.Children.Add(Row(new TextBlock { Text = readout.Name, FontSize = 13 }, new TextBlock { Text = readout.Value, FontSize = 13, Foreground = readout.Bar ? LevelBrush(readout.Level) : null }));
    if (readout.Bar)
    {
      var bar = new Grid { Height = 5, Opacity = readout.State == "aged" ? 0.55 : 1 };
      var track = new Border { CornerRadius = new(2.5) }; track.SetResourceReference(Border.BackgroundProperty, "DeckDividerBrush");
      var fill = new Border { CornerRadius = new(2.5), HorizontalAlignment = HorizontalAlignment.Left, Background = LevelBrush(readout.Level) };
      bar.Children.Add(track); bar.Children.Add(fill);
      var share = Math.Clamp(readout.Percent ?? 0, 0, 100) / 100;
      bar.SizeChanged += (_, e) => fill.Width = e.NewSize.Width * share;
      row.Children.Add(bar);
      if (readout.Facts.Length > 0) row.Children.Add(Secondary(readout.Facts, 11));
    }
    else if (readout.Detail.Length > 0) row.Children.Add(Secondary(readout.Detail, 11, wrap: true));
    AutomationProperties.SetName(row, readout.Name + ": " + readout.Detail);
    return row;
  }

  private static Grid Row(FrameworkElement left, FrameworkElement right)
  {
    var grid = new Grid(); grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    left.VerticalAlignment = VerticalAlignment.Center; right.VerticalAlignment = VerticalAlignment.Center;
    Grid.SetColumn(right, 1); grid.Children.Add(left); grid.Children.Add(right); return grid;
  }
  private static TextBlock Secondary(string text, double size, bool wrap = false)
  {
    var block = new TextBlock { Text = text, FontSize = size, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis };
    block.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); return block;
  }
  /// ok = the accent colour, warning = orange (70%+), critical = red (90%+).
  private static Brush LevelBrush(UsageLevel level) => level switch
  {
    UsageLevel.Critical => (Brush)Application.Current.Resources["DeckStatusFailedBrush"],
    UsageLevel.Warning => (Brush)Application.Current.Resources["DeckProjectOrangeBrush"],
    _ => (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"]
  };

  /// Whether a header shows the meter at all: only where figures can exist (Claude Code and Codex on
  /// this computer). Shells, Gemini and server terminals never have any, so nothing is drawn.
  public static bool Applies(string? provider, bool onServer) => !onServer && provider is ("claude" or "codex");
}
