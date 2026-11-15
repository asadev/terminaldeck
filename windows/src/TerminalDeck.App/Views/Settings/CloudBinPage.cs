using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

/// The Bin (DESIGN-WINDOWS-CLOUD.md section 3), drawn in the Your Cloud page's frame: the top bar holds back / forward,
/// the page name "Bin" with ONE info button (the 30 days live only there), a search field, and at the right the one
/// action "Put back all" for the selected lines. The list: one 36 px line per removal (what, from which device by name,
/// when); single click selects, Ctrl/Shift select more; no button on a row; the right-click menu holds "Put back" and
/// "Delete for good" (asked once). Names and dates only, never an id.
public sealed class CloudBinPage : Grid
{
  private const double RowHeight = 36;
  private readonly CloudBinRules rules;
  private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Extended, IsMultiSelectCheckBoxEnabled = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
  private readonly TextBox search = new() { PlaceholderText = "Search", Width = 220, MinHeight = 28, VerticalAlignment = VerticalAlignment.Center };
  private readonly Button putBackAll = new() { Content = CloudDeleteWords.PutBackAll, IsEnabled = false, VerticalAlignment = VerticalAlignment.Center };
  private readonly Button back = NavButton("\uE72B", "Back"), forward = NavButton("\uE72A", "Forward");
  private readonly TextBlock emptyLine = new() { FontSize = 13, Margin = new Thickness(12, 16, 12, 0), Visibility = Visibility.Collapsed };
  private readonly TextBlock problem = new() { FontSize = 13, Margin = new Thickness(12, 0, 12, 8), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
  private Action? goBack, goForward;

  /// The one call the other screens use: a new Bin page reading `contents`; the caller places the element in the main
  /// window's page area. (Back / forward stay greyed until the caller hands its history over with SetHistory.)
  public static FrameworkElement Open(CloudContents contents) => new CloudBinPage(CloudBinRules.For(contents));

  internal CloudBinPage(CloudBinRules rules)
  {
    this.rules = rules;
    AutomationProperties.SetAutomationId(this, "cloud.bin");
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });

