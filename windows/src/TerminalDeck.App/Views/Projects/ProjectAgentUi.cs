using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.Core.Agents;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Projects;
using Windows.Storage.Pickers;

namespace TerminalDeck.App.Views.Projects;

public interface IProjectsAgentsNavigation
{
  nint WindowHandle { get; }
  void OpenSession(string id);
  void OpenProject(string id);
  void OpenAgent(string id);
  Task RemoveFromSidebarAsync(string projectId) => Task.FromException(new NotSupportedException("Project session shutdown is unavailable in this window."));
}

public static class ProjectAgentUi
{
  private static readonly ConditionalWeakTable<FlyoutBase, object> themedFlyouts = new();
  public static void MatchFlyoutTheme(FrameworkElement owner, FlyoutBase flyout)
  {
    if (!themedFlyouts.TryAdd(flyout, new())) return;
    var original = flyout is Flyout panel ? panel.FlyoutPresenterStyle : (flyout as MenuFlyout)?.MenuFlyoutPresenterStyle;
    flyout.Opening += (_, _) =>
    {
      var target = flyout is MenuFlyout ? typeof(MenuFlyoutPresenter) : typeof(FlyoutPresenter);
      var style = new Style(target) { BasedOn = original }; style.Setters.Add(new Setter(FrameworkElement.RequestedThemeProperty, owner.ActualTheme));
      if (flyout is Flyout popup) { popup.FlyoutPresenterStyle = style; if (popup.Content is FrameworkElement content) content.RequestedTheme = owner.ActualTheme; }
      else if (flyout is MenuFlyout menu) menu.MenuFlyoutPresenterStyle = style;
    };
  }
  public static Style PageStyle() => (Style)XamlReader.Load("""
    <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Grid">
      <Setter Property="Background" Value="{ThemeResource ApplicationPageBackgroundThemeBrush}" />
    </Style>
    """);
  public static TextBlock Words(string text, double size = 14, bool muted = false) => new()
  {
    Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Opacity = muted ? 0.68 : 1,
    HorizontalAlignment = HorizontalAlignment.Stretch
  };
  public static TextBlock Heading(string text, double size = 28) => new() { Text = text, FontSize = size, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
  public static StackPanel Stack(double spacing = 12) => new() { Spacing = spacing, HorizontalAlignment = HorizontalAlignment.Stretch };
  public static ScrollViewer PageScroll(StackPanel body)
  {
    var scroll = new ScrollViewer { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    void Fit() => body.Width = Math.Max(0, Math.Min(1100, scroll.ActualWidth - body.Margin.Left - body.Margin.Right));
    scroll.SizeChanged += (_, _) => Fit(); scroll.Loaded += (_, _) => Fit(); return scroll;
  }
  public static Border Card(UIElement child) => new()
  {
    Child = child, Padding = new Thickness(16), CornerRadius = new CornerRadius(12),
    Style = (Style)Application.Current.Resources["SurfaceCardStyle"]
  };
  public static Button Button(string title, Action action, bool primary = false)
  {
    var b = new Button { Content = title, MinHeight = 36 };
    if (primary) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
    b.Click += (_, _) => action(); b.Loaded += (_, _) => { if (b.Flyout is { } flyout) MatchFlyoutTheme(b, flyout); }; return b;
  }
  public static Button AsyncButton(string title, Func<Task> action, bool primary = false) => Button(title, async () => await action(), primary);
  public static Grid Header(string title, string subtitle, params UIElement[] actions)
  {
    var row = new Grid { ColumnSpacing = 24 };
    row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var words = Stack(6); if (title is not ("Projects" or "Agents")) words.Children.Add(Heading(title)); words.Children.Add(Words(subtitle, muted: true)); row.Children.Add(words);
    var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Top };
    foreach (var action in actions) { if (action is Button { Flyout: { } popup } button) MatchFlyoutTheme(button, popup); buttons.Children.Add(action); } Grid.SetColumn(buttons, 1); row.Children.Add(buttons); return row;
  }
  // Keep page controls with their title; on narrow windows they get their own row.
  public static Grid PageHeader(string title, string subtitle, UIElement? badge, FrameworkElement? switcher, params UIElement[] actions)
  {
    var header = new Grid { ColumnSpacing = 16, RowSpacing = 12 };
    header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    header.RowDefinitions.Add(new() { Height = GridLength.Auto }); header.RowDefinitions.Add(new() { Height = GridLength.Auto }); header.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var identity = new Grid { ColumnSpacing = 12 };
    identity.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); identity.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    if (badge is not null) identity.Children.Add(badge);
    var words = Stack(4); words.Children.Add(Heading(title, 20));
    if (subtitle.Length > 0) words.Children.Add(Words(subtitle, 12, true));
    Grid.SetColumn(words, 1); identity.Children.Add(words); header.Children.Add(identity);
    var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    foreach (var action in actions) { if (action is Button { Flyout: { } popup } button) MatchFlyoutTheme(button, popup); buttons.Children.Add(action); }
    Grid.SetColumn(buttons, 2); header.Children.Add(buttons);
    if (switcher is not null) { Grid.SetColumn(switcher, 1); header.Children.Add(switcher); }
    void Fit()
    {
      var compact = header.ActualWidth < 900; var narrow = header.ActualWidth < 580;
      Grid.SetRow(buttons, narrow && switcher is not null ? 2 : compact ? 1 : 0); Grid.SetColumn(buttons, compact ? 0 : 2);
      Grid.SetColumnSpan(buttons, narrow ? 3 : 1); Grid.SetColumnSpan(identity, compact ? 3 : 1);
      if (switcher is not null)
      {
        Grid.SetRow(switcher, compact ? 1 : 0); Grid.SetColumn(switcher, narrow ? 0 : 1); Grid.SetColumnSpan(switcher, narrow ? 3 : compact ? 2 : 1);
      }
    }
    header.SizeChanged += (_, _) => Fit();
    return header;
  }
  public static FrameworkElement ViewSwitch(string selected, IEnumerable<string> choices, Action<string> choose)
  {
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    foreach (var choice in choices)
    {
      var button = new ToggleButton { Content = choice, IsChecked = choice == selected, MinHeight = 30, Padding = new Thickness(12, 4, 12, 4), BorderThickness = new Thickness(0) };
      AutomationProperties.SetName(button, choice + " view"); button.Checked += (_, _) => choose(choice); button.Click += (_, _) => { if (button.IsChecked != true) button.IsChecked = true; }; row.Children.Add(button);
    }
    return CompactSwitch(Card(row));
  }
  private static Border CompactSwitch(Border card) { card.Padding = new Thickness(4); return card; }
  public static Button IconButton(string glyph, string label, Action action)
  {
    var button = Button("", action); button.Content = new DeckIcon { Glyph = glyph, FontSize = 16 };
    AutomationProperties.SetName(button, label); ToolTipService.SetToolTip(button, label); return button;
  }
  public static UIElement Description(string text)
  {
    var column = Stack(6); var value = Words(text.Length == 0 ? "No description yet." : text);
    column.Children.Add(value);
    var more = new HyperlinkButton { Content = "More", Padding = new Thickness(0), MinHeight = 24, HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
    var expanded = false;
    value.MaxLines = 3; value.TextTrimming = TextTrimming.CharacterEllipsis;
    void MeasureOverflow()
    {
      if (expanded) return;
      more.Visibility = text.Length > 0 && value.IsTextTrimmed ? Visibility.Visible : Visibility.Collapsed;
    }
    value.IsTextTrimmedChanged += (_, _) => MeasureOverflow(); value.SizeChanged += (_, _) => MeasureOverflow();
    more.Click += (_, _) => { expanded = !expanded; value.MaxLines = expanded ? 0 : 3; more.Content = expanded ? "Less" : "More"; };
    AutomationProperties.SetName(more, "Show more or less of the description"); column.Children.Add(more);
    return column;
  }
  public static Button Destination(UIElement content, string label, Action action)
  {
    var button = Button("", action);
    button.Content = content; button.HorizontalAlignment = HorizontalAlignment.Stretch;
    button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Padding = new Thickness(0);
    button.Background = new SolidColorBrush(Colors.Transparent); button.BorderThickness = new Thickness(0);
    AutomationProperties.SetName(button, label); return button;
  }
  public static Grid AdaptiveColumns(IEnumerable<UIElement> items, double minimum = 260)
  {
    var grid = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
    var children = items.ToArray(); foreach (var child in children) grid.Children.Add(child);
    var count = 0;
    void Fit()
    {
      var columns = Math.Max(1, Math.Min(4, (int)((grid.ActualWidth + 12) / (minimum + 12))));
      if (count == columns) return; count = columns;
      grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
      for (var i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
      for (var i = 0; i < (children.Length + columns - 1) / columns; i++) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
      for (var i = 0; i < children.Length; i++) { Grid.SetRow((FrameworkElement)children[i], i / columns); Grid.SetColumn((FrameworkElement)children[i], i % columns); }
    }
    grid.SizeChanged += (_, _) => Fit(); Fit(); return grid;
  }
  public static Button Fact(string label, string value, string action, Action clicked)
  {
    var row = new Grid { ColumnSpacing = 18, Padding = new Thickness(14, 10, 14, 10) };
    row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = new GridLength(2, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.Children.Add(Words(label, muted: true)); var val = Words(value); Grid.SetColumn(val, 1); row.Children.Add(val);
    var arrow = new DeckIcon { Glyph = "\uE76C", FontSize = 12, Opacity = 0.5 }; Grid.SetColumn(arrow, 2); row.Children.Add(arrow);
    var b = new Button { Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), MinHeight = 44 };
    b.Click += (_, _) => clicked(); ToolTipService.SetToolTip(b, action); AutomationProperties.SetName(b, label + ": " + value + ". " + action); return b;
  }
  public static TerminalDeck.App.ViewModels.SessionDraft SessionIdentity(IProjects projects, IAgents agents, string id, string title, string provider, string mode, string? projectId)
  {
    var project = projects.List().FirstOrDefault(p => p.Id == projectId);
    var face = agents.SessionFace(id);
    var row = new TerminalDeck.App.ViewModels.SessionDraft(title, provider, "", mode.Equals("chat", StringComparison.OrdinalIgnoreCase) ? TerminalDeck.App.ViewModels.SessionPresentation.Chat : TerminalDeck.App.ViewModels.SessionPresentation.Terminal) { Id = id };
    row.SetAppearance(project?.Name ?? "", project is null ? null : projects.PicturePath(project.Id), agents.SessionLabel(id, provider), projectId, face?.Icon, face is not null && (face.Hoot || face.Id == AgentSeats.HootId));
    return row;
  }
  public static Grid SessionIdentityRow(TerminalDeck.App.ViewModels.SessionDraft session, string? detail = null)
  {
    var row = new Grid { ColumnSpacing = 12, Padding = new(8) };
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
    row.Children.Add(new SessionPicture { Session = session, Margin = new(0, 0, 6, 6), VerticalAlignment = VerticalAlignment.Center });
    var text = Stack(2); text.Children.Add(Words(session.Title)); text.Children.Add(Words(session.DisplaySubtitle, 11, true));
    if (detail is { Length: > 0 }) text.Children.Add(Words(detail, 11, true));
    Grid.SetColumn(text, 1); row.Children.Add(text); return row;
  }
  public static UIElement ProjectPicture(IProjects projects, Project project, double size = 44)
  {
    var path = projects.PicturePath(project.Id);
    if (path is not null) return new Border { Width = size, Height = size, CornerRadius = new CornerRadius(10), Child = new Image { Source = new BitmapImage(new Uri(path)), Stretch = Stretch.UniformToFill } };
    return Tile(project.Name.Length > 0 ? project.Name[..1].ToUpperInvariant() : "P", size, ProjectBrush(project.Colour));
  }
  public static UIElement AgentPicture(SavedAgent? agent, double size = 44, bool hoot = false)
  {
    if (hoot) return ChatAppearance.Avatar("hoot", size);
    var (icon, colour) = AgentPictures.Parse(agent?.Icon ?? "person");
    var emoji = icon.StartsWith("emoji:", StringComparison.Ordinal) ? icon[6..] : null;
    // Quiet neutral tile with the glyph or emoji (Mac AgentAvatar / phone AgentTile): never a coloured block.
    var tile = Tile(emoji ?? "", size, "SubtleFillColorTertiaryBrush");
    if (icon == "chart.bar")
      tile.Child = new DeckIcon { Glyph = "usage", FontSize = size * 0.52 };
    else if (emoji is null)
    {
      tile.Child = new DeckIcon
      {
        Glyph = icon switch
        {
          "terminal" => "\uE756", "code" => "\uE943", "magnifyingglass" => "\uE721", "pencil" => "\uE70F", "hammer" => "\uE90F",
          "lightbulb" => "\uEA80", "briefcase" => "\uE821", "chart.bar" => "\uE9D2", "gearshape" => "\uE713", "shield" => "\uEA18",
          "star" => "\uE734", "bolt" => "\uE945", _ => WorkspaceIcons.For("agents")
        }, FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, FontSize = size * 0.52,
        Style = (Style)XamlReader.Load("""
          <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:views="using:TerminalDeck.App.Views" TargetType="views:DeckIcon">
            <Setter Property="Foreground" Value="{ThemeResource TextFillColorSecondaryBrush}" />
          </Style>
          """)
      };
    }
    AutomationProperties.SetName(tile, agent?.Name ?? "Agent"); return tile;
  }
  private static string ProjectBrush(string colour) => colour.ToLowerInvariant() switch
  {
    "blue" or "slate" => "DeckProjectBlueBrush", "purple" or "lavender" => "DeckProjectPurpleBrush",
    "pink" or "rose" => "DeckProjectPinkBrush", "orange" or "sand" => "DeckProjectOrangeBrush",
    "yellow" or "olive" => "DeckProjectYellowBrush", "green" or "sage" => "DeckProjectGreenBrush",
    "teal" => "DeckProjectTealBrush", "graphite" => "DeckProjectGraphiteBrush", _ => "DeckProjectBlueBrush"
  };
  private static Border Tile(string text, double size, string brush) => new()
  {
    Width = size, Height = size, CornerRadius = new CornerRadius(size / 4),
    // ThemeResource stays live when the shell changes appearance without rebuilding a page.
    Style = (Style)XamlReader.Load($$"""
      <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Border">
        <Setter Property="Background" Value="{ThemeResource {{brush}}}" />
      </Style>
      """),
    Child = new TextBlock { Text = text, FontSize = size * 0.42, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
      Style = (Style)XamlReader.Load("""
        <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="TextBlock">
          <Setter Property="FontFamily" Value="{ThemeResource DeckTextFontFamily}" />
          <Setter Property="Foreground" Value="{ThemeResource TextOnAccentFillColorPrimaryBrush}" />
        </Style>
        """) }
  };
  public static TextBox Field(string label, string text = "", bool multiline = false, int max = 4000) => new()
  {
    Header = label, Text = text, MaxLength = max, AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
    MinHeight = multiline ? 120 : 32, HorizontalAlignment = HorizontalAlignment.Stretch
  };
  public static ComboBox Choice(string label, IEnumerable<(string Id, string Name)> options, string? selected = null)
  {
    var c = new ComboBox { Header = label, HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = nameof(ChoiceRow.Name), SelectedValuePath = nameof(ChoiceRow.Id) };
    foreach (var option in options) c.Items.Add(new ChoiceRow(option.Id, option.Name));
    if (selected is not null) c.SelectedValue = selected;
    if (c.SelectedIndex < 0 && c.Items.Count > 0) c.SelectedIndex = 0;
    return c;
  }
  public static string Picked(ComboBox c) => (c.SelectedItem as ChoiceRow)?.Id ?? "";
  public static IEnumerable<(string Id, string Name)> Providers => new[] { ("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini") };
  public static ContentDialog Dialog(XamlRoot root, string title, UIElement content, string save = "Save")
  {
    var dialog = new ContentDialog { XamlRoot = root, RequestedTheme = root.Content is FrameworkElement owner ? owner.ActualTheme : ElementTheme.Default, Title = title, Content = new ScrollViewer { Content = content, MaxHeight = 580, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled },
      PrimaryButtonText = save, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    dialog.Resources["ContentDialogMaxWidth"] = 720.0; return dialog;
  }
  public static async Task<string?> PickFolderAsync(nint hwnd)
  {
    var picker = new FolderPicker(); picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
    return (await picker.PickSingleFolderAsync())?.Path;
  }
  public static async Task<string?> PickPictureAsync(nint hwnd)
  {
    var picker = new FileOpenPicker(); foreach (var type in new[] { ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".ico" }) picker.FileTypeFilter.Add(type);
    WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd); return (await picker.PickSingleFileAsync())?.Path;
  }
  public static async Task<bool> ConfirmAsync(XamlRoot root, string title, string description, string action)
  {
    var dialog = Dialog(root, title, Words(description), action); return await dialog.ShowAsync() == ContentDialogResult.Primary;
  }
  public sealed record ChoiceRow(string Id, string Name);
}
