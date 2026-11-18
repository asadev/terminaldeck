using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;
using Windows.System;

namespace TerminalDeck.App.Views.Settings;

/// Your Cloud (DESIGN-WINDOWS-CLOUD.md 2; the Mac's Cloud file manager): a full page of the main window, like Explorer.
/// LEFT (215): the places in page order with their counts, "Code" (opens the GitHub page) and, set apart at the bottom,
/// the Bin. RIGHT: a top bar (back, forward, the crumbs, search, then ONLY the actions for what is selected), the list
/// (Name · Changed · On · Size; folders first; one 36 px line per row; no row buttons; the right-click menu holds the
/// same actions) and a closable reading pane (340). Names and dates only: a row's id routes and is never drawn.
/// Every rule of what shows comes from `YourCloudRules` (tested in Core.Tests); this file draws it.
public sealed class YourCloudPage : UserControl
{
  private const double PlacesWidth = 232, PaneWidth = 340, RowHeight = 36, ChangedWidth = 150, OnWidth = 130, SizeWidth = 104;
  private readonly CloudContents? contents;
  private readonly Action openCode;
  private readonly Action openSecret;
  private readonly Action<string> notice;
  private readonly ListView places = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new(8, 8, 8, 0) };
  private readonly ListView bin = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new(8, 0, 8, 8) };
  private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Extended, IsMultiSelectCheckBoxEnabled = false };
  private readonly StackPanel crumbs = new() { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
  private readonly TextBox search = new() { PlaceholderText = "Search", Width = 180, MinHeight = 28, CornerRadius = new(8), BorderThickness = new(0), Padding = new(10, 3, 10, 3), VerticalAlignment = VerticalAlignment.Center };
  private readonly Button back = Icon("", "Back"), forward = Icon("", "Forward");
  private readonly Button open = Text(YourCloudRules.Open), binCloud = Bin(YourCloudRules.BinCloud), binEverywhere = Bin(YourCloudRules.BinEverywhere),
    bringBack = Text(YourCloudRules.BringBack), putInCloud = Text(YourCloudRules.PutInCloudAgain);
  private readonly Grid right = new();
  private readonly Grid listArea = new();
  private readonly Border pane = new() { Width = PaneWidth, Visibility = Visibility.Collapsed, Padding = new(16, 12, 16, 16) };
  private readonly TextBlock empty = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 13, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
  private readonly DeckIcon emptyMark = new() { FontSize = 26, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new(0, -32, 0, 0), Visibility = Visibility.Collapsed };
  private readonly List<(string Place, string[] Folder)> history = [];
  private int at = -1;
  private CloudContentsSnapshot? snapshot;
  private string placeKey = nameof(CloudContentsKind.Memory);
  private string[] folder = [];
  private bool rendering, working, showOn, showSize;
  /// The top bar and the column titles: hidden on the Bin, which draws its own one bar (C-3).
  private Grid bar = null!, heads = null!;
  /// The search words the list was last drawn with: TextBox raises TextChanged later, also for a reset to the same
  /// words, and a redraw then would drop the selection.
  private string drawnSearch = "";

  /// One line of the list: a folder or an item.
  private sealed record Entry(CloudContentsFolderRow? Folder, CloudContentsRow? Item, string? Group = null, IReadOnlyList<CloudContentsRow>? Members = null);

  public YourCloudPage(CloudContents? contents, Action openCode, Action openSecret, Action<string> notice)
  {
    this.contents = contents; this.openCode = openCode; this.openSecret = openSecret; this.notice = notice;
    AutomationProperties.SetAutomationId(this, "cloud.manager");
    var page = new Grid();
    page.ColumnDefinitions.Add(new() { Width = new(PlacesWidth) }); page.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); page.ColumnDefinitions.Add(new() { Width = GridLength.Auto });

    // LEFT: the places; the Bin at the bottom, set apart by space.
    var left = new Grid();
    left.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) }); left.RowDefinitions.Add(new() { Height = GridLength.Auto });
    left.SetResourceReference(Panel.BackgroundProperty, "DeckRailBrush");
    AutomationProperties.SetName(places, "Places"); AutomationProperties.SetName(bin, CloudContentsWords.Bin);
    places.SelectionChanged += (_, _) => { if (!rendering && places.SelectedItem is ListViewItem { Tag: YourCloudPlaceRow row }) Choose(row); };
    bin.SelectionChanged += (_, _) => { if (!rendering && bin.SelectedItem is ListViewItem { Tag: YourCloudPlaceRow row }) Choose(row); };
    left.Children.Add(places); Grid.SetRow(bin, 1); left.Children.Add(bin);
    page.Children.Add(left);

    // RIGHT: the top bar, the column heads, the list.
    right.RowDefinitions.Add(new() { Height = GridLength.Auto }); right.RowDefinitions.Add(new() { Height = GridLength.Auto }); right.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    bar = new Grid { Padding = new(12, 8, 12, 8), ColumnSpacing = 8 };
    bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var arrows = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 }; arrows.Children.Add(back); arrows.Children.Add(forward);
    bar.Children.Add(arrows);
    Grid.SetColumn(crumbs, 1); bar.Children.Add(crumbs);
    search.SetResourceReference(Control.BackgroundProperty, "DeckHoverBrush");
    AutomationProperties.SetAutomationId(search, "cloud.manager.search");
    AutomationProperties.SetName(search, "Search"); Grid.SetColumn(search, 2); bar.Children.Add(search);
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    foreach (var button in new[] { open, binCloud, binEverywhere, bringBack, putInCloud }) actions.Children.Add(button);
    Grid.SetColumn(actions, 3); bar.Children.Add(actions);
    right.Children.Add(bar);
    heads = Columns(Head("Name"), Head("Changed"), Head("On"), Head("Size"));
    heads.Padding = new(24, 0, 24, 2);
    Grid.SetRow(heads, 1); right.Children.Add(heads);
    list.Padding = new(12, 0, 12, 12);
    AutomationProperties.SetName(list, "Items");
    list.SelectionChanged += (_, _) => { if (!rendering) UpdateActions(); };
    list.DoubleTapped += (_, args) => { if (Clicked(args.OriginalSource) is { } entry) { Activate(entry); args.Handled = true; } };
    list.KeyDown += (_, args) => { if (args.Key is VirtualKey.Enter or VirtualKey.Space) { OpenSelection(); args.Handled = true; } else if (args.Key == VirtualKey.Back) { Go(-1); args.Handled = true; } };
    list.RightTapped += (_, args) => RowMenu(args);
    listArea.Children.Add(list); listArea.Children.Add(emptyMark); listArea.Children.Add(empty);
    emptyMark.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    empty.Margin = new(0, 28, 0, 0);
    empty.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    Grid.SetRow(listArea, 2); right.Children.Add(listArea);
    Grid.SetColumn(right, 1); page.Children.Add(right);

    // The reading pane, closable.
    pane.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush");
    Grid.SetColumn(pane, 2); page.Children.Add(pane);
    page.SetResourceReference(Panel.BackgroundProperty, "DeckCanvasBrush");
    Content = page;

    back.Click += (_, _) => Go(-1); forward.Click += (_, _) => Go(1);
    search.TextChanged += (_, _) => { if (search.Text.Trim() != drawnSearch) RenderList(); };
    open.Click += (_, _) => OpenSelection();
    binCloud.Click += async (_, _) => await RunAsync(c => c.RemoveFromCloudAsync(Selected()));
    binEverywhere.Click += async (_, _) => await RunAsync(c => c.RemoveEverywhereAsync(Selected()));
    bringBack.Click += async (_, _) => await RunAsync(c => c.BringBackAsync(Selected()));
    putInCloud.Click += async (_, _) => await RunAsync(c => c.PutInCloudAgainAsync(Selected()));
    Loaded += async (_, _) => await ReadAsync();
    Visit(placeKey, []);
  }

  // ---- the picture proof only (CloudScreensProofWindow, a developer flag): drive the page without a pointer ----

  internal Task ProofReadAsync() => ReadAsync();
  internal void ProofVisit(string place, params string[] path) { ClosePane(); Visit(place, path); }
  internal void ProofSelect(params string[] names)
  {
    rendering = true;
    try
    {
      list.SelectedItems.Clear();
      foreach (var item in list.Items.OfType<ListViewItem>()) if ((item.Tag as Entry)?.Item is { } row && names.Contains(row.Name)) list.SelectedItems.Add(item);
    }
    finally { rendering = false; }
    UpdateActions();
  }
  internal Task ProofOpenAsync(string name) =>
    snapshot?.Rows.FirstOrDefault(r => r.Name == name) is { } row ? ShowAsync(row) : Task.CompletedTask;

  // ---- reading ----

  private async Task ReadAsync()
  {
    if (contents is null) { snapshot = null; Render(); return; }
    try { snapshot = await contents.ReadAsync(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { snapshot = null; }
    if (snapshot is not null && snapshot.Places.Count > 0 && !snapshot.Places.Any(p => p.Kind.ToString() == placeKey) && placeKey != "Bin")
    { placeKey = snapshot.Places[0].Kind.ToString(); folder = []; history.Clear(); at = -1; Visit(placeKey, []); }
    Render();
  }

  private void Render()
  {
    rendering = true;
    try
    {
      places.Items.Clear(); bin.Items.Clear();
      if (snapshot is { } s)
        foreach (var row in YourCloudRules.Places(s))
        {
          var item = new ListViewItem { Tag = row, Content = PlaceRow(row), MinHeight = 32, Padding = new(8, 0, 8, 0) };
          AutomationProperties.SetName(item, row.Title);
          (row.IsBin ? bin : places).Items.Add(item);
          if (row.Key == placeKey) { if (row.IsBin) bin.SelectedItem = item; else places.SelectedItem = item; }
        }
    }
    finally { rendering = false; }
    RenderList();
  }

  private void RenderList()
  {
    rendering = true;
    // A redraw (a reload, a search) keeps what was selected, by id.
    var kept = Selected().Select(r => r.Id).ToHashSet(StringComparer.Ordinal);
    try
    {
      list.Items.Clear(); emptyMark.Visibility = Visibility.Collapsed;
      drawnSearch = search.Text.Trim();
      RenderCrumbs();
      back.IsEnabled = at > 0; forward.IsEnabled = at < history.Count - 1;
      var isBin = placeKey == "Bin";
      list.Visibility = isBin ? Visibility.Collapsed : Visibility.Visible;
      bar.Visibility = heads.Visibility = YourCloudRules.ShowsListBar(placeKey) ? Visibility.Visible : Visibility.Collapsed;
      // The Bin is its own page (the Bin hand's CloudBinPage), drawn in this page's right side.
      foreach (var child in listArea.Children.Where(c => c is not ListView && !ReferenceEquals(c, empty) && !ReferenceEquals(c, emptyMark)).ToArray()) listArea.Children.Remove(child);
      if (isBin)
      {
        empty.Visibility = Visibility.Collapsed;
        if (contents is not null)
        {
          var page = CloudBinPage.Open(contents);
          // The Bin's own bar holds back / forward: they walk this page's history.
          if (page is CloudBinPage binPage) binPage.SetHistory(at > 0, at < history.Count - 1, () => Go(-1), () => Go(1));
          listArea.Children.Add(page);
        }
        return;
      }
      if (snapshot is null || contents is null) { Empty(CloudContentsWords.SignedOut); return; }
      var kind = Enum.Parse<CloudContentsKind>(placeKey);
      var listing = snapshot.List(kind, folder, search.Text.Trim());
      var entries = new List<Entry>();
      entries.AddRange(listing.Folders.Select(f => new Entry(f, null)));
      if (kind == CloudContentsKind.Settings && folder.Length == 0 && listing.Folders.Count == 0)
      {
        // Settings: each setting a row, grouped by its Settings page.
        foreach (var group in listing.Items.GroupBy(i => i.Folder.FirstOrDefault() ?? ""))
        {
          if (group.Key.Length > 0) entries.Add(new(null, null, group.Key));
          entries.AddRange(group.Select(i => new Entry(null, i)));
        }
      }
      else entries.AddRange(listing.Items.Select(i => new Entry(null, i)));
      var missing = entries.Where(e => e.Item is { } item && YourCloudRules.Nameless(item)).Select(e => e.Item!).ToArray();
      if (missing.Length > 1)
      {
        entries.RemoveAll(e => e.Item is { } item && missing.Contains(item));
        entries.Add(new(null, missing.OrderByDescending(i => i.ChangedAt).First() with { Name = YourCloudRules.MissingName(kind, missing.Length), CanOpen = false }, Members: missing));
      }
      showOn = listing.Items.Any(i => i.OnText.Length > 0);
      showSize = listing.Items.Any(i => i.Bytes is not null || i.Kind == CloudContentsKind.Settings && YourCloudRules.Detail(i).Length > 0);
      right.Children.Remove(heads);
      heads = Columns(Head("Name"), Head("Changed"), Head("On"), Head("Size"));
      heads.Padding = new(24, 0, 24, 2); Grid.SetRow(heads, 1); right.Children.Add(heads);
      heads.Visibility = entries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
      foreach (var entry in entries) list.Items.Add(ListRow(entry));
      // Through the list's own selection, not the row's IsSelected: a row not yet laid out drops IsSelected when the
      // list prepares it, so a redraw lost the selection (seen in the r7 pictures).
      foreach (var row in list.Items.OfType<ListViewItem>())
        if (row.Tag is Entry entry && (entry.Members?.Any(i => kept.Contains(i.Id)) == true || entry.Item is { } item && kept.Contains(item.Id))) list.SelectedItems.Add(row);
      if (entries.Count == 0) Empty(CloudContentsWords.NothingYet); else empty.Visibility = Visibility.Collapsed;
    }
    finally { rendering = false; }
    UpdateActions();
  }

  private void Empty(string words) { heads.Visibility = Visibility.Collapsed; emptyMark.Glyph = PlaceGlyph(new YourCloudPlaceRow(placeKey, "", "", Enum.TryParse<CloudContentsKind>(placeKey, out var kind) ? kind : null)); emptyMark.Visibility = Visibility.Visible; empty.Text = words; empty.TextAlignment = TextAlignment.Center; empty.Visibility = Visibility.Visible; UpdateActions(); }

  private void RenderCrumbs()
  {
    crumbs.Children.Clear();
    var title = placeKey == "Bin" ? CloudContentsWords.Bin : snapshot?.Places.FirstOrDefault(p => p.Kind.ToString() == placeKey)?.Title ?? CloudContentsWords.Title(Enum.TryParse<CloudContentsKind>(placeKey, out var k) ? k : CloudContentsKind.Memory);
    var parts = YourCloudRules.Crumbs(title, folder);
    for (var i = 0; i < parts.Count; i++)
    {
      if (i > 0) { var chevron = new DeckIcon { Glyph = "", FontSize = 10, VerticalAlignment = VerticalAlignment.Center }; chevron.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush"); crumbs.Children.Add(chevron); }
      var last = i == parts.Count - 1;
      if (last)
      {
        crumbs.Children.Add(new TextBlock { Text = parts[i], FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        continue;
      }
      var depth = i;
      var link = new HyperlinkButton { Content = parts[i], FontSize = 13, Padding = new(4, 2, 4, 2), VerticalAlignment = VerticalAlignment.Center };
      link.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
      link.Click += (_, _) => Visit(placeKey, folder.Take(depth).ToArray());
      crumbs.Children.Add(link);
    }
  }

  // ---- the top bar's actions ----

  private IReadOnlyList<CloudContentsRow> Selected()
  {
    var selected = new List<CloudContentsRow>();
    foreach (var item in list.SelectedItems.OfType<ListViewItem>())
    {
      if (item.Tag is not Entry entry) continue;
      if (entry.Members is not null) selected.AddRange(entry.Members);
      else if (entry.Item is not null) selected.Add(entry.Item);
    }
    return selected.DistinctBy(i => i.Id).ToArray();
  }

  private CloudContentsPlace? Place() => snapshot?.Places.FirstOrDefault(p => p.Kind.ToString() == placeKey);

  private void UpdateActions()
  {
    var isBin = placeKey == "Bin";
    var actions = YourCloudRules.For(isBin ? null : Place(), Selected());
    // Rows "Not on this PC" / "Only on this PC" show only their one action (Bring back / Put in Cloud again).
    open.Visibility = isBin || actions.BringBack || actions.PutInCloudAgain ? Visibility.Collapsed : Visibility.Visible;
    open.IsEnabled = actions.Open && !working;
    binCloud.Visibility = actions.ShowBins && Place()?.CanBinCloud == true ? Visibility.Visible : Visibility.Collapsed;
    binEverywhere.Visibility = actions.ShowBins && Place()?.CanBinEverywhere == true ? Visibility.Visible : Visibility.Collapsed;
    binCloud.IsEnabled = actions.BinCloud && !working; binEverywhere.IsEnabled = actions.BinEverywhere && !working;
    bringBack.Visibility = actions.BringBack ? Visibility.Visible : Visibility.Collapsed; bringBack.IsEnabled = !working;
    putInCloud.Visibility = actions.PutInCloudAgain ? Visibility.Visible : Visibility.Collapsed; putInCloud.IsEnabled = !working;
  }

  private async Task RunAsync(Func<CloudContents, Task<CloudContentsResult>> action)
  {
    if (contents is null || working || Selected().Count == 0) return;
    working = true; UpdateActions();
    try
    {
      var result = await action(contents);
      if (result.Line is { Length: > 0 } line) notice(line);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { notice("That could not be done. Nothing was changed."); }
    finally { working = false; }
    ClosePane();
    await ReadAsync();
  }

  private void RowMenu(RightTappedRoutedEventArgs args)
  {
    if (Clicked(args.OriginalSource) is not { Item: not null } entry || placeKey == "Bin") return;
    var container = list.Items.OfType<ListViewItem>().FirstOrDefault(i => ReferenceEquals(i.Tag, entry));
    if (container is not null && !container.IsSelected) { list.SelectedItems.Clear(); container.IsSelected = true; }
    var actions = YourCloudRules.For(Place(), Selected());
    var menu = new MenuFlyout();
    void Item(string text, bool on, Action press) { if (!on) return; var item = new MenuFlyoutItem { Text = text }; item.Click += (_, _) => press(); menu.Items.Add(item); }
    Item(YourCloudRules.Open, actions.Open, OpenSelection);
    Item("Remove from Cloud", actions.BinCloud, () => _ = RunAsync(c => c.RemoveFromCloudAsync(Selected())));
    Item("Remove everywhere", actions.BinEverywhere, () => _ = RunAsync(c => c.RemoveEverywhereAsync(Selected())));
    Item(YourCloudRules.BringBack, actions.BringBack, () => _ = RunAsync(c => c.BringBackAsync(Selected())));
    Item(YourCloudRules.PutInCloudAgain, actions.PutInCloudAgain, () => _ = RunAsync(c => c.PutInCloudAgainAsync(Selected())));
    if (menu.Items.Count == 0) return;
    menu.ShowAt(list, args.GetPosition(list)); args.Handled = true;
  }

  // ---- moving around ----

  private void Choose(YourCloudPlaceRow row)
  {
    if (row.IsCode) { openCode(); return; }
    if (!row.IsBin && placeKey == row.Key && folder.Length == 0) return;
    if (row.IsBin) { rendering = true; places.SelectedItem = null; rendering = false; }
    else { rendering = true; bin.SelectedItem = null; rendering = false; }
    Visit(row.Key, []);
  }

  private void Visit(string place, string[] path)
  {
    if (at >= 0 && history[at].Place == place && history[at].Folder.SequenceEqual(path)) { placeKey = place; folder = path; RenderList(); return; }
    if (at < history.Count - 1) history.RemoveRange(at + 1, history.Count - at - 1);
    history.Add((place, path)); at = history.Count - 1;
    placeKey = place; folder = path; search.Text = ""; ClosePane();
    Render();
  }

  private void Go(int step)
  {
    var next = at + step;
    if (next < 0 || next >= history.Count) return;
    at = next; placeKey = history[at].Place; folder = history[at].Folder; ClosePane();
    Render();
  }

  private Entry? Clicked(object? source)
  {
    for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
      if (element is ListViewItem { Tag: Entry entry }) return entry;
    return null;
  }

  /// A double click: a folder opens in place; an item opens in the reading pane.
  private void Activate(Entry entry)
  {
    if (entry.Members is not null)
    {
      var row = list.Items.OfType<ListViewItem>().FirstOrDefault(i => ReferenceEquals(i.Tag, entry));
      if (row is not null) list.SelectedItem = row;
      UpdateActions();
    }
    else if (entry.Folder is { } f) Visit(placeKey, [.. f.Path]);
    else if (entry.Item is { CanOpen: true } item) _ = ShowAsync(item);
  }

  private void OpenSelection()
  {
    var selected = list.SelectedItems.OfType<ListViewItem>().Select(i => i.Tag as Entry).OfType<Entry>().ToArray();
    if (selected.Length == 1) Activate(selected[0]);
  }

  // ---- the reading pane ----

  private async Task ShowAsync(CloudContentsRow row)
  {
    if (contents is null) return;
    CloudOpenedItem? item;
    try { item = await contents.OpenAsync(row); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { item = null; }
    if (item is null) { notice("This item could not be opened."); return; }
    var body = new StackPanel { Spacing = 10 };
    var head = new Grid { ColumnSpacing = 8 };
    head.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); head.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    head.Children.Add(new TextBlock { Text = item.Name, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
    var close = Icon("", "Close"); close.Click += (_, _) => ClosePane(); Grid.SetColumn(close, 1); head.Children.Add(close);
    body.Children.Add(head);
    body.Children.Add(Secondary("Changed " + YourCloudRules.Changed(item.ChangedAt)));
    if (item.WhereLine is { Length: > 0 } where) body.Children.Add(Secondary(where));
    if (item.IsSecret || row.IsSecret)
    {
      // A saved password or secret file: its name and date, never its value; one Open.
      var openSecretButton = new Button { Content = YourCloudRules.Open };
      openSecretButton.Click += (_, _) => openSecret();
      body.Children.Add(openSecretButton);
    }
    else if (item.Bytes is { Length: > 0 } bytes && item.MediaType is { } type && type.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
    {
      var picture = new BitmapImage();
      using (var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream())
      {
        await stream.WriteAsync(bytes.AsBuffer()); stream.Seek(0);
        await picture.SetSourceAsync(stream);
      }
      body.Children.Add(new Image { Source = picture, Stretch = Stretch.Uniform, MaxHeight = 520, HorizontalAlignment = HorizontalAlignment.Left });
    }
    else if (item.Bytes is { Length: > 0 } pdf && item.MediaType is "application/pdf")
    {
      var file = Path.Combine(Path.GetTempPath(), "deck-cloud-preview", Guid.NewGuid().ToString("N") + ".pdf");
      Directory.CreateDirectory(Path.GetDirectoryName(file)!);
      await File.WriteAllBytesAsync(file, pdf);
      var web = new WebView2 { Height = 520, Source = new Uri(file) };
      body.Children.Add(web);
    }
    else if (item.Text is { Length: > 0 } text)
      body.Children.Add(FormattedText(text, item.Name));
    pane.Child = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    pane.Visibility = Visibility.Visible;
  }

  /// A note as formatted text (C-1), drawn natively from the chat's own markdown reading (ChatMarkdown): headings,
  /// lists, quotes, bold, italic, links, code in a monospace face. Nothing to wait for, so no "loading" words.
  internal static RichTextBlock FormattedText(string text, string? title = null)
  {
    var first = true;
    var view = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 13, LineHeight = 20 };
    var mono = new FontFamily("Cascadia Mono, Consolas");
    foreach (var block in TerminalDeck.Core.Chats.ChatMarkdown.Blocks(text))
    {
      // The pane's header already names the note: a first heading that says the same is not drawn again.
      var skip = first && block.Kind == "heading" && YourCloudRules.RepeatsTitle(block.Text, title);
      first = false;
      if (skip) continue;
      var paragraph = new Microsoft.UI.Xaml.Documents.Paragraph { Margin = new(0, 0, 0, 8) };
      switch (block.Kind)
      {
        case "heading":
          paragraph.FontSize = block.Level <= 1 ? 18 : block.Level == 2 ? 16 : 14; paragraph.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
          paragraph.Margin = new(0, 4, 0, 6); Spans(paragraph, block.Text); break;
        case "list":
          paragraph.TextIndent = -14; paragraph.Margin = new(14, 0, 0, 4);
          paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = (block.Language is { Length: > 0 } marker && char.IsDigit(marker[0]) ? marker : "•") + "  " });
          Spans(paragraph, block.Text); break;
        case "code":
          paragraph.FontFamily = mono; paragraph.FontSize = 12;
          paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = block.Text }); break;
        case "quote":
          paragraph.Margin = new(12, 0, 0, 8); paragraph.FontStyle = Windows.UI.Text.FontStyle.Italic; Spans(paragraph, block.Text); break;
        default:
          Spans(paragraph, block.Text); break;
      }
      view.Blocks.Add(paragraph);
    }
    return view;

    void Spans(Microsoft.UI.Xaml.Documents.Paragraph paragraph, string line)
    {
      foreach (var span in TerminalDeck.Core.Chats.ChatMarkdown.Spans(line))
        switch (span.Kind)
        {
          case "strong": paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Bold { Inlines = { new Microsoft.UI.Xaml.Documents.Run { Text = span.Text } } }); break;
          case "emphasis": paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Italic { Inlines = { new Microsoft.UI.Xaml.Documents.Run { Text = span.Text } } }); break;
          case "code": paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = span.Text, FontFamily = mono }); break;
          case "link" when span.Target is { } target && TerminalDeck.Core.Chats.ChatMarkdown.CanOpenLink(target):
            var link = new Microsoft.UI.Xaml.Documents.Hyperlink { NavigateUri = new Uri(target) };
            link.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = span.Text }); paragraph.Inlines.Add(link); break;
          default: paragraph.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = span.Text }); break;
        }
    }
  }

  private void ClosePane() { pane.Visibility = Visibility.Collapsed; pane.Child = null; }

  // ---- drawing ----

  private Grid Columns(FrameworkElement name, FrameworkElement changed, FrameworkElement on, FrameworkElement size)
  {
    var row = new Grid { ColumnSpacing = 12 };
    row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star), MaxWidth = 520 }); row.ColumnDefinitions.Add(new() { Width = new(ChangedWidth) });
    row.Children.Add(name);
    Grid.SetColumn(changed, 1); row.Children.Add(changed);
    if (showOn) { row.ColumnDefinitions.Add(new() { Width = new(OnWidth) }); Grid.SetColumn(on, row.ColumnDefinitions.Count - 1); row.Children.Add(on); }
    if (showSize) { row.ColumnDefinitions.Add(new() { Width = new(SizeWidth) }); size.HorizontalAlignment = HorizontalAlignment.Right; Grid.SetColumn(size, row.ColumnDefinitions.Count - 1); row.Children.Add(size); }
    return row;
  }

  private static TextBlock Head(string text) { var head = Secondary(text); head.FontSize = 11; return head; }

  private static TextBlock Secondary(string text)
  {
    var block = new TextBlock { Text = text, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
    block.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    return block;
  }

  private ListViewItem ListRow(Entry entry)
  {
    if (entry.Group is { } group)
    {
      // A Settings page's name over its settings (not selectable).
      var title = new TextBlock { Text = group, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new(0, 10, 0, 2) };
      return new ListViewItem { Tag = entry, Content = title, IsEnabled = false, MinHeight = 28, Padding = new(12, 0, 12, 0) };
    }
    var name = new Grid { ColumnSpacing = 8, VerticalAlignment = VerticalAlignment.Center };
    name.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); name.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); name.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    void Name(FrameworkElement title) { Grid.SetColumn(title, 1); name.Children.Add(title); }
    void Detail(string text) { var detail = Secondary(text); detail.MaxWidth = 120; Grid.SetColumn(detail, 2); name.Children.Add(detail); }
    var glyph = new DeckIcon { Glyph = entry.Folder is not null ? "folder" : "", FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    glyph.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    name.Children.Add(glyph);
    FrameworkElement changed, on, size;
    if (entry.Folder is { } f)
    {
      Name(new TextBlock { Text = f.Name, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
      Detail(CloudContentsWords.Items(f.Items));
      changed = new Border(); on = new Border(); size = new Border();
    }
    else
    {
      var item = entry.Item!;
      Name(new TextBlock { Text = item.Name, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
      var detail = YourCloudRules.Detail(item);
      // A task's state follows its name; a setting's value sits at the right.
      if (detail.Length > 0 && item.Kind != CloudContentsKind.Settings && entry.Members is null) Detail(detail);
      changed = Secondary(YourCloudRules.Changed(item.ChangedAt));
      on = Secondary(item.OnText);
      size = Secondary(item.Kind == CloudContentsKind.Settings ? detail : YourCloudRules.Size(item.Bytes));
    }
    var row = Columns(name, changed, on, size);
    row.Height = RowHeight;
    var container = new ListViewItem { Tag = entry, Content = row, MinHeight = RowHeight, Height = RowHeight, Padding = new(12, 0, 12, 0), HorizontalContentAlignment = HorizontalAlignment.Stretch };
    AutomationProperties.SetAutomationId(container, entry.Members is null ? "cloud.manager.item" : "cloud.manager.missingGroup");
    AutomationProperties.SetName(container, entry.Folder?.Name ?? entry.Item!.Name);
    return container;
  }

  private static FrameworkElement PlaceRow(YourCloudPlaceRow row)
  {
    var line = new Grid { ColumnSpacing = 10 };
    line.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); line.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); line.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var icon = new DeckIcon { Glyph = PlaceGlyph(row), FontSize = 15, VerticalAlignment = VerticalAlignment.Center };
    line.Children.Add(icon);
    var title = new TextBlock { Text = row.Title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    Grid.SetColumn(title, 1); line.Children.Add(title);
    if (row.Count.Length > 0) { var count = Secondary(row.Count); count.FontSize = 12; Grid.SetColumn(count, 2); line.Children.Add(count); }
    return line;
  }

  private static string PlaceGlyph(YourCloudPlaceRow row) => row.IsBin ? "" : row.IsCode ? "" : row.Kind switch
  {
    CloudContentsKind.Memory => "", CloudContentsKind.Projects => "folder", CloudContentsKind.Agents => "",
    CloudContentsKind.InstructionFiles => "", CloudContentsKind.Tasks => "", CloudContentsKind.Settings => "",
    CloudContentsKind.Artifacts => "rich-document", CloudContentsKind.CloudFolder => "", CloudContentsKind.Sessions => "",
    _ => ""
  };

  private static Button Icon(string glyph, string name)
  {
    var button = new Button { Content = new DeckIcon { Glyph = glyph, FontSize = 12 }, Width = 32, Height = 28, MinWidth = 32, MinHeight = 28, Padding = new(0) };
    button.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
    AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name);
    return button;
  }

  private static Button Text(string text)
  {
    var button = new Button { Content = text, MinHeight = 28, Padding = new(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
    AutomationProperties.SetName(button, text);
    return button;
  }

  // The two small bin buttons: a bin glyph and one word ("Cloud", "Everywhere").
  private static Button Bin(string word)
  {
    var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
    line.Children.Add(new DeckIcon { Glyph = "", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
    line.Children.Add(new TextBlock { Text = word, VerticalAlignment = VerticalAlignment.Center });
    var button = new Button { Content = line, MinHeight = 28, Padding = new(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
    AutomationProperties.SetName(button, word == YourCloudRules.BinCloud ? "Remove from Cloud" : "Remove everywhere");
    return button;
  }
}