    // Top bar: back / forward, "Bin" + info, then search and the one action at the right.
    var bar = new Grid { ColumnSpacing = 8, Padding = new Thickness(12, 10, 12, 10) };
    bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var nav = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    nav.Children.Add(back); nav.Children.Add(forward);
    back.IsEnabled = forward.IsEnabled = false;
    back.Click += (_, _) => goBack?.Invoke(); forward.Click += (_, _) => goForward?.Invoke();
    var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
    name.Children.Add(new TextBlock { Text = CloudContentsWords.Bin, FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
    name.Children.Add(SettingsPanel.InfoButton(CloudContentsWords.Bin, CloudContentsWords.BinEmptiesAfter));
    var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    left.Children.Add(nav); left.Children.Add(name);
    bar.Children.Add(left);
    AutomationProperties.SetName(search, "Search the Bin");
    search.TextChanged += (_, _) => { rules.Search = search.Text; Draw(); };
    SetColumn(search, 2); bar.Children.Add(search);
    AutomationProperties.SetAutomationId(putBackAll, "cloud.bin.putBackAll");
    putBackAll.Click += async (_, _) => await PutBackAsync();
    SetColumn(putBackAll, 3); bar.Children.Add(putBackAll);
    Children.Add(bar);

    problem.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    SetRow(problem, 1); Children.Add(problem);

    // The list: Windows' own row highlight and selection; rows 36 px; one menu for the selection.
    list.ItemContainerStyle = (Style)Microsoft.UI.Xaml.Markup.XamlReader.Load(
      "<Style xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" TargetType=\"ListViewItem\">" +
      "<Setter Property=\"MinHeight\" Value=\"36\"/><Setter Property=\"Height\" Value=\"36\"/><Setter Property=\"Padding\" Value=\"12,0,12,0\"/>" +
      "<Setter Property=\"HorizontalContentAlignment\" Value=\"Stretch\"/></Style>");
    AutomationProperties.SetName(list, CloudContentsWords.Bin);
    list.SelectionChanged += (_, _) => Actions();
    list.RightTapped += (_, e) =>
    {
      // A right click on a line that is not selected makes it the selection first, as Explorer does.
      if ((e.OriginalSource as FrameworkElement)?.DataContext is CloudBinLine line && !SelectedLines().Any(l => l.Id == line.Id)
        && list.Items.OfType<ListViewItem>().FirstOrDefault(i => i.Tag is CloudBinLine t && t.Id == line.Id) is { } row) { list.SelectedItems.Clear(); row.IsSelected = true; }
      if (Menu() is { } menu) menu.ShowAt(list, e.GetPosition(list));
      e.Handled = true;
    };
    var host = new Grid();
    host.Children.Add(list);
    emptyLine.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    host.Children.Add(emptyLine);
    SetRow(host, 2); Children.Add(host);

    Loaded += async (_, _) => { await rules.RefreshAsync(); Draw(); };
  }

  /// The Your Cloud page's history: whether back / forward can be pressed and what they do.
  public void SetHistory(bool canGoBack, bool canGoForward, Action? onBack, Action? onForward)
  {
    back.IsEnabled = canGoBack && onBack is not null; forward.IsEnabled = canGoForward && onForward is not null;
    goBack = onBack; goForward = onForward;
  }

  private void Draw()
  {
    var keep = SelectedLines().Select(l => l.Id).ToHashSet(StringComparer.Ordinal);
    var shown = rules.Shown();
    list.Items.Clear();
    foreach (var line in shown) list.Items.Add(Row(line));
    // Rows are ListViewItems carrying their line, so the selection survives a redraw by id.
    foreach (var item in list.Items.OfType<ListViewItem>()) if (item.Tag is CloudBinLine l && keep.Contains(l.Id)) item.IsSelected = true;
    emptyLine.Text = rules.EmptyLine() ?? ""; emptyLine.Visibility = rules.EmptyLine() is null ? Visibility.Collapsed : Visibility.Visible;
    problem.Text = rules.Line ?? ""; problem.Visibility = rules.Line is null ? Visibility.Collapsed : Visibility.Visible;
    Actions();
  }

  private void Actions() => putBackAll.IsEnabled = rules.CanPutBackAll(SelectedLines());

  private IReadOnlyList<CloudBinLine> SelectedLines() => list.SelectedItems.Select(i => i is ListViewItem { Tag: CloudBinLine l } ? l : i as CloudBinLine).OfType<CloudBinLine>().ToArray();

  // One line: what it was (takes the room, truncates), where it was removed, and when, both in secondary text.
  private static ListViewItem Row(CloudBinLine line)
  {
    var grid = new Grid { ColumnSpacing = 16, Height = RowHeight, DataContext = line };
    grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new() { Width = new GridLength(150) });
    grid.Children.Add(new TextBlock { Text = line.What, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1, DataContext = line });
    var where = SettingsPanel.StateText(line.Title); where.DataContext = line; SetColumn(where, 1); grid.Children.Add(where);
    var when = SettingsPanel.StateText(CloudBinRules.When(line.At, DateTimeOffset.Now)); when.DataContext = line; SetColumn(when, 2); grid.Children.Add(when);
    var item = new ListViewItem { Content = grid, Tag = line, DataContext = line };
    AutomationProperties.SetName(item, line.What + ", " + line.Title + ", " + CloudBinRules.When(line.At, DateTimeOffset.Now));
    return item;
  }

  private MenuFlyout? Menu()
  {
    var selected = SelectedLines();
    var words = rules.Menu(selected);
    if (words.Count == 0) return null;
    var menu = new MenuFlyout();
    foreach (var word in words)
    {
      var item = new MenuFlyoutItem { Text = word };
      item.Click += async (_, _) => { if (word == CloudBinRules.PutBack) await PutBackAsync(); else await DeleteForGoodAsync(); };
      menu.Items.Add(item);
    }
    return menu;
  }

  private async Task PutBackAsync()
  {
    var selected = SelectedLines();
    if (!rules.CanPutBackAll(selected)) return;
    putBackAll.IsEnabled = false;
    await rules.PutBackAsync(selected);
    Draw();
  }

  private async Task DeleteForGoodAsync()
  {
    var selected = SelectedLines();
    if (selected.Count == 0 || rules.Working) return;
    var (title, text) = CloudBinRules.DeleteForGoodQuestion(selected);
    if (!await TerminalDeck.App.Views.Projects.ProjectAgentUi.ConfirmAsync(XamlRoot, title, text, CloudBinRules.DeleteForGood)) return;
    await rules.DeleteForGoodAsync(selected);
    Draw();
  }

  private static Button NavButton(string glyph, string name)
  {
    var button = new Button { Content = new DeckIcon { Glyph = glyph, FontSize = 12 }, Padding = new Thickness(6), MinWidth = 28, MinHeight = 28, VerticalAlignment = VerticalAlignment.Center };
    button.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
    AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name);
    return button;
  }
}
