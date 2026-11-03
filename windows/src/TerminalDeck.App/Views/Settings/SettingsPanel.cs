using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace TerminalDeck.App.Views.Settings;

/// Shared Settings content hosted only by the owned Settings window.
/// Account and connection actions continue to belong to the existing Settings pane.
public sealed partial class SettingsPanel : Grid
{
  private readonly SettingsPane legacy;
  private readonly Func<ElementTheme> readTheme;
  private readonly Action<ElementTheme> changeTheme;
  private readonly ListView categories = new() { SelectionMode = ListViewSelectionMode.Single, HorizontalContentAlignment = HorizontalAlignment.Stretch };
  private readonly TextBox search = new() { PlaceholderText = "Search", CornerRadius = new CornerRadius(16), Margin = new Thickness(12, 12, 12, 8) };
  private readonly Grid detail = new() { Padding = new Thickness(0) };
  private readonly StackPanel tabs = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
  private readonly Border tabSurface = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(3), HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
  private readonly Grid page = new();
  private string selectedSection = "coding-ais";
  private bool selecting;
  private bool selectingLegacy;
  private readonly Notices.CompactNotice saveStatus = new();
  public string SelectedCategory { get; private set; } = "coding-ais";
  internal Grid DragArea { get; private set; } = null!;
  public event Action? CloseRequested;
  public event Action<string>? NavigationChanged;
  public Func<string, bool>? OpenMainPage { get; set; }

