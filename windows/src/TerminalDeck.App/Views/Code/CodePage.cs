using Microsoft.UI.Xaml;
using TerminalDeck.App.Shell;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Code;

namespace TerminalDeck.App.Views.Code;

// What the Files, Source control and GitHub pages need from the shell.
public interface ICodePageHost
{
  IReadOnlyList<CodeRoot> Roots();
  (string? ProjectId, string? Folder) Current();
  UIElement Picture(CodeRoot root, double size);
  Task OpenTerminalAsync(CodeRoot root, string folder);
  Task OpenInBrowserAsync(string url);
  void Notice(string message);
}

internal static class CodeUi
{
  public static FontFamily Mono => TerminalDeck.App.Views.DeckFonts.Mono;
  public static StackPanel Stack(double gap = 8) => new() { Spacing = gap, HorizontalAlignment = HorizontalAlignment.Stretch };
  public static TextBlock Words(string text, double size = 13, bool muted = false, bool wrap = true) => new()
  { Text = text, FontSize = size, Opacity = muted ? 0.68 : 1, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
  public static Style Canvas() => (Style)XamlReader.Load("""
    <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Grid"><Setter Property="Background" Value="{ThemeResource DeckCanvasBrush}" /></Style>
    """);
  public static Border Card(UIElement child, double padding = 16) => new() { Child = child, Padding = new Thickness(padding), Style = (Style)Application.Current.Resources["SurfaceCardStyle"] };
  public static DeckIcon Icon(string glyph, double size = 14) => new() { Glyph = glyph, FontSize = size, VerticalAlignment = VerticalAlignment.Center };
  public static Button Action(string title, Func<Task> clicked, bool primary = false, string? glyph = null)
  {
    var button = new Button { MinHeight = 28, Padding = new Thickness(10, 4, 10, 4) };
    if (glyph is null) button.Content = title;
    else { var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 }; row.Children.Add(Icon(glyph)); row.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center }); button.Content = row; }
    if (primary) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
    AutomationProperties.SetName(button, title);
    button.Click += async (_, _) =>
    {
      button.IsEnabled = false;
      try { await clicked(); }
      catch (OperationCanceledException) { }
      finally { button.IsEnabled = true; }
    };
    return button;
  }
  public static Button IconAction(string glyph, string name, Func<Task> clicked)
  {
    var button = Action(name, clicked); button.Content = Icon(glyph);
    button.MinWidth = 28; button.Width = 28; button.Height = 28; button.MinHeight = 28; button.Padding = new Thickness(0);
    button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); button.BorderThickness = new Thickness(0);
    ToolTipService.SetToolTip(button, name); return button;
  }
  // The side panel's own row style: same hover, pressed and selected look.
  public static ToggleButton Row(UIElement content, string name, bool selected)
  {
    var row = new ToggleButton { Content = content, IsChecked = selected, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, MinHeight = 30, Padding = new Thickness(6, 3, 6, 3) };
    if (Application.Current.Resources.TryGetValue("DeckNavigationButtonStyle", out var style) && style is Style navigation) row.Style = navigation;
    AutomationProperties.SetName(row, name); ToolTipService.SetToolTip(row, name); return row;
  }
  public static Grid Columns(params (UIElement Child, GridLength Width)[] cells)
  {
    var grid = new Grid { ColumnSpacing = 8 };
    for (var i = 0; i < cells.Length; i++) { grid.ColumnDefinitions.Add(new ColumnDefinition { Width = cells[i].Width }); Grid.SetColumn((FrameworkElement)cells[i].Child, i); grid.Children.Add(cells[i].Child); }
    return grid;
  }
  public static GridLength Star => new(1, GridUnitType.Star);
  public static GridLength Auto => GridLength.Auto;
  public static void Copy(string text)
  {
    var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(text);
    Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
  }
  public static void Reveal(string path)
  {
    var info = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = true };
    info.ArgumentList.Add(Directory.Exists(path) && !File.Exists(path) ? path : "/select," + path);
    System.Diagnostics.Process.Start(info);
  }
  public static async Task OpenWithDefaultAppAsync(string path)
  {
    var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
    if (!await Windows.System.Launcher.LaunchFileAsync(file)) throw new InvalidOperationException("Windows could not open this file.");
  }
  public static InfoBar Problem(string message, InfoBarSeverity severity = InfoBarSeverity.Error) => new() { IsOpen = true, IsClosable = true, Message = message, Severity = severity };
  public static SolidColorBrush Brush(byte r, byte g, byte b, byte a = 255) => new(Windows.UI.Color.FromArgb(a, r, g, b));
}

