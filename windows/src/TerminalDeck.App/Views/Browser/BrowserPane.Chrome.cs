using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Browser;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  public Action? OpenStore { get; set; }
  public Action<string>? ToggleSplitView { get; set; }
  public Func<string, bool> SplitViewIsOn { get; set; } = _ => false;
  private static IconElement? BrowserMenuGlyph(string label)
  {
    var name = label switch
    {
      "New tab" or "New Tab" => "plus", "New isolated tab" or "Isolated tab" => "lock",
      "Annotate page" or "Stop annotating" => "cursor", "Screenshot" => "camera", "Draw on a screenshot" => "pencil",
      "Record steps" or "Stop recording" => "record", "Page size" => "phone", "Developer tools" => "code",
      "Find in page" => "search", "Print…" => "print", "Copy address" => "clipboard", "Open in your browser" => "new-window",
      "Bookmarks" => "star", "Home" => "home", "Browser settings…" => "settings", "Store" => "store",
      "History" => "clock", "Passwords" => "lock", _ => ""
    };
    if (label == "Print…") return new FontIcon { Glyph = "\uE749", FontFamily = DeckFonts.Icons, FontSize = 16 };
    if (DeckIconCatalog.Find(name) is not { } definition) return null;
    return (PathIcon)XamlReader.Load($"<PathIcon xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{definition.Path}\" />");
  }
  private static UIElement BookmarkGlyph(bool saved)
  {
    if (!saved) return new DeckIcon { Glyph = "\uE734", FontSize = 14 };
    var definition = DeckIconCatalog.Find("star")!;
    var path = (Microsoft.UI.Xaml.Shapes.Path)XamlReader.Load($"<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{definition.Path}\" />");
    path.SetResourceReference(Microsoft.UI.Xaml.Shapes.Shape.FillProperty, "AccentFillColorDefaultBrush");
    return new Viewbox { Width = 14, Height = 14, Child = new Canvas { Width = 16, Height = 16, Children = { path } } };
  }
  private Flyout ProfileCard(BrowserTab tab)
  {
    var content = new StackPanel { Width = 252, Spacing = 8 };
    var popup = new Flyout { Content = content }; DeckMenu.Apply(popup, tab.View.ActualTheme);
    popup.Opening += (_, _) =>
    {
      DeckMenu.Apply(popup, tab.View.ActualTheme); content.RequestedTheme = tab.View.ActualTheme;
      content.Children.Clear();
      content.Children.Add(ProfileAvatar(tab.Profile, 44, tab.Isolated));
      content.Children.Add(new TextBlock { Text = tab.Profile.Name, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
      if (tab.Isolated) content.Children.Add(new TextBlock { Text = "Isolated tab: nothing is kept", FontSize = 11, Opacity = .65, HorizontalAlignment = HorizontalAlignment.Center });
      content.Children.Add(new TextBlock { Text = "Other profiles", FontSize = 11, Opacity = .65, Margin = new(0, 8, 0, 0) });
      foreach (var profile in profiles.Where(p => p.Id != tab.Profile.Id))
      {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        label.Children.Add(ProfileAvatar(profile, 22)); label.Children.Add(new TextBlock { Text = profile.Name, VerticalAlignment = VerticalAlignment.Center });
        var row = TextAction(profile.Name, async () => { popup.Hide(); await GuardAsync(async () => { await Core.ActivateProfileAsync(profile.Id); await SwitchStoreAsync(tab, profile.Id, tab.Isolated); }, tab); });
        row.Content = label; row.HorizontalAlignment = row.HorizontalContentAlignment = HorizontalAlignment.Stretch; row.MinHeight = 30; content.Children.Add(row);
      }
      content.Children.Add(TextAction("New profile…", async () => { popup.Hide(); await GuardAsync(() => NewProfileAsync(tab), tab); }));
      if (!tab.Isolated)
      {
        content.Children.Add(TextAction("Passwords", async () => { popup.Hide(); await GuardAsync(() => ShowPasswordsAsync(tab), tab); }));
        content.Children.Add(TextAction("History", async () => { popup.Hide(); await GuardAsync(() => ShowHistoryAsync(tab), tab); }));
      }
    };
    return popup;
  }
  private static Border ProfileAvatar(BrowserProfile profile, double size, bool isolated = false)
  {
    // Profile identities use the existing meaningful data colours in both themes.
    var colors = new[] { "DeckProjectBlueBrush", "DeckProjectGreenBrush", "DeckProjectOrangeBrush", "DeckProjectPurpleBrush", "DeckAgentRedBrush", "DeckProjectBlueBrush" };
    var hash = profile.Id.Aggregate(0u, (value, c) => unchecked(value * 31 + c));
    var avatar = new Border { Width = size, Height = size, CornerRadius = new(size / 2), HorizontalAlignment = HorizontalAlignment.Center };
    avatar.SetResourceReference(Border.BackgroundProperty, colors[(int)(hash % (uint)colors.Length)]);
    var letter = new TextBlock { Text = System.Globalization.StringInfo.GetNextTextElement(profile.Name).ToUpperInvariant(), FontSize = size * .44, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    letter.SetResourceReference(TextBlock.ForegroundProperty, "TextOnAccentFillColorPrimaryBrush");
    var content = new Grid(); content.Children.Add(letter);
    if (isolated)
    {
      var locked = new DeckIcon { Glyph = "\uE72E", FontSize = size * .34, Width = size * .4, Height = size * .4, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom }; locked.SetResourceReference(Control.ForegroundProperty, "TextOnAccentFillColorPrimaryBrush"); content.Children.Add(locked);
    }
    avatar.Child = content; return avatar;
  }
  private async Task NewProfileAsync(BrowserTab tab)
  {
    var name = new TextBox { PlaceholderText = "Profile name", MaxLength = 40 };
    var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "New browser profile", Content = name, PrimaryButtonText = "Create", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = false };
    name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text);
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    var profile = await Core.CreateProfileAsync(name.Text); await Core.ActivateProfileAsync(profile.Id); await SwitchStoreAsync(tab, profile.Id, tab.Isolated);
  }
  private MenuFlyout MoreMenu(BrowserTab tab)
  {
    var menu = DeckMenu.CreateFor(tab.View);
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear();
      void Add(string text, Func<Task> action, bool enabled = true) => menu.Items.Add(MenuAction(text, tab, action, enabled));
      void Command(string text, string command) => Add(text, () => RunForAsync(tab, command));
      Add("New tab", () => OpenAfterAsync(tab, false)); Add("New isolated tab", () => OpenAfterAsync(tab, true));
      menu.Items.Add(new MenuFlyoutSeparator());
      Command(tab.Inspecting ? "Stop annotating" : "Annotate page", "inspect"); Command("Screenshot", "shot"); Command("Draw on a screenshot", "draw"); Command(tab.Recording ? "Stop recording" : "Record steps", "record");
      var sizes = new MenuFlyoutSubItem { Text = tab.Viewport.Width == 0 ? "Page size" : "Page size · " + tab.Viewport.Name, Icon = BrowserMenuGlyph("Page size") };
      foreach (var size in BrowserViewport.Presets)
      {
        var item = new ToggleMenuFlyoutItem { Text = size.Width == 0 ? size.Name : $"{size.Name} · {size.Width} × {size.Height}", IsChecked = size.Width == tab.Viewport.Width && size.Height == tab.Viewport.Height };
        item.Click += async (_, _) => await GuardAsync(async () => { tab.Viewport = size; await ApplyViewportAsync(tab); }, tab); sizes.Items.Add(item);
      }
      var landscape = new ToggleMenuFlyoutItem { Text = "Landscape", IsChecked = tab.Viewport.Width > tab.Viewport.Height, IsEnabled = tab.Viewport.Width != 0 };
      landscape.Click += async (_, _) => await GuardAsync(async () => { tab.Viewport = tab.Viewport.Landscape(); await ApplyViewportAsync(tab); }, tab); sizes.Items.Add(landscape);
      var phone = new ToggleMenuFlyoutItem { Text = "Phone user agent", IsChecked = tab.PhoneAgent };
      phone.Click += async (_, _) => await GuardAsync(async () => { tab.PhoneAgent = phone.IsChecked; await ApplyViewportAsync(tab); }, tab); sizes.Items.Add(phone);
      sizes.Items.Add(MenuAction("Custom size…", tab, () => { tab.SizeEditing = true; RefreshShellViews(); return Task.CompletedTask; })); menu.Items.Add(sizes);
      Command("Developer tools", "devtools");
      menu.Items.Add(new MenuFlyoutSeparator());
      var zoom = new MenuFlyoutSubItem { Text = $"Zoom · {tab.Zoom:P0}", Icon = BrowserMenuGlyph("Find in page") };
      zoom.Items.Add(MenuAction("Zoom out", tab, () => SetZoomAsync(tab, tab.Zoom / 1.1))); zoom.Items.Add(MenuAction("Actual size · 100%", tab, () => SetZoomAsync(tab, 1))); zoom.Items.Add(MenuAction("Zoom in", tab, () => SetZoomAsync(tab, tab.Zoom * 1.1))); menu.Items.Add(zoom);
      Add("Find in page", () => { tab.FindShown = true; RefreshShellViews(); return Task.CompletedTask; });
      Add("Print…", () => { tab.View.CoreWebView2.ShowPrintUI(Microsoft.Web.WebView2.Core.CoreWebView2PrintDialogKind.Browser); return Task.CompletedTask; });
      Add("Copy address", () => { CopyText(tab.Address); return Task.CompletedTask; }, tab.Address.Length > 0);
      Add("Open in your browser", async () => { await Launcher.LaunchUriAsync(new Uri(tab.Address)); }, tab.Address.Length > 0);
      menu.Items.Add(new MenuFlyoutSeparator());
      var bookmarks = new MenuFlyoutSubItem { Text = "Bookmarks", Icon = BrowserMenuGlyph("Bookmarks") };
      var always = new ToggleMenuFlyoutItem { Text = "Always show the bookmarks bar", IsChecked = Core.ShowsBookmarkBar(tab.Profile.Id) };
      always.Click += async (_, _) => await GuardAsync(async () => { await Core.ShowBookmarkBarAsync(tab.Profile.Id, always.IsChecked); RefreshShellViews(); }, tab); bookmarks.Items.Add(always);
      foreach (var bookmark in Core.Bookmarks(tab.Profile.Id)) bookmarks.Items.Add(MenuAction(bookmark.Title, tab, () => RunForAsync(tab, "navigate", bookmark.Url)));
      menu.Items.Add(bookmarks);
      var isolated = new ToggleMenuFlyoutItem { Text = "Isolated tab", IsChecked = tab.Isolated };
      isolated.Click += async (_, _) => await GuardAsync(() => SwitchStoreAsync(tab, tab.Profile.Id, !tab.Isolated), tab); menu.Items.Add(isolated);
      var toggleSplit = ToggleSplitView;
      if (toggleSplit is not null)
      {
        var split = new ToggleMenuFlyoutItem { Text = "Split view", IsChecked = SplitViewIsOn(tab.Id) }; split.Click += async (_, _) => await GuardAsync(() => { toggleSplit(tab.Id); return Task.CompletedTask; }, tab); menu.Items.Add(split);
      }
      if (tab.Steps.Count > 0 || tab.Recording) Add("Recorded flow", () => { tab.StepsShown = true; RefreshShellViews(); return Task.CompletedTask; }); Command("Send page to a session", "send");
      menu.Items.Add(new MenuFlyoutSeparator()); Command("Home", "home");
      Add("Set as start page", async () => { await Core.SetStartUrlAsync(tab.Address); SetTabStatus(tab, "Start page saved."); }, tab.Address.Length > 0);
      if (OpenStore is { } openStore) Add("Store", () => { openStore(); return Task.CompletedTask; }); Add("Browser settings…", OpenProfileSettingsAsync);
      DeckMenu.CompactRows(menu.Items);
    };
    return menu;
  }
  private async Task ShowPasswordsAsync(BrowserTab tab)
  {
    var rows = new StackPanel { Spacing = 12, MinWidth = 360 };
    var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Passwords · " + tab.Profile.Name, Content = new ScrollViewer { Content = rows, MaxHeight = 420 }, CloseButtonText = "Done" };
    void Render()
    {
      rows.Children.Clear(); var passwords = Privacy.Logins(tab.Profile.Id);
      if (passwords.Count == 0) rows.Children.Add(new TextBlock { Text = "No saved passwords in this profile." });
      foreach (var password in passwords)
      {
        var row = new StackPanel { Spacing = 4 }; row.Children.Add(new TextBlock { Text = password.Origin, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); row.Children.Add(new TextBlock { Text = password.Username, FontSize = 12, Opacity = .7 });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(TextAction("Copy password", async () => await GuardAsync(() => CopyBrowserPasswordAsync(tab.Profile.Id, password.Id), tab)));
        actions.Children.Add(TextAction("Fill this page", async () => await GuardAsync(async () => { selected = tab; await FillBrowserPasswordAsync(tab.Profile.Id, password.Id); SetTabStatus(tab, "Password filled. Nothing was submitted."); }, tab)));
        actions.Children.Add(TextAction("Forget", async () => await GuardAsync(async () => { await Privacy.ForgetAsync(tab.Profile.Id, password.Id); Render(); }, tab))); row.Children.Add(actions); rows.Children.Add(row);
      }
    }
    Render(); await dialog.ShowAsync();
  }
  private async Task ToggleBookmarkAsync(BrowserTab tab)
  {
    var existing = Core.Bookmarks(tab.Profile.Id).FirstOrDefault(b => b.Url == tab.Address);
    if (existing is null) { await Core.AddBookmarkAsync(tab.Profile.Id, tab.Address, tab.Title, tab.View.CoreWebView2.FaviconUri); SetTabStatus(tab, "Bookmark saved."); }
    else { await Core.RemoveBookmarkAsync(tab.Profile.Id, existing.Id); SetTabStatus(tab, "Bookmark removed."); }
    RefreshShellViews();
  }
  private FrameworkElement BookmarkBar(BrowserTab tab, out Action refresh)
  {
    var bar = new Grid { Height = 30, ColumnSpacing = 4 };
    bar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var items = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 }; bar.Children.Add(items);
    var overflow = WorkspaceSurface.IconButton("More bookmarks", "\uE76C", () => { }); Grid.SetColumn(overflow, 1); bar.Children.Add(overflow);
    string? last = null;
    void Render()
    {
      var bookmarks = Core.Bookmarks(tab.Profile.Id); bar.Visibility = bookmarks.Length > 0 && (tab.Address.Length == 0 || Core.ShowsBookmarkBar(tab.Profile.Id)) ? Visibility.Visible : Visibility.Collapsed;
      var fingerprint = bar.ActualWidth + "|" + string.Join("|", bookmarks.Select(b => b.Id));
      if (last == fingerprint) return; last = fingerprint;
      items.Children.Clear(); var menu = DeckMenu.CreateFor(tab.View); var available = Math.Max(0, bar.ActualWidth - 32); var used = 0d;
      foreach (var bookmark in bookmarks)
      {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (bookmark.Icon is { } icon) label.Children.Add(new Image { Source = new BitmapImage(new Uri(icon)), Width = 14, Height = 14 });
        else label.Children.Add(new DeckIcon { Glyph = "\uE774", FontSize = 12 });
        label.Children.Add(new TextBlock { Text = bookmark.Title, FontSize = 12, MaxWidth = 130, TextTrimming = TextTrimming.CharacterEllipsis });
        var button = TextAction(bookmark.Title, async () =>
        {
          var modifiers = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
          if (modifiers) await GuardAsync(async () => { var made = await Core.OpenAsync(bookmark.Url, profileId: tab.Profile.Id, select: false); ObserveShellPages(); ShellChanged?.Invoke(); }, tab);
          else await RunForAsync(tab, "navigate", bookmark.Url);
        });
        button.PointerPressed += async (_, args) =>
        {
          if (!args.GetCurrentPoint(button).Properties.IsMiddleButtonPressed) return; args.Handled = true;
          await GuardAsync(async () => { await Core.OpenAsync(bookmark.Url, profileId: tab.Profile.Id, select: false); ObserveShellPages(); ShellChanged?.Invoke(); }, tab);
        };
        button.Content = label; button.CornerRadius = new(6); button.Measure(new(double.PositiveInfinity, 30)); var width = button.DesiredSize.Width;
        var context = DeckMenu.CreateFor(tab.View);
        context.Items.Add(MenuAction("Open in new tab", tab, async () => { var made = await Core.OpenAsync(bookmark.Url, profileId: tab.Profile.Id); ObserveShellPages(); ShellSelected?.Invoke(made.Id); }));
        context.Items.Add(MenuAction("Copy address", tab, () => { CopyText(bookmark.Url); return Task.CompletedTask; }));
        context.Items.Add(MenuAction("Remove", tab, async () => { await Core.RemoveBookmarkAsync(tab.Profile.Id, bookmark.Id); RefreshShellViews(); })); button.ContextFlyout = context;
        if (used + width <= available) { items.Children.Add(button); used += width + 4; }
        else menu.Items.Add(MenuAction(bookmark.Title, tab, () => RunForAsync(tab, "navigate", bookmark.Url)));
      }
      overflow.Flyout = menu; overflow.Visibility = menu.Items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
    bar.SizeChanged += (_, _) => Render(); refresh = Render; return bar;
  }
}
