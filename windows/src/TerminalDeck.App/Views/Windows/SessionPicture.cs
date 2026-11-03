using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Agents;

namespace TerminalDeck.App.Views;

// One phone-style picture for running, history, project and search rows. The
// project ring follows its containing row; selection never recolours the avatar.
public sealed class SessionPicture : Grid
{
  public static readonly DependencyProperty SessionProperty = DependencyProperty.Register(nameof(Session), typeof(SessionDraft), typeof(SessionPicture), new PropertyMetadata(null, (target, args) =>
  {
    var picture = (SessionPicture)target;
    if (args.OldValue is SessionDraft old) old.PropertyChanged -= picture.Changed;
    if (args.NewValue is SessionDraft next) next.PropertyChanged += picture.Changed;
    picture.Refresh();
  }));
  public static readonly DependencyProperty OnAccentProperty = DependencyProperty.Register(nameof(OnAccent), typeof(bool), typeof(SessionPicture), new PropertyMetadata(false, (target, _) => ((SessionPicture)target).Refresh()));
  public SessionDraft? Session { get => (SessionDraft?)GetValue(SessionProperty); set => SetValue(SessionProperty, value); }
  public string SurfaceResource { get; set; } = "DeckCanvasBrush";
  public bool OnAccent { get => (bool)GetValue(OnAccentProperty); set => SetValue(OnAccentProperty, value); }
  // Set once by the shell: the same project tile the Projects list draws (logo,
  // else the coloured letter tile), so a row badge never invents its own look.
  internal static TerminalDeck.Core.Projects.IProjects? Projects { get; set; }
  public SessionPicture()
  {
    Width = Height = 28;
    AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
    Loaded += (_, _) => { if (Session is { } row) { row.PropertyChanged -= Changed; row.PropertyChanged += Changed; } Refresh(); };
    Unloaded += (_, _) => { if (Session is { } row) row.PropertyChanged -= Changed; };
    SizeChanged += (_, _) => Refresh(); ActualThemeChanged += (_, _) => Refresh();
  }
  private void Changed(object? sender, PropertyChangedEventArgs args)
  {
    if (args.PropertyName is null or nameof(SessionDraft.AgentIcon) or nameof(SessionDraft.PicturePath) or nameof(SessionDraft.HasProject)) Refresh();
  }
  internal void RowSurface(string resource) { SurfaceResource = resource; Refresh(); }
  private Brush Ink(string key) => (Brush)ShellTheme.Resource(this, key);
  private void Refresh()
  {
    Children.Clear();
    if (Session is not { } row) return;
    var size = double.IsFinite(Width) ? Width : 28;
    if (row.HasAgent)
    {
      var (symbol, colour) = AgentPictures.Parse(row.AgentIcon);
      if (symbol.StartsWith("sf:", StringComparison.Ordinal)) symbol = symbol[3..];
      var tile = new Border { Width = size, Height = size, CornerRadius = new(size * 0.28), Background = Ink("DeckSessionAvatarBrush") };
      if (row.IsHoot)
        tile.Child = new Image { Width = size * 0.78, Height = size * 0.78, Source = new SvgImageSource(new("ms-appx:///Assets/icons/hoot.svg")) };
      else if (symbol.StartsWith("emoji:", StringComparison.Ordinal))
        tile.Child = new TextBlock { Text = symbol[6..], FontSize = size * 0.60, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
      else if (symbol == "chart.bar")
        tile.Child = new DeckIcon { Glyph = "usage", FontSize = size * 0.52, Foreground = Ink(ColourBrush(colour)) };
      else
        tile.Child = new DeckIcon { Glyph = Glyph(symbol), FontSize = size * 0.52, FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, Foreground = Ink(ColourBrush(colour)) };
      Children.Add(tile);
    }
    else if (row.Provider == "shell" && ShellIcons.For(row.Shell) is { } program)
      Children.Add(new Image { Source = program, Width = size * 0.62, Height = size * 0.62, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
    else Children.Add(new DeckIcon { Glyph = WorkspaceIcons.For(row.Presentation == SessionPresentation.Chat ? "chat" : "terminal"), FontSize = size * 0.58, FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, Foreground = Ink(OnAccent ? "DeckSidebarSelectionInkBrush" : "DeckSecondaryInkBrush") });
    if (!row.HasProject) return;
    var badge = Math.Round(size * 0.52);
    var tileRadius = Math.Max(3, badge * 0.25);
    UIElement project;
    if (Projects?.List().FirstOrDefault(p => p.Id == row.ProjectId) is { } saved)
    {
      project = TerminalDeck.App.Views.Projects.ProjectAgentUi.ProjectPicture(Projects, saved, badge);
      if (project is Border tile) { tile.CornerRadius = new(tileRadius); if (tile.Child is TextBlock letter) letter.FontSize = badge * 0.62; }
    }
    else
    {
      var fallback = new Border { Width = badge, Height = badge, CornerRadius = new(tileRadius), Background = Ink("DeckProjectBlueBrush") };
      fallback.Child = new TextBlock { Text = row.ProjectInitial, FontSize = badge * 0.62, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
      project = fallback;
    }
    var ring = new Border { Child = project, Padding = new(1.5), CornerRadius = new(tileRadius + 1.5), Background = Ink(OnAccent ? "DeckSidebarSelectionBrush" : SurfaceResource), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, RenderTransform = new TranslateTransform { X = size * 0.2, Y = size * 0.2 } };
    Children.Add(ring);
  }
  internal static Geometry ChartBars()
  {
    var path = new PathGeometry();
    foreach (var (x, y) in new[] { (1d, 8d), (6d, 4d), (11d, 1d) })
    {
      var bar = new PathFigure { StartPoint = new(x, y), IsClosed = true, IsFilled = true };
      bar.Segments.Add(new LineSegment { Point = new(x + 3, y) });
      bar.Segments.Add(new LineSegment { Point = new(x + 3, 15) });
      bar.Segments.Add(new LineSegment { Point = new(x, 15) });
      path.Figures.Add(bar);
    }
    return path;
  }
  private static string ColourBrush(string colour) => colour switch
  {
    "purple" => "DeckProjectPurpleBrush", "pink" => "DeckProjectPinkBrush", "orange" => "DeckProjectOrangeBrush",
    "green" => "DeckProjectGreenBrush", "mint" => "DeckAgentMintBrush", "teal" => "DeckProjectTealBrush", "yellow" => "DeckProjectYellowBrush",
    "graphite" => "DeckProjectGraphiteBrush", "brown" => "DeckAgentBrownBrush", "red" => "DeckAgentRedBrush", "indigo" => "DeckAgentIndigoBrush", _ => "DeckProjectBlueBrush"
  };
  private static string Glyph(string symbol) => symbol switch
  {
    "terminal" => "\uE756", "code" => "\uE943", "magnifyingglass" => "\uE721", "pencil" => "\uE70F", "hammer" => "\uE90F",
    "lightbulb" => "\uEA80", "briefcase" => "\uE821", "chart.bar" => "\uE9D2", "gearshape" => "\uE713", "shield" => "\uEA18",
    "star" => "\uE734", "bolt" => "\uE945", _ => WorkspaceIcons.For("agents")
  };
}