// The multi-project frame the three pages share: every open project (and every
// Independent session's folder) as its own collapsible group with its picture,
// and a quick switcher on top that follows the current session by default.
public abstract class CodePage : Grid
{
  protected readonly ICodePageHost Host;
  private readonly string title;
  private readonly ComboBox switcher = new() { MinWidth = 160, MaxWidth = 280, MinHeight = 28 };
  // A folder path reads in the code font; with no folder the line is the page title in the interface font.
  private void ShowScope(string? folder)
  {
    if (folder is null)
    {
      scope.ClearValue(TextBlock.FontFamilyProperty); scope.FontSize = 20; scope.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
      scope.Opacity = 1; scope.Text = title; ToolTipService.SetToolTip(scope, null);
    }
    else
    {
      scope.FontFamily = TerminalDeck.App.Views.DeckFonts.Mono; scope.FontSize = 11.5; scope.FontWeight = Microsoft.UI.Text.FontWeights.Normal;
      scope.Opacity = 0.7; scope.Text = folder + " · on this PC"; ToolTipService.SetToolTip(scope, folder);
    }
  }
  private readonly TextBlock scope = new() { FontSize = 11.5, FontFamily = TerminalDeck.App.Views.DeckFonts.Mono, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
  private readonly StackPanel groups = CodeUi.Stack(6);
  private readonly ScrollViewer groupScroll;
  private readonly Dictionary<string, bool> expanded = [];
  private readonly Dictionary<string, FrameworkElement> groupViews = [];
  private readonly Dictionary<string, Border> summaries = [];
  protected readonly Border Detail = new() { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
  protected readonly StackPanel Toolbar = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
  protected readonly StackPanel Messages = CodeUi.Stack(4);
  private string? pinnedKey;
  private bool updatingSwitcher;
  protected IReadOnlyList<CodeRoot> RootList { get; private set; } = [];
  protected CodeRoot? Active { get; private set; }

  private sealed record Choice(string? Key, string Name)
  {
    public override string ToString() => Name;
  }

  protected CodePage(ICodePageHost host, string title, double listWidth = 280)
  {
    Host = host; this.title = title; Style = CodeUi.Canvas();
    RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
    AutomationProperties.SetName(switcher, "Project"); ToolTipService.SetToolTip(switcher, "Choose a project, or follow the current session");
    switcher.SelectionChanged += (_, _) =>
    {
      if (updatingSwitcher || switcher.SelectedItem is not Choice choice) return;
      pinnedKey = choice.Key; Rebuild(focusActive: true);
    };
    var refresh = CodeUi.IconAction("", "Refresh", async () => { await RefreshAllAsync(); });
    scope.SetResourceReference(TextBlock.ForegroundProperty, "DeckInkBrush"); ShowScope(null);
    var tools = new ScrollViewer { Content = Toolbar, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled, MaxWidth = 460 };
    var top = CodeUi.Columns((scope, CodeUi.Star), (switcher, CodeUi.Auto), (tools, CodeUi.Auto), (refresh, CodeUi.Auto));
    top.RowDefinitions.Add(new() { Height = GridLength.Auto }); top.RowDefinitions.Add(new() { Height = GridLength.Auto });
    top.MinHeight = 52; top.Padding = new Thickness(24, 10, 24, 10); top.ColumnSpacing = 8;
    top.SizeChanged += (_, _) =>
    {
      var compact = top.ActualWidth < 780;
      Grid.SetRow(tools, compact ? 1 : 0); Grid.SetColumn(tools, compact ? 0 : 2); Grid.SetColumnSpan(tools, compact ? 4 : 1);
      tools.Margin = new Thickness(0, compact ? 8 : 0, 0, 0);
      tools.MaxWidth = Math.Max(0, compact ? top.ActualWidth - 48 : 460);
    };
    Children.Add(top);
    Messages.Margin = new Thickness(24, 0, 24, 6); SetRow(Messages, 1); Children.Add(Messages);
    groups.Padding = new Thickness(12, 0, 12, 16);
    groupScroll = new ScrollViewer { Content = groups, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    var body = new Grid { ColumnSpacing = 0 };
    body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(listWidth), MinWidth = 240 }); body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
    body.Children.Add(groupScroll);
    var divider = new Border { Width = 1, Opacity = 0.12, Background = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] }; SetColumn(divider, 1); body.Children.Add(divider);
    Detail.Padding = new Thickness(24, 20, 24, 16); SetColumn(Detail, 2); body.Children.Add(Detail);
    SetRow(body, 2); Children.Add(body);
    Loaded += async (_, _) => { Rebuild(focusActive: false); await OnShownAsync(); };
  }

