using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

// The terminal mark is drawn here rather than using CommandPrompt's enclosing box.
public sealed class SessionTypeIcon : Grid
{
  public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(SessionTypeIcon), new PropertyMetadata("", Changed));
  public static readonly DependencyProperty StateProperty = DependencyProperty.Register(nameof(State), typeof(string), typeof(SessionTypeIcon), new PropertyMetadata("", Changed));
  public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
  public string State { get => (string)GetValue(StateProperty); set => SetValue(StateProperty, value); }
  private bool onAccent;
  public bool OnAccent { get => onAccent; set { if (onAccent == value) return; onAccent = value; Draw(); } }
  private Storyboard? pulse;
  private static void Changed(DependencyObject sender, DependencyPropertyChangedEventArgs args) => ((SessionTypeIcon)sender).Draw();
  public SessionTypeIcon()
  {
    Width = Height = 18; VerticalAlignment = VerticalAlignment.Center;
    Loaded += (_, _) => Draw(); Unloaded += (_, _) => { pulse?.Stop(); pulse = null; };
    ActualThemeChanged += (_, _) => Draw();
  }
  private void Draw()
  {
    pulse?.Stop(); pulse = null; Opacity = 1; Children.Clear();
    var working = State.ToLowerInvariant() is "working" or "sending";
    var brush = (Brush)ShellTheme.Resource(this, OnAccent ? "DeckSidebarSelectionInkBrush" : working ? "AccentFillColorDefaultBrush" : "DeckSecondaryInkBrush");
    if (Glyph == SidebarRowLook.ChatGlyph) Children.Add(new DeckIcon { Glyph = Glyph, FontSize = 14, Foreground = brush, VerticalAlignment = VerticalAlignment.Center });
    else
    {
      var geometry = new PathGeometry();
      var chevron = new PathFigure { StartPoint = new(2, 4.5), IsClosed = false };
      chevron.Segments.Add(new LineSegment { Point = new(8, 9) }); chevron.Segments.Add(new LineSegment { Point = new(2, 13.5) });
      var underline = new PathFigure { StartPoint = new(10, 13.5), IsClosed = false }; underline.Segments.Add(new LineSegment { Point = new(16, 13.5) });
      geometry.Figures.Add(chevron); geometry.Figures.Add(underline);
      Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = brush, StrokeThickness = 1.6, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round });
    }
    if (!working || !IsLoaded || !new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled) return;
    var fade = new DoubleAnimation { From = 1, To = .35, Duration = TimeSpan.FromSeconds(1.1), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
    Storyboard.SetTarget(fade, this); Storyboard.SetTargetProperty(fade, nameof(Opacity));
    pulse = new(); pulse.Children.Add(fade); pulse.Begin();
  }
}
