using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

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
  private readonly Border tabSurface = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(3), HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
  private readonly Grid page = new();
  // Top bar (Mac, 15 Nov): back and forward walk everything opened in this window; the page's name is the heading.
  private readonly TextBlock pageTitle = new() { FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
  private readonly Button back = NavigationButton("", "Back");
  private readonly Button forward = NavigationButton("", "Forward");
  private readonly List<string> visited = [];
  private int visitedAt = -1;
  private PersonPicture? railPicture;
  private TextBlock? railName;
  private string selectedSection = "coding-ais";
  private bool selecting;
  private bool selectingLegacy;
  private readonly Notices.CompactNotice saveStatus = new();
  public string SelectedCategory { get; private set; } = "coding-ais";
  internal Grid DragArea { get; private set; } = null!;
  public event Action? CloseRequested;
  public event Action<string>? NavigationChanged;
  public Func<string, bool>? OpenMainPage { get; set; }
  // The Browser's settings: their own small window, opened from the Browser (Mac, 15 Nov).
  public Func<bool>? OpenBrowserSettings { get; set; }

  public SettingsPanel(SettingsPane pane, Func<ElementTheme> theme, Action<ElementTheme> setTheme, string initialSection = "coding-ais")
  {
    legacy = pane;
    legacy.OpenPairedDevices = () => OpenMainPage?.Invoke("Devices") == true;
    legacy.SettingsContentRendered += () => { if (page.Children.Contains(legacy)) PresentHostedPage(); };
    legacy.DirectionRefreshRequested += async id => { if (SelectedCategory == id) await ShowAsync(selectedSection, false); };
    legacy.CloudAccount.Changed += _ => DispatcherQueue.TryEnqueueHandled(UpdateProfileRow);
    // A row that opens a second page ("Which account agents use", "MCP servers", "Custom terminal CLIs") goes
    // through this window's history, so the bar names it and Back returns.
    legacy.NavigateSettings = SelectAsync;
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
    var body = new Grid(); body.ColumnDefinitions.Add(new() { Width = new GridLength(RailWidth) }); body.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); SetRow(body, 1); Children.Add(body);
    var rail = new Grid(); SetResourceReference(rail, BackgroundProperty, "DeckTransparentBrush"); rail.RowDefinitions.Add(new() { Height = GridLength.Auto }); rail.RowDefinitions.Add(new() { Height = GridLength.Auto }); rail.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    rail.Children.Add(DragArea);
    AutomationProperties.SetName(search, "Search Settings"); search.TextChanged += (_, _) => FilterCategories(); SetRow(search, 1); rail.Children.Add(search);
    search.Padding = new Thickness(32, 6, 10, 6); search.MinHeight = 28; search.BorderThickness = new Thickness(0);
    SetResourceReference(search, Control.BackgroundProperty, "DeckControlBrush");
    var magnifier = new DeckIcon { Glyph = "", FontSize = 12, Margin = new Thickness(22, 12, 0, 8), HorizontalAlignment = HorizontalAlignment.Left, IsHitTestVisible = false };
    SetRow(magnifier, 1); rail.Children.Add(magnifier);
    categories.Margin = new Thickness(8, 0, 8, 8); SetRow(categories, 2); rail.Children.Add(categories); body.Children.Add(rail);
    categories.SelectionChanged += async (_, _) => { if (!selecting && categories.SelectedItem is ListViewItem { Tag: string id }) await SelectAsync(id); };
    // The window's own material shows through, so a group's card reads as a card (Windows Settings' look).
    SetResourceReference(detail, BackgroundProperty, "DeckTransparentBrush");
    InstallSelectionResources();
    detail.CornerRadius = new CornerRadius(0); detail.Margin = new Thickness(0);
    detail.RowDefinitions.Add(new() { Height = GridLength.Auto }); detail.RowDefinitions.Add(new() { Height = GridLength.Auto });
    detail.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    // The top bar: [‹ ›] Page name. No footer and no heading inside the page (Mac, 15 Nov).
    var capsule = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
    capsule.Children.Add(back); capsule.Children.Add(forward);
    var capsuleSurface = new Border { Child = capsule, CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
    SetResourceReference(capsuleSurface, Border.BackgroundProperty, "DeckControlBrush");
    back.Click += async (_, _) => await WalkAsync(-1); forward.Click += async (_, _) => await WalkAsync(1);
    var topBar = new Grid { Height = 52, ColumnSpacing = 12, Padding = new Thickness(16, 0, 150, 0) };
    topBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); topBar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    topBar.Children.Add(capsuleSurface); SetColumn(pageTitle, 1); topBar.Children.Add(pageTitle);
    detail.Children.Add(topBar); UpdateHistoryButtons();
    tabSurface.Child = tabs; SetResourceReference(tabSurface, Border.BackgroundProperty, "DeckControlBrush");
    SetRow(tabSurface, 1); detail.Children.Add(tabSurface); SetRow(page, 2); detail.Children.Add(page); SetColumn(detail, 1); body.Children.Add(detail);
    // Keep a long previous page from giving the next ScrollViewer an oversized
    // desired width. Every category measures against this actual content cell.
    SizeChanged += (_, _) => page.Width = Math.Max(0, ActualWidth - RailWidth);
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
    Loaded += async (_, _) => { await ShowAsync(selectedSection, visitedAt < 0); };
  }

  public void FocusSearch() => search.Focus(FocusState.Keyboard);
  public string SearchQuery => search.Text;
  public void Search(string query) => search.Text = query;

  public Task SelectAsync(string section) => ShowAsync(section, true);

  private async Task WalkAsync(int step)
  {
    var next = visitedAt + step;
    if (next < 0 || next >= visited.Count) return;
    visitedAt = next;
    await ShowAsync(visited[visitedAt], false);
  }

  private void UpdateHistoryButtons()
  {
    back.IsEnabled = visitedAt > 0;
    forward.IsEnabled = visitedAt >= 0 && visitedAt < visited.Count - 1;
  }

  private async Task ShowAsync(string section, bool remember)
  {
    if (SettingsNavigation.IsHoot(section))
    {
      if (OpenMainPage?.Invoke("Hoot") == true) return;
      throw new InvalidOperationException("Open Hoot from its page to change its settings.");
    }
    if (SettingsNavigation.IsBrowser(section))
    {
      if (OpenBrowserSettings?.Invoke() == true) return;
      throw new InvalidOperationException("Open the Browser's settings from the Browser.");
    }
    if (section is "mcp" && OpenMainPage?.Invoke("Mcp") == true) return;
    SelectedCategory = SettingsNavigation.Canonical(section);
    selectedSection = section;
    if (remember && (visitedAt < 0 || visited[visitedAt] != section))
    {
      visited.RemoveRange(visitedAt + 1, visited.Count - visitedAt - 1);
      visited.Add(section); visitedAt = visited.Count - 1;
    }
    UpdateHistoryButtons();
    pageTitle.Text = SettingsNavigation.Title(section is "accounts" or "mcp-servers" ? section : SelectedCategory);
    NavigationChanged?.Invoke(section);
    selecting = true;
    var owner = SettingsNavigation.ListOwner(SelectedCategory);
    categories.SelectedItem = categories.Items.OfType<ListViewItem>().FirstOrDefault(item => item.Tag as string == owner);
    selecting = false;
    tabs.Children.Clear(); tabSurface.Visibility = Visibility.Collapsed; tabSurface.Margin = new Thickness(0); page.Children.Clear();
    if (legacy.DirectionPage(SelectedCategory, id => _ = SelectAsync(id)) is { } directionPage)
    {
      if (directionPage.Tag is string named) pageTitle.Text = named;
      page.Children.Add(directionPage); return;
    }
    if (SelectedCategory == "appearance") { page.Children.Add(AppearancePage()); return; }
    if (SelectedCategory == "about") { page.Children.Add(AboutPage()); return; }
    // No switch at the top of a page: the second half is a page of its own, opened from a row.
    var index = SelectedCategory switch { "coding-ais" => section == "accounts" ? 1 : 0, "advanced" => 2, _ => section is "mcp" or "mcp-servers" ? 3 : 4 };
    tabSurface.Visibility = tabs.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    tabSurface.Margin = new Thickness(0, 0, 0, 12);
    page.Children.Add(legacy); selectingLegacy = true;
    try { legacy.SelectSection(index); } finally { selectingLegacy = false; }
    await legacy.RenderAsync();
    PresentHostedPage();
  }

  // Present the retained account/connection controls in the Mac's compact card layout.
  // Their labels, values, click handlers and ownership stay with SettingsPane.
  private void PresentHostedPage()
  {
    if (legacy.Children.OfType<ScrollViewer>().FirstOrDefault()?.Content is not Grid container ||
        container.Children.OfType<StackPanel>().FirstOrDefault() is not { } stack) return;
    stack.MaxWidth = ColumnWidth; stack.Spacing = 20; stack.HorizontalAlignment = HorizontalAlignment.Stretch; stack.Margin = new Thickness(20, 8, 20, 20);
    // The top bar is the heading: the page's own big title goes.
    if (stack.Children.FirstOrDefault() is TextBlock heading) heading.Visibility = Visibility.Collapsed;
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
    selecting = true; categories.Items.Clear(); railPicture = null; railName = null;
    var group = -1;
    foreach (var item in SettingsNavigation.Matching(search.Text))
    {
      // Groups are told apart by space alone, never by a line (Mac, 15 Nov).
      if (group >= 0 && group != item.Group)
        categories.Items.Add(new ListViewItem { Content = new Border { Height = 2 }, IsEnabled = false, IsTabStop = false, MinHeight = 14, Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch });
      var profile = item.Id == "profile";
      FrameworkElement row;
      TextBlock title;
      TextBlock? second = null;
      if (profile)
      {
        // [picture] Name / "Terminal Deck account".
        var picture = new PersonPicture { Width = 32, Height = 32, VerticalAlignment = VerticalAlignment.Center };
        var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        title = new TextBlock { FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        // Never cut (15 Nov): the second line wraps rather than trims.
        second = new TextBlock { Text = TerminalDeck.Core.Brand.Name + " account", FontSize = 11, TextWrapping = TextWrapping.Wrap };
        words.Children.Add(title); words.Children.Add(second);
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(picture); SetColumn(words, 1); grid.Children.Add(words);
        railPicture = picture; railName = title; row = grid;
      }
      else
      {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var icon = new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(5), Child = new DeckIcon { Glyph = item.Glyph, FontSize = 11, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) } };
        SetResourceReference(icon, Border.BackgroundProperty, item.ColorResource); line.Children.Add(icon);
        title = new TextBlock { Text = item.Title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center }; line.Children.Add(title);
        row = line;
      }
      var surface = new Border { Child = row, Padding = new Thickness(8, profile ? 8 : 4, 8, profile ? 8 : 4), CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Stretch };
      var entry = new ListViewItem { Content = surface, Tag = item.Id, MinHeight = profile ? 56 : 32, Margin = new Thickness(0), Padding = new Thickness(0), CornerRadius = new CornerRadius(8), HorizontalContentAlignment = HorizontalAlignment.Stretch };
      void SelectionInk()
      {
        SetResourceReference(surface, Border.BackgroundProperty, entry.IsSelected ? "DeckSidebarSelectionBrush" : "DeckTransparentBrush");
        title.ClearValue(TextBlock.ForegroundProperty);
        SetResourceReference(title, TextBlock.ForegroundProperty, entry.IsSelected ? "DeckSidebarSelectionInkBrush" : "DeckInkBrush");
        if (second is not null)
        {
          second.ClearValue(TextBlock.ForegroundProperty);
          SetResourceReference(second, TextBlock.ForegroundProperty, entry.IsSelected ? "DeckSidebarSelectionInkBrush" : "DeckSecondaryInkBrush");
        }
      }
      entry.RegisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, (_, _) => SelectionInk());
      entry.Loaded += (_, _) => SelectionInk(); SelectionInk();
      AutomationProperties.SetName(entry, item.Title); categories.Items.Add(entry); group = item.Group;
    }
    if (categories.Items.Count == 0) categories.Items.Add(new ListViewItem { Content = new TextBlock { Text = "No matching settings", TextWrapping = TextWrapping.Wrap, Opacity = 0.7 }, IsEnabled = false });
    var owner = SettingsNavigation.ListOwner(SelectedCategory);
    categories.SelectedItem = categories.Items.OfType<ListViewItem>().FirstOrDefault(item => item.Tag as string == owner);
    selecting = false;
    UpdateProfileRow();
  }

  // The profile row says who is signed in; signed out it says "Sign in".
  private void UpdateProfileRow()
  {
    if (railPicture is null || railName is null) return;
    var snapshot = legacy.CloudAccount.Snapshot;
    var signedIn = snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused or CloudPhase.NotAllowed;
    var name = signedIn ? CloudProfile.FromSnapshot(snapshot).Name : "Sign in";
    railName.Text = name;
    railPicture.DisplayName = signedIn ? name : "";
    railPicture.Initials = signedIn ? CloudProfile.Initials(name) : "";
  }

  // Appearance (Mac, 15 Nov): one group, three picture tiles; the chosen one is ringed in the accent colour.
  // The terminal font and colours left this page; their saved values keep working.
  private FrameworkElement AppearancePage()
  {
    var tiles = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(12, 16, 12, 16) };
    var options = new[] { ("Match Windows", ElementTheme.Default), ("Light", ElementTheme.Light), ("Dark", ElementTheme.Dark) };
    var rings = new List<Border>();
    void RefreshChoice()
    {
      for (var i = 0; i < rings.Count; i++)
      {
        var chosen = readTheme() == options[i].Item2;
        rings[i].BorderThickness = new Thickness(chosen ? 2 : 1);
        rings[i].BorderBrush = (Brush)ShellTheme.Resource(rings[i], chosen ? "AccentFillColorDefaultBrush" : "DeckDividerBrush");
      }
    }
    foreach (var (label, theme) in options)
    {
      var ring = new Border { Width = 150, Height = 96, CornerRadius = new CornerRadius(8), Padding = new Thickness(2), Child = ThemePicture(theme) };
      var words = new TextBlock { Text = label, FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center };
      var stack = new StackPanel { Spacing = 8, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
      stack.Children.Add(ring); stack.Children.Add(words);
      var tile = new ContentControl { Content = stack, IsTabStop = true, UseSystemFocusVisuals = true };
      AutomationProperties.SetName(tile, label + " appearance");
      void Choose()
      {
        try { saveStatus.Text = "Saving…"; changeTheme(theme); saveStatus.IsOpen = false; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        { saveStatus.Text = "The appearance could not be saved. Please try again."; }
        RefreshChoice();
      }
      tile.Tapped += (_, _) => Choose();
      tile.KeyDown += (_, args) => { if (args.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { Choose(); args.Handled = true; } };
      rings.Add(ring); tiles.Children.Add(tile);
    }
    tiles.Loaded += (_, _) => RefreshChoice();
    tiles.ActualThemeChanged += (_, _) => RefreshChoice();
    return Page(GroupRows([tiles]));
  }

  // A small drawing of the app's window in that look: a rail and a page with three lines.
  private static FrameworkElement ThemePicture(ElementTheme theme)
  {
    static SolidColorBrush Grey(byte value) => new(Windows.UI.Color.FromArgb(255, value, value, value));
    static Grid Sketch(bool dark)
    {
      var window = new Grid();
      window.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); window.ColumnDefinitions.Add(new() { Width = new GridLength(3, GridUnitType.Star) });
      window.Children.Add(new Border { Background = Grey(dark ? (byte)0x2B : (byte)0xE9) });
      var content = new StackPanel { Spacing = 5, Padding = new Thickness(8), Background = Grey(dark ? (byte)0x1C : (byte)0xFF) };
      for (var i = 0; i < 3; i++)
        content.Children.Add(new Border { Height = 6, CornerRadius = new CornerRadius(3), HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 0, i == 0 ? 0 : 16, 0), Background = Grey(dark ? (byte)0x45 : (byte)0xD6) });
      Grid.SetColumn(content, 1); window.Children.Add(content);
      return window;
    }
    FrameworkElement picture;
    if (theme == ElementTheme.Default)
    {
      var halves = new Grid();
      halves.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); halves.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
      var light = Sketch(false); var dark = Sketch(true); Grid.SetColumn(dark, 1);
      halves.Children.Add(light); halves.Children.Add(dark); picture = halves;
    }
    else picture = Sketch(theme == ElementTheme.Dark);
    return new Border { CornerRadius = new CornerRadius(6), Child = picture };
  }

  private static FrameworkElement AboutPage() => Page(GroupRows([SettingRow(TerminalDeck.Core.Brand.Name, "",
    // The installed package's version, the same build General and Windows show (never the 1.0.0 assembly stamp).
    StateText(Services.WindowsUpdateStatus.Version()))]));

  // One scroll area fills the right side (its bar at the window's edge); the column is centred.
  internal static FrameworkElement Page(FrameworkElement content)
  {
    var stack = Column();
    stack.Children.Add(content);
    return new ScrollViewer { Content = stack, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
  }

  // ONE column on every page (15 Nov): 560 wide, centred in the right side whatever the page holds.
  internal const double ColumnWidth = 560;
  internal const double RailWidth = 210;
  internal static StackPanel Column() => new() { Spacing = 20, MaxWidth = ColumnWidth, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(20, 8, 20, 20) };

  // Kept for older callers; pages no longer draw a heading of their own (the top bar is the heading).
  internal static FrameworkElement PageHead(string title) => new Border { Height = 0, Visibility = Visibility.Collapsed, Child = new TextBlock { Text = title } };

  // A group's title, 8 above its group; an explanation sits behind ONE info button beside it.
  internal static FrameworkElement GroupTitle(string text, string? help = null)
  {
    var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(12, 0, 0, -12) };
    line.Children.Add(new TextBlock { Text = text, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
    if (!string.IsNullOrWhiteSpace(help)) line.Children.Add(InfoButton(text, help));
    return line;
  }

  // The info button: a click (never hover) opens the explanation.
  internal static Button InfoButton(string title, string help)
  {
    var info = new Button { Content = new DeckIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(2), MinWidth = 20, MinHeight = 20, CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
    info.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
    ToolTipService.SetToolTip(info, "About " + title); AutomationProperties.SetName(info, "About " + title);
    info.Flyout = new Flyout { Content = new TextBlock { Text = help, MaxWidth = 300, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } };
    return info;
  }

  // ONE short state word at a row's right ("Signed in", "Up to date", "Not allowed").
  internal static TextBlock StateText(string text, string brush = "DeckSecondaryInkBrush")
  {
    var state = new TextBlock { Text = text, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    state.SetResourceReference(TextBlock.ForegroundProperty, brush);
    return state;
  }

  // A small coloured tile with a white glyph, at the start of a row.
  internal static FrameworkElement IconTile(string glyph, string brush, double size = 26)
  {
    var tile = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(6), VerticalAlignment = VerticalAlignment.Center, Child = new DeckIcon { Glyph = glyph, FontSize = 14, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) } };
    tile.SetResourceReference(Border.BackgroundProperty, brush);
    return tile;
  }

  // A row that opens a page: the whole row is the click target and ends with a chevron.
  internal static FrameworkElement LinkRow(string title, string? detail, FrameworkElement? leading, string? state, Action open)
  {
    var row = new Grid { ColumnSpacing = 12, MinHeight = 44, Padding = new Thickness(12, 8, 12, 8), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    if (leading is not null) row.Children.Add(leading);
    var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
    words.Children.Add(new TextBlock { Text = title, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
    if (!string.IsNullOrWhiteSpace(detail)) words.Children.Add(StateText(detail));
    if (words.Children.Count > 1) ((TextBlock)words.Children[1]).FontSize = 11;
    SetColumn(words, 1); row.Children.Add(words);
    if (!string.IsNullOrWhiteSpace(state)) { var value = StateText(state); SetColumn(value, 2); row.Children.Add(value); }
    var chevron = new DeckIcon { Glyph = "", FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    chevron.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    SetColumn(chevron, 3); row.Children.Add(chevron);
    var link = new ContentControl { Content = row, IsTabStop = true, UseSystemFocusVisuals = true, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch };
    AutomationProperties.SetName(link, title);
    link.Tapped += (_, _) => open();
    link.KeyDown += (_, args) => { if (args.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { open(); args.Handled = true; } };
    return link;
  }

  // Title, its info button (the help is shown ONCE, behind the button: no sentence under the title), and ONE control.
  internal static FrameworkElement SettingRow(string title, string help, FrameworkElement? control)
  {
    var row = new Grid { ColumnSpacing = 16 }; row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var words = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center }; var label = new Grid { ColumnSpacing = 4, HorizontalAlignment = HorizontalAlignment.Left };
    label.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    label.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
    if (!string.IsNullOrWhiteSpace(help)) { var info = InfoButton(title, help); SetColumn(info, 1); label.Children.Add(info); }
    words.Children.Add(label);
    row.Children.Add(words);
    if (control is not null) { control.HorizontalAlignment = HorizontalAlignment.Right; control.VerticalAlignment = VerticalAlignment.Center; AutomationProperties.SetName(control, title); SetColumn(control, 1); row.Children.Add(control); }
    if (control is not null)
    {
      row.RowDefinitions.Add(new() { Height = GridLength.Auto }); row.RowDefinitions.Add(new() { Height = GridLength.Auto });
      row.SizeChanged += (_, _) =>
      {
        // ONE line (15 Nov): title at the left, the control at the right; only a very narrow window stacks them.
        var compact = row.ActualWidth < 320;
        SetRow(control, compact ? 1 : 0); SetColumn(control, compact ? 0 : 1); SetColumnSpan(control, compact ? 2 : 1);
        control.HorizontalAlignment = compact ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        control.Margin = new Thickness(0, compact ? 8 : 0, 0, 0);
        control.MaxWidth = Math.Max(0, compact ? row.ActualWidth : Math.Min(280, row.ActualWidth * .48));
      };
    }
    var card = new Border { Padding = new Thickness(12, 6, 12, 6), CornerRadius = new CornerRadius(8), Child = row, BorderThickness = new Thickness(0), MinHeight = 44 };
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
      if (card is Border border) { border.CornerRadius = new CornerRadius(0); border.Padding = new Thickness(12, 6, 12, 6); border.BorderThickness = new Thickness(0); border.MinHeight = 44; }
      rows.Children.Add(card);
    }
    // A group is a card: radius 8, the quiet card fill, no border.
    var group = new Border { CornerRadius = new CornerRadius(8), Child = rows };
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

  private static Button NavigationButton(string glyph, string name)
  {
    var button = new Button { Content = new DeckIcon { Glyph = glyph, FontSize = 12 }, Width = 32, Height = 28, MinWidth = 32, MinHeight = 28, Padding = new Thickness(0) };
    button.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
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