  public void EmbedInProject()
  {
    // The owning Project page supplies identity and project selection. Preserve
    // the actual search/actions/refresh row instead of duplicating that chrome.
    if (Children.FirstOrDefault() is Grid top)
    {
      foreach (var child in top.Children.OfType<FrameworkElement>().Where(c => GetColumn(c) < 2)) child.Visibility = Visibility.Collapsed;
      top.ColumnDefinitions[0].Width = new(0); top.ColumnDefinitions[1].Width = new(0); top.ColumnSpacing = 0;
      top.MinHeight = 0; top.Padding = new(0, 4, 0, 8);
    }
  }
  public string PageTitle => title;
  // Re-read the roots and follow the current session unless a project was picked.
  public void Rebuild(bool focusActive)
  {
    RootList = Host.Roots();
    var (projectId, folder) = Host.Current();
    var following = CodeWorkspace.Current(RootList, projectId, folder);
    Active = pinnedKey is not null ? RootList.FirstOrDefault(r => r.Key == pinnedKey) ?? following : following;
    ShowScope(Active?.Folder);
    updatingSwitcher = true;
    try
    {
      var choices = new List<Choice> { new(null, following is null ? "Follow current session" : "Follow current session · " + following.Name) };
      choices.AddRange(RootList.Select(r => new Choice(r.Key, r.Name + (r.Independent ? " (no project)" : ""))));
      switcher.ItemsSource = choices; switcher.SelectedItem = choices.FirstOrDefault(c => c.Key == pinnedKey) ?? choices[0];
    }
    finally { updatingSwitcher = false; }
    foreach (var root in RootList) if (!expanded.ContainsKey(root.Key)) expanded[root.Key] = root.Key == Active?.Key;
    if (Active is not null && focusActive) expanded[Active.Key] = true;
    groups.Children.Clear(); groupViews.Clear(); summaries.Clear();
    if (RootList.Count == 0)
    {
      groups.Children.Add(CodeUi.Card(CodeUi.Words("No open projects yet. Open a project or start a session in a folder, and it shows up here.", muted: true)));
      Detail.Child = null; return;
    }
    foreach (var root in RootList) { var view = Group(root); groupViews[root.Key] = view; groups.Children.Add(view); }
    ShowDetail();
    if (focusActive && Active is not null && groupViews.TryGetValue(Active.Key, out var target))
      DispatcherQueue.TryEnqueue(() => target.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 0 }));
  }
  protected void MakeActive(CodeRoot root)
  {
    if (Active?.Key == root.Key) return;
    Active = root; ShowScope(root.Folder); OnActiveChanged(); ShowDetail();
    foreach (var (key, view) in groupViews) if (view is Grid g && g.Children.Count > 0 && g.Children[0] is ToggleButton head) head.IsChecked = key == root.Key;
  }
  private FrameworkElement Group(CodeRoot root)
  {
    var open = expanded[root.Key];
    var shell = new Grid { RowSpacing = 2 };
    shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
    var chevron = CodeUi.Icon(open ? "" : "", 10);
    var picture = Host.Picture(root, 18);
    var name = CodeUi.Words(root.Name, 13, wrap: false); name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    var summary = new Border { Child = GroupSummary(root), VerticalAlignment = VerticalAlignment.Center }; summaries[root.Key] = summary;
    var headContent = CodeUi.Columns((chevron, CodeUi.Auto), (picture, CodeUi.Auto), (name, CodeUi.Star), (summary, CodeUi.Auto));
    var head = CodeUi.Row(headContent, (open ? "Collapse " : "Expand ") + root.Name, root.Key == Active?.Key);
    ToolTipService.SetToolTip(head, root.Folder);
    var content = CodeUi.Stack(1); content.Margin = new Thickness(18, 0, 0, 6); content.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
    head.Click += (_, _) =>
    {
      var now = !expanded[root.Key]; expanded[root.Key] = now;
      chevron.Glyph = now ? "" : ""; content.Visibility = now ? Visibility.Visible : Visibility.Collapsed;
      AutomationProperties.SetName(head, (now ? "Collapse " : "Expand ") + root.Name);
      MakeActive(root); head.IsChecked = true;
      if (now && content.Children.Count == 0) _ = FillGroupAsync(root, content);
    };
    head.ContextFlyout = GroupMenu(root);
    shell.Children.Add(head); SetRow(content, 1); shell.Children.Add(content);
    if (open) _ = FillGroupAsync(root, content);
    return shell;
  }
  private MenuFlyout GroupMenu(CodeRoot root)
  {
    var menu = new MenuFlyout();
    void Add(string text, Func<Task> run) { var item = new MenuFlyoutItem { Text = text, FontSize = 13, MinHeight = 28 }; item.Click += async (_, _) => await GuardAsync(run); menu.Items.Add(item); }
    Add("Show in Explorer", () => { CodeUi.Reveal(root.Folder); return Task.CompletedTask; });
    Add("Copy folder path", () => { CodeUi.Copy(root.Folder); return Task.CompletedTask; });
    Add("Open a terminal here", () => Host.OpenTerminalAsync(root, root.Folder));
    return menu;
  }
  protected async Task FillGroupAsync(CodeRoot root, StackPanel content)
  {
    content.Children.Clear();
    content.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3, Margin = new Thickness(0, 6, 8, 6) });
    try { await FillAsync(root, content); }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { content.Children.Clear(); content.Children.Add(CodeUi.Words(Plain(ex), 12, true)); }
  }
  protected void RefillGroup(CodeRoot root)
  {
    if (groupViews.TryGetValue(root.Key, out var view) && view is Grid g && g.Children.Count > 1 && g.Children[1] is StackPanel content && content.Visibility == Visibility.Visible)
      _ = FillGroupAsync(root, content);
  }
  protected static string Plain(Exception ex) => ex switch
  {
    GitHubException gh => GitHubRules.Explanation(gh.Failure),
    GitCommandException or ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException => ex.Message,
    _ => "That could not finish. Try again."
  };
  protected async Task GuardAsync(Func<Task> run)
  {
    try { await run(); }
    catch (OperationCanceledException) { }
    catch (Exception ex) when (ex is not OutOfMemoryException) { ShowProblem(Plain(ex)); }
  }
  protected void ShowProblem(string message, InfoBarSeverity severity = InfoBarSeverity.Error)
  {
    Messages.Children.Clear(); Messages.Children.Add(CodeUi.Problem(message, severity));
  }
  protected void ClearProblem() => Messages.Children.Clear();
  protected void UpdateSummary(CodeRoot root) { if (summaries.TryGetValue(root.Key, out var holder)) holder.Child = GroupSummary(root); }
  public async Task RefreshAllAsync() { ClearProblem(); Rebuild(focusActive: false); await OnShownAsync(); }

  protected abstract Task FillAsync(CodeRoot root, StackPanel content);
  protected virtual UIElement GroupSummary(CodeRoot root) => new TextBlock();
  protected abstract void ShowDetail();
  protected virtual Task OnShownAsync() => Task.CompletedTask;
  protected virtual void OnActiveChanged() { }
}