  public SettingsPanel(SettingsPane pane, Func<ElementTheme> theme, Action<ElementTheme> setTheme, string initialSection = "coding-ais")
  {
    legacy = pane;
    legacy.SettingsContentRendered += () => { if (page.Children.Contains(legacy)) PresentHostedPage(); };
    legacy.DirectionRefreshRequested += async id => { if (SelectedCategory == id) await SelectAsync(id); };
    readTheme = theme; changeTheme = setTheme;
    selectedSection = initialSection; SelectedCategory = SettingsNavigation.Canonical(initialSection);
    AutomationProperties.SetAutomationId(this, "settings.panel");

    TabFocusNavigation = KeyboardNavigationMode.Cycle;
    Resources["ListViewItemMinHeight"] = 32d;
    SetResourceReference(this, BackgroundProperty, "DeckTransparentBrush");
    RowDefinitions.Add(new() { Height = GridLength.Auto });
    RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    // Only the rail header is draggable; the content stays white up to its top edge.
    DragArea = new Grid { Height = 40, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    DragArea.Children.Add(new TextBlock { Text = "Settings", FontSize = 13, Margin = new Thickness(16, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
    var body = new Grid(); body.ColumnDefinitions.Add(new() { Width = new GridLength(194) }); body.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); SetRow(body, 1); Children.Add(body);
    var rail = new Grid(); SetResourceReference(rail, BackgroundProperty, "DeckTransparentBrush"); rail.RowDefinitions.Add(new() { Height = GridLength.Auto }); rail.RowDefinitions.Add(new() { Height = GridLength.Auto }); rail.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    rail.Children.Add(DragArea);
    AutomationProperties.SetName(search, "Search Settings"); search.TextChanged += (_, _) => FilterCategories(); SetRow(search, 1); rail.Children.Add(search);
    search.Padding = new Thickness(32, 6, 10, 6); search.MinHeight = 28; search.BorderThickness = new Thickness(0);
    SetResourceReference(search, Control.BackgroundProperty, "DeckControlBrush");
    var magnifier = new DeckIcon { Glyph = "\uE721", FontSize = 12, Margin = new Thickness(22, 12, 0, 8), HorizontalAlignment = HorizontalAlignment.Left, IsHitTestVisible = false };
    SetRow(magnifier, 1); rail.Children.Add(magnifier);
    categories.Margin = new Thickness(8, 0, 8, 8); SetRow(categories, 2); rail.Children.Add(categories); body.Children.Add(rail);
    categories.SelectionChanged += async (_, _) => { if (!selecting && categories.SelectedItem is ListViewItem { Tag: string id }) await SelectAsync(id); };
    SetResourceReference(detail, BackgroundProperty, "DeckCanvasBrush");
    InstallSelectionResources();
    detail.CornerRadius = new CornerRadius(0); detail.Margin = new Thickness(0);
    detail.RowDefinitions.Add(new() { Height = GridLength.Auto }); detail.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    detail.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var foot = new Grid { Padding = new Thickness(20, 10, 20, 10), ColumnSpacing = 12 };
    foot.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); foot.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    SetResourceReference(foot, BackgroundProperty, "DeckRailBrush");
    var saving = new TextBlock { Text = "Changes save as you make them.", FontSize = 13, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    SetResourceReference(saving, TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); foot.Children.Add(saving);
    var shortcutLabel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
    shortcutLabel.Children.Add(new DeckIcon { Glyph = "\uE765", FontSize = 13 }); shortcutLabel.Children.Add(new TextBlock { Text = "Shortcuts", FontSize = 13 });
    var shortcuts = new Button { Content = shortcutLabel, FontSize = 13, MinHeight = 28, Padding = new Thickness(6, 2, 6, 2) };
    AutomationProperties.SetName(shortcuts, "Keyboard shortcuts");
    shortcuts.Click += async (_, _) => { try { await ShowShortcutsAsync(); } catch (Exception ex) when (ex is not OutOfMemoryException) { saveStatus.Text = ex.Message; } };
    SetColumn(shortcuts, 1); foot.Children.Add(shortcuts); SetRow(foot, 2); detail.Children.Add(foot);
    tabSurface.Child = tabs; SetResourceReference(tabSurface, Border.BackgroundProperty, "DeckControlBrush");
    detail.Children.Add(tabSurface); SetRow(page, 1); detail.Children.Add(page); SetColumn(detail, 1); body.Children.Add(detail);
    // Keep a long previous page from giving the next ScrollViewer an oversized
    // desired width. Every category measures against this actual content cell.
    SizeChanged += (_, _) => page.Width = Math.Max(0, ActualWidth - 194);
    saveStatus.Scope = this; Children.Add(saveStatus);
    // Collapse only the old navigation. Its content and all account/AI actions remain intact.
    legacy.Children[0].Visibility = Visibility.Collapsed;
    if (legacy.Children[0] is ListView navigation) navigation.SelectionChanged += async (_, _) =>
    {
      if (!selectingLegacy) await SelectAsync(navigation.SelectedIndex switch { 1 => "accounts", 2 => "devices", 3 => "mcp", 4 => "outside-ai-apps", _ => "coding-ais" });
    };
    legacy.ColumnDefinitions[0].Width = new GridLength(0); legacy.ColumnSpacing = 0;
    if (legacy.Children.OfType<ScrollViewer>().FirstOrDefault() is { } scroll) scroll.Padding = new Thickness(0, 4, 4, 16);
    var find = new KeyboardAccelerator { Key = Windows.System.VirtualKey.F, Modifiers = Windows.System.VirtualKeyModifiers.Control };
    find.Invoked += (_, args) => { search.Focus(FocusState.Keyboard); args.Handled = true; }; KeyboardAccelerators.Add(find);
    KeyDown += (_, args) => { if (args.Key == Windows.System.VirtualKey.Escape) { CloseRequested?.Invoke(); args.Handled = true; } };
    FilterCategories();
    Loaded += async (_, _) => { await SelectAsync(selectedSection); };
  }

  public void FocusSearch() => search.Focus(FocusState.Keyboard);
  public string SearchQuery => search.Text;
  public void Search(string query) => search.Text = query;

  public async Task SelectAsync(string section)
  {
    if (SettingsNavigation.IsHoot(section))
    {
      if (OpenMainPage?.Invoke("Hoot") == true) return;
      throw new InvalidOperationException("Open Hoot from its page to change its settings.");
    }
    if ((section is "devices" or "mcp") && OpenMainPage?.Invoke(section == "devices" ? "Devices" : "Mcp") == true) return;
    SelectedCategory = SettingsNavigation.Canonical(section);
    selectedSection = section;
    NavigationChanged?.Invoke(section);
    selecting = true;
    categories.SelectedItem = categories.Items.OfType<ListViewItem>().FirstOrDefault(item => item.Tag as string == SelectedCategory);
    selecting = false;
    tabs.Children.Clear(); tabSurface.Visibility = Visibility.Collapsed; tabSurface.Margin = new Thickness(0); page.Children.Clear();
    if (legacy.DirectionPage(SelectedCategory, id => _ = SelectAsync(id)) is { } directionPage) { page.Children.Add(directionPage); return; }
    if (SelectedCategory == "appearance") { page.Children.Add(AppearancePage()); return; }
    if (SelectedCategory == "about") { page.Children.Add(AboutPage()); return; }
    var index = SelectedCategory switch { "coding-ais" => section == "accounts" ? 1 : 0, "advanced" => 2, _ => section == "mcp" ? 3 : 4 };
    if (SelectedCategory == "coding-ais")
    {
      AddTab("Coding AIs", 0, index); AddTab("Who uses what", 1, index);
    }

    if (SelectedCategory == "outside-ai-apps")
    {
      AddTab("Outside AI apps", 4, index); AddTab("MCP servers", 3, index);
    }
    tabSurface.Visibility = tabs.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    tabSurface.Margin = new Thickness(0, 0, 0, 16);
    page.Children.Add(legacy); selectingLegacy = true;
    try { legacy.SelectSection(index); } finally { selectingLegacy = false; }
    await legacy.RenderAsync();
    PresentHostedPage();
  }

  private void AddTab(string title, int index, int selected)
  {
    var button = new ToggleButton { Content = title, IsChecked = index == selected, Padding = new Thickness(12, 5, 12, 5), MinHeight = 30 };
    foreach (var key in new[] { "ToggleButtonBackgroundChecked", "ToggleButtonBackgroundCheckedPointerOver", "ToggleButtonBackgroundCheckedPressed" }) button.Resources[key] = TerminalDeck.App.Shell.ShellTheme.Resource(this, "DeckSidebarSelectionBrush");
    foreach (var key in new[] { "ToggleButtonForegroundChecked", "ToggleButtonForegroundCheckedPointerOver", "ToggleButtonForegroundCheckedPressed" }) button.Resources[key] = TerminalDeck.App.Shell.ShellTheme.Resource(this, "DeckSidebarSelectionInkBrush");
    AutomationProperties.SetName(button, title);
    button.Click += async (_, _) =>
    {
      if (index == 3 && OpenMainPage?.Invoke("Mcp") == true) return;
      await SelectAsync(index switch { 1 => "accounts", 3 => "mcp", 4 => "outside-ai-apps", _ => "coding-ais" });
    };
    tabs.Children.Add(button);
  }

  // Present the retained account/connection controls in the Mac's compact card layout.
  // Their labels, values, click handlers and ownership stay with SettingsPane.
  private void PresentHostedPage()
  {
    if (legacy.Children.OfType<ScrollViewer>().FirstOrDefault()?.Content is not Grid container ||
        container.Children.OfType<StackPanel>().FirstOrDefault() is not { } stack) return;
    stack.MaxWidth = 640; stack.Spacing = 12; stack.HorizontalAlignment = HorizontalAlignment.Center; stack.Margin = new Thickness(20, 0, 20, 20);
    if (stack.Children.FirstOrDefault() is TextBlock heading)
    { if (SelectedCategory == "advanced") heading.Text = "Advanced"; heading.FontSize = 20; heading.MinHeight = 0; heading.Margin = new Thickness(0, 14, 0, 14); }
    foreach (var card in stack.Children.OfType<Border>())
    {
      SetResourceReference(card, Border.BackgroundProperty, "DeckCardBrush");
      card.Padding = new Thickness(12, 10, 12, 10); card.CornerRadius = new CornerRadius(10); card.BorderThickness = new Thickness(0);
      if (card.Child is not Grid row) continue;
      row.ColumnSpacing = 16;
      if (row.Children.OfType<StackPanel>().FirstOrDefault() is not { } words) continue;
      words.Spacing = 4;
      foreach (var text in words.Children.OfType<TextBlock>()) text.FontSize = 12;
      if (words.Children.FirstOrDefault() is TextBlock label)
      { label.FontSize = 13; label.FontWeight = Microsoft.UI.Text.FontWeights.Normal; }
    }
  }

  private void FilterCategories()
  {
    selecting = true; categories.Items.Clear();
    var group = -1;
    foreach (var item in SettingsNavigation.Matching(search.Text))
    {
      var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
      var icon = new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(5), Child = new DeckIcon { Glyph = item.Glyph, FontSize = 11, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) } };
      SetResourceReference(icon, Border.BackgroundProperty, item.ColorResource); row.Children.Add(icon);
      var title = new TextBlock { Text = item.Title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center }; row.Children.Add(title);
      if (group >= 0 && group != item.Group)
      {
        var rule = new Border { Height = 1, Margin = new Thickness(10, 6, 10, 6) };
        SetResourceReference(rule, Border.BackgroundProperty, "DeckDividerBrush");
        categories.Items.Add(new ListViewItem { Content = rule, IsEnabled = false, IsTabStop = false, MinHeight = 13, Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch });
      }
      var surface = new Border { Child = row, Padding = new Thickness(8, 4, 8, 4), CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Stretch };
      var entry = new ListViewItem { Content = surface, Tag = item.Id, MinHeight = 32, Margin = new Thickness(0), Padding = new Thickness(0), CornerRadius = new CornerRadius(8), HorizontalContentAlignment = HorizontalAlignment.Stretch };
      void SelectionInk()
      {
        SetResourceReference(surface, Border.BackgroundProperty, entry.IsSelected ? "DeckSidebarSelectionBrush" : "DeckTransparentBrush");
        title.ClearValue(TextBlock.ForegroundProperty);
        SetResourceReference(title, TextBlock.ForegroundProperty, entry.IsSelected ? "DeckSidebarSelectionInkBrush" : "DeckInkBrush");
      }
      entry.RegisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, (_, _) => SelectionInk());
      entry.Loaded += (_, _) => SelectionInk(); SelectionInk();
      AutomationProperties.SetName(entry, item.Title); categories.Items.Add(entry); group = item.Group;
    }
    if (categories.Items.Count == 0) categories.Items.Add(new ListViewItem { Content = new TextBlock { Text = "No matching settings", TextWrapping = TextWrapping.Wrap, Opacity = 0.7 }, IsEnabled = false });
    categories.SelectedItem = categories.Items.OfType<ListViewItem>().FirstOrDefault(item => item.Tag as string == SelectedCategory);
    selecting = false;
  }

