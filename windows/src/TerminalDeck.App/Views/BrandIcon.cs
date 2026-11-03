using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace TerminalDeck.App.Views;

// One piece of artwork per identity, in both themes and at every display scale.
public sealed class BrandIcon : Grid
{
  public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(string), typeof(BrandIcon), new PropertyMetadata("shell", (target, _) => ((BrandIcon)target).Refresh()));
  public string Kind { get => (string)GetValue(KindProperty); set => SetValue(KindProperty, value); }
  public static readonly DependencyProperty OnDarkProperty = DependencyProperty.Register(nameof(OnDark), typeof(bool), typeof(BrandIcon), new PropertyMetadata(false, (target, _) => ((BrandIcon)target).Refresh()));
  public bool OnDark { get => (bool)GetValue(OnDarkProperty); set => SetValue(OnDarkProperty, value); }
  // For a terminal: which shell it runs (TerminalShells), shown with that program's own icon.
  public static readonly DependencyProperty ShellProperty = DependencyProperty.Register(nameof(Shell), typeof(string), typeof(BrandIcon), new PropertyMetadata(null, (target, _) => ((BrandIcon)target).Refresh()));
  public string? Shell { get => (string?)GetValue(ShellProperty); set => SetValue(ShellProperty, value); }
  private readonly Image image = new();
  private readonly DeckIcon terminal = new() { Glyph = "terminal" };
  public BrandIcon()
  {
    Children.Add(image); Children.Add(terminal);
    SizeChanged += (_, _) => Refresh();
    Loaded += (_, _) => Refresh(); ActualThemeChanged += (_, _) => Refresh(); Refresh();
  }
  private void Refresh()
  {
    var kind = Kind?.ToLowerInvariant() ?? "shell";
    if (kind.Contains("claude")) kind = "claude";
    else if (kind.Contains("codex")) kind = "codex";
    else if (kind.Contains("gemini")) kind = "gemini";
    else if (kind != "hoot") kind = "shell";
    if (kind == "shell" && ShellIcons.For(Shell) is { } program)
    {
      terminal.Visibility = Visibility.Collapsed; image.Visibility = Visibility.Visible; image.Source = program; return;
    }
    terminal.Visibility = kind == "shell" ? Visibility.Visible : Visibility.Collapsed;
    image.Visibility = kind == "shell" ? Visibility.Collapsed : Visibility.Visible;
    terminal.FontSize = ActualWidth > 0 ? Math.Min(ActualWidth, ActualHeight > 0 ? ActualHeight : ActualWidth) : (double.IsFinite(Width) ? Width : 16);
    var file = kind == "hoot" ? "hoot" : kind + (OnDark || ActualTheme == ElementTheme.Dark ? "-dark" : "-light");
    image.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/" + file + ".svg"));
  }
}
