using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;

namespace TerminalDeck.App.Views.Receiver;

internal static class ReceiverUi
{
  public static StackPanel Stack(double spacing = 12) => new() { Spacing = spacing, HorizontalAlignment = HorizontalAlignment.Stretch };
  public static TextBlock Words(string text, double size = 13) => new() { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
  public static Border Card(UIElement child) => new() { Child = child, Padding = new Thickness(16), CornerRadius = new CornerRadius(12), Style = (Style)Application.Current.Resources["SurfaceCardStyle"] };
  public static Button Button(string text, Func<Task> action, bool primary = false)
  {
    var button = new Button { Content = text, MinHeight = 28, Padding = new Thickness(12, 4, 12, 4) };
    if (primary) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
    button.Click += async (_, _) => await action(); return button;
  }
  public static TextBox Field(string name, string value = "", bool multi = false, int limit = 16000) => new()
  { Header = name, Text = value, AcceptsReturn = multi, TextWrapping = multi ? TextWrapping.Wrap : TextWrapping.NoWrap, MinHeight = multi ? 100 : 28, MaxLength = limit };
  public static ComboBox Choice(string name, IEnumerable<(string Id, string Label)> rows, string? selected = null)
  {
    var result = new ComboBox { Header = name, HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = nameof(ChoiceItem.Label), SelectedValuePath = nameof(ChoiceItem.Id), MinHeight = 28 };
    foreach (var (id, label) in rows) result.Items.Add(new ChoiceItem(id, label));
    if (selected is not null) result.SelectedValue = selected;
    if (result.SelectedIndex < 0 && result.Items.Count > 0) result.SelectedIndex = 0;
    return result;
  }
  public static string Picked(ComboBox box) => (box.SelectedItem as ChoiceItem)?.Id ?? "";
  public static ContentDialog Dialog(FrameworkElement owner, string title, UIElement content, string action)
  {
    var dialog = new ContentDialog { XamlRoot = owner.XamlRoot, RequestedTheme = owner.ActualTheme, Title = title,
      Content = new ScrollViewer { Content = content, MaxHeight = 540, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled },
      PrimaryButtonText = action, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    dialog.Resources["ContentDialogMaxWidth"] = 640.0; return dialog;
  }
  public static ScrollViewer Scroll(StackPanel body) => new() { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
  public static Style PageStyle() => (Style)XamlReader.Load("""
    <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Grid">
      <Setter Property="Background" Value="{ThemeResource ApplicationPageBackgroundThemeBrush}" />
    </Style>
    """);
  private sealed record ChoiceItem(string Id, string Label);
}