  private FrameworkElement AppearancePage()
  {
    var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    var options = new[] { ("Light", ElementTheme.Light), ("Dark", ElementTheme.Dark), ("Match Windows", ElementTheme.Default) };
    var buttons = new List<ToggleButton>();
    void RefreshChoice()
    {
      for (var i = 0; i < buttons.Count; i++) buttons[i].IsChecked = readTheme() == options[i].Item2;
    }
    foreach (var (label, theme) in options)
    {
      var button = new ToggleButton { Content = label, Padding = new Thickness(10, 4, 10, 4), MinHeight = 32 };
      AutomationProperties.SetName(button, label + " appearance");
      button.Click += (_, _) =>
      {
        try { saveStatus.Text = "Saving…"; changeTheme(theme); saveStatus.IsOpen = false; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { saveStatus.Text = "The appearance could not be saved. Please try again."; }
        RefreshChoice();
      };
      buttons.Add(button); choices.Children.Add(button);
    }
    RefreshChoice();
    choices.ActualThemeChanged += (_, _) => RefreshChoice();
    var content = new StackPanel { Spacing = 16 }; content.Children.Add(SettingRow("Theme", "Use the system appearance, or choose light or dark.", choices)); content.Children.Add(new TerminalAppearancePage(legacy.TerminalAppearance));
    return Page("Appearance", "Window and terminal", content);
  }

  private static FrameworkElement AboutPage() => Page("About", "App", SettingRow(TerminalDeck.Core.Brand.Name,
    // The installed package's version, the same build General and Windows show (never the 1.0.0 assembly stamp).
    "App build " + Services.WindowsUpdateStatus.Version(), null));

  internal static FrameworkElement Page(string title, string group, FrameworkElement card)
  {
    var stack = new StackPanel { Spacing = 12, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20, 0, 20, 20) };
    stack.Children.Add(PageHead(title));
    stack.Children.Add(new TextBlock { Text = group, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(8, 20, 0, 0) }); stack.Children.Add(card);
    return new ScrollViewer { Content = stack, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
  }

  internal static FrameworkElement PageHead(string title) => new Border { Height = 52, Child = new TextBlock { Text = title, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center } };

  internal static FrameworkElement SettingRow(string title, string help, FrameworkElement? control)
  {
    var row = new Grid { ColumnSpacing = 16 }; row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var words = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center }; var label = new Grid { ColumnSpacing = 4, HorizontalAlignment = HorizontalAlignment.Left };
    label.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    label.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
    if (!string.IsNullOrWhiteSpace(help))
    {
      var info = new Button { Content = new DeckIcon { Glyph = "\uE946", FontSize = 12 }, Padding = new Thickness(2), MinWidth = 20, MinHeight = 20, CornerRadius = new CornerRadius(8) };
      info.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
      ToolTipService.SetToolTip(info, "About " + title); AutomationProperties.SetName(info, "About " + title); info.Flyout = new Flyout { Content = new TextBlock { Text = help, MaxWidth = 300, TextWrapping = TextWrapping.Wrap } }; SetColumn(info, 1); label.Children.Add(info);
    }
    words.Children.Add(label);
    if (!string.IsNullOrWhiteSpace(help)) words.Children.Add(new TextBlock { Text = help, FontSize = 13, Opacity = 0.7, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis });
    row.Children.Add(words);
    if (control is not null) { control.HorizontalAlignment = HorizontalAlignment.Right; control.VerticalAlignment = VerticalAlignment.Center; AutomationProperties.SetName(control, title); SetColumn(control, 1); row.Children.Add(control); }
    if (control is not null)
    {
      row.RowDefinitions.Add(new() { Height = GridLength.Auto }); row.RowDefinitions.Add(new() { Height = GridLength.Auto });
      row.SizeChanged += (_, _) =>
      {
        var compact = row.ActualWidth < 460;
        SetRow(control, compact ? 1 : 0); SetColumn(control, compact ? 0 : 1); SetColumnSpan(control, compact ? 2 : 1);
        control.HorizontalAlignment = compact ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        control.Margin = new Thickness(0, compact ? 8 : 0, 0, 0);
        control.MaxWidth = Math.Max(0, compact ? row.ActualWidth : Math.Min(280, row.ActualWidth * .48));
      };
    }
    var card = new Border { Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(10), Child = row, BorderThickness = new Thickness(0) };
    SetResourceReference(card, Border.BorderBrushProperty, "DeckDividerBrush");
    AutomationProperties.SetAutomationId(card, "settings.row"); SetResourceReference(card, Border.BackgroundProperty, "DeckCardBrush"); return card;
  }

