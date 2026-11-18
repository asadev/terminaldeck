using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

// A shared, solid surface for app menus. Native flyouts keep keyboard walking,
// focus restoration, outside-click dismissal and screen-edge placement.
public static class DeckMenu
{
  private static Style SurfaceStyle(string target, double padding) => (Style)XamlReader.Load("""
    <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="TARGET">
      <Setter Property="Background" Value="{ThemeResource DeckCardBrush}"/>
      <Setter Property="Foreground" Value="{ThemeResource DeckInkBrush}"/>
      <Setter Property="BorderBrush" Value="{ThemeResource DeckTabRimBrush}"/>
      <Setter Property="BorderThickness" Value="0.5"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="PADDING"/>
      <Setter Property="MinWidth" Value="208"/>
      <Setter Property="MaxWidth" Value="380"/>
    </Style>
    """.Replace("TARGET", target).Replace("PADDING", padding.ToString(System.Globalization.CultureInfo.InvariantCulture)));

  public static MenuFlyout Create()
  {
    var menu = new MenuFlyout(); Apply(menu); return menu;
  }
  public static MenuFlyout CreateFor(FrameworkElement owner)
  {
    var menu = Create(); Projects.ProjectAgentUi.MatchFlyoutTheme(owner, menu); return menu;
  }
  public static void Apply(MenuFlyout menu)
  {
    menu.MenuFlyoutPresenterStyle = SurfaceStyle("MenuFlyoutPresenter", 5);
    menu.Opening += (_, _) => CompactRows(menu.Items);
  }
  private static void CompactRows(IEnumerable<MenuFlyoutItemBase> rows)
  {
    foreach (var row in rows)
    {
      if (row is MenuFlyoutSeparator) continue;
      row.MinHeight = 30; row.Padding = new(9, 0, 9, 0); row.FontSize = 13; row.CornerRadius = new(7);
      if (row is MenuFlyoutSubItem sub) CompactRows(sub.Items);
    }
  }
  public static void Apply(Flyout flyout, ElementTheme theme = ElementTheme.Default)
  {
    var style = SurfaceStyle("FlyoutPresenter", 14);
    style.Setters.Add(new Setter(FrameworkElement.RequestedThemeProperty, theme));
    flyout.FlyoutPresenterStyle = style;
  }
  public static Flyout Create(UIElement content)
  {
    var flyout = new Flyout { Content = content }; Apply(flyout); return flyout;
  }
  public static void Pill(Button button)
  {
    button.Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"];
    button.Width = double.NaN; button.MinWidth = 0; button.Height = button.MinHeight = 22;
    button.Padding = new(8, 0, 8, 0); button.FontSize = 11; button.CornerRadius = new(11);
    button.SetResourceReference(Control.BackgroundProperty, "DeckControlBrush");
  }
  public static string AccountName(string? name, string? email = null)
  {
    var value = string.IsNullOrWhiteSpace(name) ? email?.Trim() ?? "" : name.Trim();
    var at = value.IndexOf('@');
    return at > 0 ? value[..at] : value;
  }
}
