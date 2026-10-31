using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Code;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TerminalDeck.App.Views.Code;

// Files (Ctrl+Shift+E): every open project's tree, search, preview, reveal,
// copy path, a terminal here, and drag a file into a chat or terminal.
public sealed class FilesPage : CodePage
{
  private readonly ProjectFiles files;
  private readonly Dictionary<string, FileTreeState> trees = [];
  private readonly Dictionary<string, IReadOnlyList<FileMatch>?> searches = [];
  private readonly Dictionary<string, StackPanel> contents = [];
  private readonly Dictionary<string, string?> readmes = [];
  private readonly HashSet<string> opened = [];
  private readonly AutoSuggestBox search = new() { PlaceholderText = "Search files by name", MinWidth = 220, QueryIcon = new SymbolIcon(Symbol.Find) };
  private readonly CheckBox showIgnored = new() { Content = "Show ignored", MinWidth = 0 };
  private (CodeRoot Root, string RelPath)? selected;
  private FileRead? read;
  private string? readError;
  private bool reading;

  public FilesPage(ICodePageHost host, ProjectFiles files) : base(host, "Files")
  {
    this.files = files;
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(search, "Search files by name");
    ToolTipService.SetToolTip(showIgnored, "Show files your .gitignore excludes");
    search.QuerySubmitted += async (_, args) => await SearchAsync(args.QueryText);
    search.TextChanged += async (_, args) => { if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput && search.Text.Length == 0) await SearchAsync(""); };
    showIgnored.Checked += async (_, _) => await ReloadTreesAsync(); showIgnored.Unchecked += async (_, _) => await ReloadTreesAsync();
    Toolbar.Children.Add(search); Toolbar.Children.Add(showIgnored);
    KeyDown += OnKeyDown;
  }

  private FileTreeState Tree(CodeRoot root) => trees.TryGetValue(root.Key, out var tree) ? tree : trees[root.Key] = new FileTreeState();
  private async Task ReloadTreesAsync()
  {
    foreach (var tree in trees.Values) tree.Reset();
    foreach (var (key, content) in contents) if (RootList.FirstOrDefault(r => r.Key == key) is { } root && content.Visibility == Visibility.Visible) await FillGroupAsync(root, content);
  }
  private async Task SearchAsync(string query)
  {
    if (Active is null) return;
    searches[Active.Key] = query.Trim().Length == 0 ? null : await files.SearchAsync(Active.Folder, query, showIgnored.IsChecked == true);
    RefillGroup(Active);
  }

  protected override async Task FillAsync(CodeRoot root, StackPanel content)
  {
    contents[root.Key] = content;
    var tree = Tree(root);
    if (searches.GetValueOrDefault(root.Key) is { } matches)
    {
      content.Children.Clear();
      if (matches.Count == 0) content.Children.Add(CodeUi.Words("No file names match.", 12, true));
      foreach (var match in matches) content.Children.Add(FileRow(root, new FsEntry(match.Name, match.RelPath, false), 0, match.RelPath));
      return;
    }
    if (!tree.Children.ContainsKey(FileTreeState.Root)) await LoadAsync(root, FileTreeState.Root);
    Render(root, content);
    // Open the folder's README once per project, only when nothing is open.
    if (selected is null && Active?.Key == root.Key && readmes.GetValueOrDefault(root.Key) is { } readme && opened.Add(root.Key)) await OpenAsync(root, readme);
  }
  private async Task LoadAsync(CodeRoot root, string dir)
  {
    var tree = Tree(root); tree.LoadStarted(dir);
    try
    {
      var listing = await files.ListAsync(root.Folder, dir, showIgnored.IsChecked == true);
      tree.Loaded(dir, listing); if (dir == FileTreeState.Root) readmes[root.Key] = listing.DefaultFile;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { tree.Failed(dir, ex.Message); }
  }
  private void Render(CodeRoot root, StackPanel content)
  {
    var tree = Tree(root); content.Children.Clear();
    var state = tree.RootState;
    if (state.Kind == TreeRootKind.Error) { content.Children.Add(CodeUi.Words("Could not read this folder — " + state.Message, 12, true)); return; }
    if (state.Kind == TreeRootKind.Empty) { content.Children.Add(CodeUi.Words(FilesRules.BlankReason(root.FolderName, showIgnored.IsChecked == true), 12, true)); return; }
    foreach (var row in tree.Rows)
    {
      content.Children.Add(FileRow(root, row.Entry, row.Depth, row.Entry.Name));
      if (tree.Errors.TryGetValue(row.Entry.RelPath, out var error)) content.Children.Add(Indented(CodeUi.Words(error, 11, true), row.Depth + 1));
      if (row.Entry.IsDir && tree.Truncated.Contains(row.Entry.RelPath) && tree.Expanded.Contains(row.Entry.RelPath)) content.Children.Add(Indented(CodeUi.Words(FilesRules.TruncatedLine, 11, true), row.Depth + 1));
    }
    if (tree.Truncated.Contains(FileTreeState.Root)) content.Children.Add(CodeUi.Words(FilesRules.TruncatedLine, 11, true));
  }
  private static FrameworkElement Indented(FrameworkElement child, int depth) { child.Margin = new Thickness(depth * 14 + 22, 0, 0, 0); return child; }

  private FrameworkElement FileRow(CodeRoot root, FsEntry entry, int depth, string label)
  {
    var tree = Tree(root);
    var glyph = entry.IsDir ? (tree.Expanded.Contains(entry.RelPath) ? "" : "") : "";
    var icon = CodeUi.Icon(glyph, 13); if (entry.Ignored || entry.Blocked) icon.Opacity = 0.5;
    var text = CodeUi.Words(label, 13, wrap: false); if (entry.Ignored) text.Opacity = 0.6;
    var tail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    if (entry.Symlink) tail.Children.Add(CodeUi.Words("link", 11, true));
    if (entry.Ignored) tail.Children.Add(CodeUi.Words("Ignored", 11, true));
    var cells = CodeUi.Columns((icon, CodeUi.Auto), (text, CodeUi.Star), (tail, CodeUi.Auto));
    cells.Margin = new Thickness(depth * 14, 0, 0, 0);
    var isSelected = selected is { } s && s.Root.Key == root.Key && s.RelPath == entry.RelPath;
    var row = CodeUi.Row(cells, FilesRules.RowTitle(entry), isSelected || (Active?.Key == root.Key && tree.Focused == entry.RelPath));
    row.Click += async (_, _) => await GuardAsync(() => ActivateAsync(root, entry));
    row.ContextFlyout = RowMenu(root, entry);
    // Drag a file into a chat or terminal: both accept dropped files.
    row.CanDrag = !entry.Blocked;
    row.DragStarting += async (_, args) =>
    {
      var deferral = args.GetDeferral();
      try
      {
        var full = ProjectFiles.Resolve(root.Folder, entry.RelPath);
        Windows.Storage.IStorageItem item = entry.IsDir ? await Windows.Storage.StorageFolder.GetFolderFromPathAsync(full) : await Windows.Storage.StorageFile.GetFileFromPathAsync(full);
        args.Data.SetStorageItems([item]); args.Data.SetText(full); args.Data.RequestedOperation = DataPackageOperation.Copy;
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { args.Cancel = true; }
      finally { deferral.Complete(); }
    };
    return row;
  }
  private MenuFlyout RowMenu(CodeRoot root, FsEntry entry)
  {
    var menu = new MenuFlyout();
    void Add(string text, Func<Task> run, bool enabled = true) { var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled }; item.Click += async (_, _) => await GuardAsync(run); menu.Items.Add(item); }
    string Full() => ProjectFiles.Resolve(root.Folder, entry.RelPath);
    if (!entry.IsDir) Add("Open preview", () => OpenAsync(root, entry.RelPath), !entry.Blocked);
    if (!entry.IsDir) Add("Open with default app", () => CodeUi.OpenWithDefaultAppAsync(Full()), !entry.Blocked);
    Add("Show in Explorer", () => { CodeUi.Reveal(Full()); return Task.CompletedTask; });
    menu.Items.Add(new MenuFlyoutSeparator());
    Add("Copy path", () => { CodeUi.Copy(Full()); Host.Notice("Path copied."); return Task.CompletedTask; });
    Add("Copy relative path", () => { CodeUi.Copy(entry.RelPath); Host.Notice("Relative path copied."); return Task.CompletedTask; });
    menu.Items.Add(new MenuFlyoutSeparator());
    Add("Open a terminal here", () => Host.OpenTerminalAsync(root, entry.IsDir ? Full() : Path.GetDirectoryName(Full()) ?? root.Folder), !entry.Blocked);
    return menu;
  }
  private async Task ActivateAsync(CodeRoot root, FsEntry entry)
  {
    MakeActive(root);
    var tree = Tree(root); tree.Focused = entry.RelPath;
    if (entry.IsDir)
    {
      switch (tree.ToggleFor(entry))
      {
        case FileTreeState.Toggle.Collapse: tree.Collapse(entry.RelPath); break;
        case FileTreeState.Toggle.Expand: tree.Expand(entry.RelPath); break;
        case FileTreeState.Toggle.Load: await LoadAsync(root, entry.RelPath); break;
      }
      if (contents.TryGetValue(root.Key, out var content)) Render(root, content);
      return;
    }
    if (!entry.Blocked) await OpenAsync(root, entry.RelPath);
  }
  private async Task OpenAsync(CodeRoot root, string relPath)
  {
    selected = (root, relPath); read = null; readError = null; reading = true; ShowDetail();
    try { read = await files.ReadAsync(root.Folder, relPath); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { readError = ex.Message; }
    finally { reading = false; }
    if (selected is { } now && now.Root.Key == root.Key && now.RelPath == relPath) ShowDetail();
    if (contents.TryGetValue(root.Key, out var content) && searches.GetValueOrDefault(root.Key) is null) Render(root, content);
  }
  private async void OnKeyDown(object sender, KeyRoutedEventArgs e)
  {
    if (Active is null || e.OriginalSource is TextBox || searches.GetValueOrDefault(Active.Key) is not null) return;
    FileTreeState.Key? key = e.Key switch
    {
      VirtualKey.Down => FileTreeState.Key.Down, VirtualKey.Up => FileTreeState.Key.Up, VirtualKey.Right => FileTreeState.Key.Right, VirtualKey.Left => FileTreeState.Key.Left,
      VirtualKey.Home => FileTreeState.Key.Home, VirtualKey.End => FileTreeState.Key.End, VirtualKey.Enter => FileTreeState.Key.Activate, _ => null
    };
    if (key is null) return;
    e.Handled = true;
    var root = Active; var tree = Tree(root); var effect = tree.Effect(key.Value);
    switch (effect.Kind)
    {
      case FileTreeState.EffectKind.Focus: tree.Focused = effect.RelPath; break;
      case FileTreeState.EffectKind.Collapse: tree.Collapse(effect.RelPath!); break;
      case FileTreeState.EffectKind.Toggle: await GuardAsync(() => ActivateAsync(root, effect.Entry!)); return;
      case FileTreeState.EffectKind.Activate: await GuardAsync(() => ActivateAsync(root, effect.Entry!)); return;
      default: return;
    }
    if (contents.TryGetValue(root.Key, out var content)) Render(root, content);
  }

  protected override UIElement GroupSummary(CodeRoot root) => CodeUi.Words(root.Independent ? "folder" : "", 11, true);

  protected override void ShowDetail()
  {
    if (selected is not { } current || Active is null || current.Root.Key != Active.Key)
    {
      Detail.Child = Active is null ? null : CodeUi.Card(CodeUi.Words("Choose a file in " + Active.Name + " to preview it here.", muted: true));
      return;
    }
    var full = ProjectFiles.Resolve(current.Root.Folder, current.RelPath);
    var panel = new Grid { RowSpacing = 8 };
    panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
    var name = CodeUi.Words(FilesRules.Name(current.RelPath), 15, wrap: false); name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    var where = CodeUi.Words(current.Root.Name + " · " + current.RelPath, 12, true, wrap: false);
    var titles = CodeUi.Stack(0); titles.Children.Add(name); titles.Children.Add(where);
    var document = read is { Kind: FileReadKind.Text } text ? FilesRules.Document(text.Text) : default;
    var meta = CodeUi.Words(FilesRules.ViewerMeta(read is { Kind: FileReadKind.Text } ? document.Count : null, read), 12, true, wrap: false);
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
    actions.Children.Add(CodeUi.IconAction("", "Open with default app", () => CodeUi.OpenWithDefaultAppAsync(full)));
    actions.Children.Add(CodeUi.IconAction("", "Show in Explorer", () => { CodeUi.Reveal(full); return Task.CompletedTask; }));
    actions.Children.Add(CodeUi.IconAction("", "Copy path", () => { CodeUi.Copy(full); Host.Notice("Path copied."); return Task.CompletedTask; }));
    actions.Children.Add(CodeUi.IconAction("", "Open a terminal here", () => Host.OpenTerminalAsync(current.Root, Path.GetDirectoryName(full) ?? current.Root.Folder)));
    panel.Children.Add(CodeUi.Columns((titles, CodeUi.Star), (meta, CodeUi.Auto), (actions, CodeUi.Auto)));
    UIElement body;
    if (reading) body = new ProgressBar { IsIndeterminate = true, Height = 3, VerticalAlignment = VerticalAlignment.Top };
    else if (readError is not null) body = CodeUi.Words(FilesRules.ErrorLine(readError), muted: true);
    else if (read is { Kind: FileReadKind.Binary }) body = CodeUi.Words(FilesRules.BinaryLine(read.Bytes), muted: true);
    else if (read is { Kind: FileReadKind.TooLarge }) body = CodeUi.Words(FilesRules.TooLargeLine(read.Bytes, read.Limit), muted: true);
    else if (read is { Kind: FileReadKind.Text })
    {
      var gutter = new TextBlock { Text = FilesRules.Gutter(document.Shown), FontFamily = CodeUi.Mono, FontSize = 12, Opacity = 0.45, TextAlignment = TextAlignment.Right, Margin = new Thickness(0, 0, 12, 0) };
      var source = new TextBlock { Text = document.Source, FontFamily = CodeUi.Mono, FontSize = 12, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.NoWrap };
      var lines = CodeUi.Columns((gutter, CodeUi.Auto), (source, CodeUi.Star)); lines.ColumnSpacing = 0;
      var stack = CodeUi.Stack(6); stack.Children.Add(lines);
      if (document.Shown < document.Count) stack.Children.Add(CodeUi.Words(FilesRules.ShownLine(document.Shown, document.Count), 12, true));
      body = new ScrollViewer { Content = stack, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
    else body = new TextBlock();
    var frame = CodeUi.Card(body, 12); frame.VerticalAlignment = VerticalAlignment.Stretch;
    SetRow(frame, 1); panel.Children.Add(frame);
    Detail.Child = panel;
  }
}