  internal static FrameworkElement GroupRows(IEnumerable<FrameworkElement> cards)
  {
    var rows = new StackPanel();
    foreach (var card in cards)
    {
      if (rows.Children.Count > 0)
      {
        var divider = new Border { Height = 1, Margin = new Thickness(12, 0, 12, 0) };
        SetResourceReference(divider, Border.BackgroundProperty, "DeckDividerBrush"); rows.Children.Add(divider);
      }
      if (card is Border border) { border.CornerRadius = new CornerRadius(0); border.Padding = new Thickness(12, 10, 12, 10); border.BorderThickness = new Thickness(0); }
      rows.Children.Add(card);
    }
    var group = new Border { CornerRadius = new CornerRadius(10), Child = rows };
    SetResourceReference(group, Border.BackgroundProperty, "DeckCardBrush");
    return group;
  }

  public async Task ShowShortcutsAsync()
  {
    // A programmatic reopen can reach this before the retained panel has joined
    // its new window. A dialog must wait for that window's real content root.
    if (XamlRoot is null)
    {
      var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      RoutedEventHandler ready = (_, _) => loaded.TrySetResult(); Loaded += ready;
      try { await loaded.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
      finally { Loaded -= ready; }
    }
    var root = XamlRoot ?? throw new InvalidOperationException("Open Settings before showing its shortcuts.");
    await new ContentDialog
    {
    XamlRoot = root, RequestedTheme = ActualTheme, Title = "Settings shortcuts", CloseButtonText = "Done",
    Content = new TextBlock { Text = "Ctrl+F   Search Settings\nEscape   Close Settings\nTab / Shift+Tab   Move between controls\nArrow keys   Move through categories", TextWrapping = TextWrapping.Wrap }
    }.ShowAsync();
  }

  private static Button IconButton(string glyph, string name)
  {
    var button = new Button { Content = new DeckIcon { Glyph = glyph, FontSize = 14 }, Width = 32, Height = 32, MinHeight = 32, Padding = new Thickness(4) };
    AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name); return button;
  }

