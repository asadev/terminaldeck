using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Browser;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private XamlRoot RootFor(BrowserTab tab) => shellViews.TryGetValue(tab.Id, out var panel) ? panel.XamlRoot : XamlRoot;
  private async Task RunForAsync(BrowserTab tab, string command, string? argument = null)
  {
    await GuardAsync(async () => { await Core.TakeHumanControlAsync(tab.Id); await ExecuteTabAsync(tab, command, argument); }, tab);
    RefreshShellViews();
  }
  private static Button TextAction(string label, Action action)
  {
    var button = new Button { Content = label, FontSize = 13, MinHeight = 26, Padding = new Thickness(6, 2, 6, 2) };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
    ToolTipService.SetToolTip(button, label); button.Click += (_, _) => action(); return button;
  }
  private static void CopyText(string text) { var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); }
  private MenuFlyoutItem MenuAction(string label, BrowserTab tab, Func<Task> action, bool enabled = true)
  {
    var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled, FontSize = 13, MinHeight = 28 };
    item.Click += async (_, _) => await GuardAsync(action, tab); return item;
  }
  private void InstallAddress(BrowserTab tab, AutoSuggestBox address)
  {
    address.PlaceholderText = "Enter a URL, or search";
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(address, "Web address");
    address.Text = tab.Address;
    TextBox? editor = null; var deleting = false;
    static TextBox? FindEditor(DependencyObject parent)
    {
      for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
      {
        var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i);
        if (child is TextBox box) return box;
        if (FindEditor(child) is { } nested) return nested;
      }
      return null;
    }
    address.Loaded += (_, _) =>
    {
      editor = FindEditor(address);
      if (editor is not null) editor.KeyDown += (_, args) => { if (args.Key is VirtualKey.Back or VirtualKey.Delete) deleting = true; };
    };
    address.TextChanged += (_, args) =>
    {
      if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
      var visits = tab.Isolated || string.IsNullOrWhiteSpace(address.Text) ? Array.Empty<string>() :
        Core.History(tab.Profile.Id, address.Text).Select(v => v.Url).Distinct().Take(8).ToArray();
      address.ItemsSource = visits;
      var completion = BrowserAddressCompletion.Complete(address.Text, deleting, visits); deleting = false;
      if (completion is null || editor is null) return;
      address.Text = completion.Url;
      editor.Select(completion.SelectionStart, completion.SelectionLength);
    };
    address.SuggestionChosen += (_, args) => address.Text = (string)args.SelectedItem;
    address.QuerySubmitted += async (_, args) => { address.IsSuggestionListOpen = false; await RunForAsync(tab, "navigate", args.ChosenSuggestion as string ?? args.QueryText); };
    address.KeyDown += (_, args) => { if (args.Key == VirtualKey.Escape) { address.Text = tab.Address; address.IsSuggestionListOpen = false; args.Handled = true; } };
  }
  private void InstallHistoryMenu(BrowserTab tab, Button button, bool forward)
  {
    var menu = new MenuFlyout(); button.ContextFlyout = menu;
    menu.Opening += async (_, _) =>
    {
      menu.Items.Clear();
      await GuardAsync(async () =>
      {
        var result = await tab.Model.CommandAsync("Page.getNavigationHistory", new { });
        var index = result.GetProperty("currentIndex").GetInt32();
        var entries = result.GetProperty("entries").EnumerateArray().Select(e => e.Clone()).ToArray();
        var visits = forward ? entries.Skip(index + 1) : entries.Take(index).Reverse();
        foreach (var visit in visits)
        {
          var entry = visit.GetProperty("id").GetInt32();
          var title = visit.GetProperty("title").GetString();
          menu.Items.Add(MenuAction(string.IsNullOrEmpty(title) ? visit.GetProperty("url").GetString()! : title, tab,
            async () => { await tab.Model.CommandAsync("Page.navigateToHistoryEntry", new { entryId = entry }); }));
        }
      }, tab);
    };
  }
  private MenuFlyout ProfileMenu(BrowserTab tab)
  {
    var menu = new MenuFlyout();
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear();
      foreach (var profile in Core.Read().Profiles)
      {
        var item = new ToggleMenuFlyoutItem { Text = profile.Name, IsChecked = profile.Id == tab.Profile.Id, FontSize = 13, MinHeight = 28 };
        item.Click += async (_, _) => await GuardAsync(() => SwitchStoreAsync(tab, profile.Id, tab.Isolated), tab);
        menu.Items.Add(item);
      }
      menu.Items.Add(MenuAction("Manage profiles…", tab, OpenProfileSettingsAsync));
      menu.Items.Add(new MenuFlyoutSeparator());
      menu.Items.Add(MenuAction("New Tab", tab, () => OpenAfterAsync(tab, false)));
      menu.Items.Add(MenuAction("New Isolated Tab", tab, () => OpenAfterAsync(tab, true)));
      menu.Items.Add(MenuAction("Open in Your Browser", tab, async () => { await Launcher.LaunchUriAsync(new Uri(tab.Address)); }, tab.Address.Length > 0));
      menu.Items.Add(MenuAction("Copy Address", tab, () => { CopyText(tab.Address); SetTabStatus(tab, "Address copied."); return Task.CompletedTask; }, tab.Address.Length > 0));
      menu.Items.Add(new MenuFlyoutSeparator());
      menu.Items.Add(MenuAction("Zoom Out", tab, () => SetZoomAsync(tab, tab.Zoom / 1.1)));
      menu.Items.Add(MenuAction($"Actual Size · {tab.Zoom:P0}", tab, () => SetZoomAsync(tab, 1)));
      menu.Items.Add(MenuAction("Zoom In", tab, () => SetZoomAsync(tab, tab.Zoom * 1.1)));
      menu.Items.Add(MenuAction("Find in Page", tab, () => { tab.FindShown = true; RefreshShellViews(); return Task.CompletedTask; }));
      menu.Items.Add(MenuAction("Print…", tab, () => { tab.View.CoreWebView2.ShowPrintUI(Microsoft.Web.WebView2.Core.CoreWebView2PrintDialogKind.Browser); return Task.CompletedTask; }));
      menu.Items.Add(MenuAction("History", tab, () => ShowHistoryAsync(tab), !tab.Isolated));
      menu.Items.Add(MenuAction("Recorded flow", tab, () => { tab.StepsShown = true; RefreshShellViews(); return Task.CompletedTask; }));
    };
    return menu;
  }
  private async Task OpenAfterAsync(BrowserTab tab, bool isolated)
  {
    await Core.SelectAsync(tab.Id);
    var made = await Core.OpenAsync(StartAddress, isolated, tab.Profile.Id, Core.Get(tab.Id).SessionId);
    SyncCore(); ObserveShellPages(); ShellSelected?.Invoke(made.Id);
  }
  private string StartAddress => Core.Read().StartUrl == "about:blank" ? "https://start.deck.invalid/index.html" : Core.Read().StartUrl;
  private async Task SwitchStoreAsync(BrowserTab tab, string profileId, bool isolated)
  {
    if (tab.Profile.Id == profileId && tab.Isolated == isolated) return;
    try { await Core.ChangeStoreAsync(tab.Id, profileId, isolated); }
    finally { SyncCore(); ObserveShellPages(); RefreshShellViews(); ShellChanged?.Invoke(); ShellSelected?.Invoke(tab.Id); }
  }
  private readonly Dictionary<string, (Grid Panel, BrowserTab Tab)> replacingViews = [];
  private void StageReplacement(BrowserTab tab)
  {
    if (Core.Read().Tabs.Any(t => t.Id == tab.Id) && shellViews.TryGetValue(tab.Id, out var panel)) replacingViews[tab.Id] = (panel, tab);
  }
  private async Task RebindRetainedPageAsync(BrowserTab current)
  {
    if (!replacingViews.Remove(current.Id, out var previous)) return;
    var tab = previous.Tab;
    current.FlowDraft = tab.FlowDraft; current.ShotDraft = tab.ShotDraft; current.AnnotationDraft = tab.AnnotationDraft;
    current.Steps.AddRange(tab.Steps); current.StepsShown = tab.StepsShown; current.Annotations.AddRange(tab.Annotations); current.NextAnnotation = tab.NextAnnotation; current.SelectedAnnotation = tab.SelectedAnnotation;
    foreach (var mark in tab.Drawing.Marks) current.Drawing.Add(mark);
    current.DrawingImage = tab.DrawingImage; current.CapturePath = tab.CapturePath; current.Viewport = tab.Viewport; current.PhoneAgent = tab.PhoneAgent;
    var replacement = (Grid)ShellView(current.Id); var retained = previous.Panel;
    retained.Children.Clear();
    foreach (var child in replacement.Children.ToArray()) { replacement.Children.Remove(child); retained.Children.Add(child); }
    retained.KeyboardAccelerators.Clear();
    foreach (var shortcut in replacement.KeyboardAccelerators.ToArray()) { replacement.KeyboardAccelerators.Remove(shortcut); retained.KeyboardAccelerators.Add(shortcut); }
    shellViews[current.Id] = retained;
    await ApplyViewportAsync(current); await SetZoomAsync(current, tab.Zoom);
  }
  private async Task SetZoomAsync(BrowserTab tab, double factor)
  {
    tab.Zoom = Math.Clamp(factor, 0.25, 5);
    await tab.Model.CommandAsync("Emulation.setPageScaleFactor", new { pageScaleFactor = tab.Zoom }); RefreshShellViews();
  }
  private async Task ShowHistoryAsync(BrowserTab tab)
  {
    if (tab.Isolated) { SetTabStatus(tab, "Isolated tabs do not save browsing history."); return; }
    var content = new StackPanel { Spacing = 12, MinWidth = 400 };
    var search = new TextBox { PlaceholderText = "Search history" }; content.Children.Add(search);
    var rows = new StackPanel { Spacing = 8 };
    content.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 420 });
    var confirm = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
    var confirmation = new TextBlock { TextWrapping = TextWrapping.Wrap }; confirm.Children.Add(confirmation);
    var clear = TextAction("Clear", () => { confirmation.Text = search.Text.Length == 0 ? "Clear this profile’s browsing history?" : "Clear the history matching this search?"; confirm.Visibility = Visibility.Visible; });
    content.Children.Add(clear); content.Children.Add(confirm);
    var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "History · " + tab.Profile.Name, Content = content, CloseButtonText = "Done" };
    void Render()
    {
      rows.Children.Clear(); var visits = Core.History(tab.Profile.Id, search.Text); clear.IsEnabled = visits.Length > 0;
      if (visits.Length == 0) rows.Children.Add(new TextBlock { Text = search.Text.Length == 0 ? "No history yet" : "No matching history" });
      foreach (var day in visits.GroupBy(v => v.At.LocalDateTime.Date))
      {
        rows.Children.Add(new TextBlock { Text = day.Key.ToString("D"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        foreach (var visit in day)
        {
          var row = new StackPanel { Spacing = 4 };
          var open = TextAction($"{visit.At.LocalDateTime:t} · {(visit.Title.Length > 0 ? visit.Title : visit.Url)}", async () => { dialog.Hide(); await RunForAsync(tab, "navigate", visit.Url); });
          ToolTipService.SetToolTip(open, visit.Url); row.Children.Add(open);
          row.Children.Add(TextAction("Forget", async () => await GuardAsync(async () => { await Core.ForgetHistoryAsync(tab.Profile.Id, visit.Id); Render(); }, tab)));
          rows.Children.Add(row);
        }
      }
    }
    confirm.Children.Add(TextAction("Clear history", async () => await GuardAsync(async () => { await Core.ForgetHistoryAsync(tab.Profile.Id, query: search.Text); confirm.Visibility = Visibility.Collapsed; Render(); }, tab)));
    confirm.Children.Add(TextAction("Cancel", () => confirm.Visibility = Visibility.Collapsed));
    search.TextChanged += (_, _) => { confirm.Visibility = Visibility.Collapsed; Render(); }; Render(); BrowserDialogForProof = dialog;
    try { await dialog.ShowAsync(); } finally { BrowserDialogForProof = null; }
  }
  private async Task FindAsync(BrowserTab tab, bool backwards = false)
  {
    if (tab.FindText.Length == 0) { tab.FindResult = ""; RefreshShellViews(); return; }
    var result = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.find(" + JsonSerializer.Serialize(tab.FindText) + ",false," + (backwards ? "true" : "false") + ",true)", returnByValue = true });
    tab.FindResult = result.GetProperty("result").GetProperty("value").GetBoolean() ? "" : "Not found"; RefreshShellViews();
  }
}