  // Programmatically constructed controls still use the app's live theme resources.
  internal static void SetResourceReference(FrameworkElement target, DependencyProperty property, string key)
  {
    var name = property == Control.ForegroundProperty || property == TextBlock.ForegroundProperty ? "Foreground" : "Background";
    target.Style = (Style)Microsoft.UI.Xaml.Markup.XamlReader.Load(
      "<Style xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" TargetType=\"" + (target is Border ? "Border" : target is TextBox ? "TextBox" : target is TextBlock ? "TextBlock" : target is StackPanel ? "StackPanel" : "Grid") + "\">" + (target is TextBlock ? DeckFonts.TextSetter : "") + "<Setter Property=\"" + name + "\" Value=\"{ThemeResource " + key + "}\"/></Style>");
  }

  private void InstallSelectionResources()
  {
    // Scoped aliases preserve WinUI's keyboard/focus template while replacing the grey selection.
    var aliases = (ResourceDictionary)Microsoft.UI.Xaml.Markup.XamlReader.Load("""
      <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
        <StaticResource x:Key="ListViewItemBackgroundSelected" ResourceKey="DeckTransparentBrush"/>
        <StaticResource x:Key="ListViewItemBackgroundSelectedPointerOver" ResourceKey="DeckTransparentBrush"/>
        <StaticResource x:Key="ListViewItemBackgroundSelectedPressed" ResourceKey="DeckTransparentBrush"/>
        <StaticResource x:Key="ListViewItemForegroundSelected" ResourceKey="DeckSidebarSelectionInkBrush"/>
        <StaticResource x:Key="ListViewItemForegroundSelectedPointerOver" ResourceKey="DeckSidebarSelectionInkBrush"/>
        <StaticResource x:Key="ListViewItemForegroundSelectedPressed" ResourceKey="DeckSidebarSelectionInkBrush"/>
      </ResourceDictionary>
      """);
    categories.Resources.MergedDictionaries.Add(aliases);
  }
}
