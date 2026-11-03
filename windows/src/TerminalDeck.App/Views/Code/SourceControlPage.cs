using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Code;

namespace TerminalDeck.App.Views.Code;

// Source control (Ctrl+Shift+G): each open project's changes through the
// system git — diff, stage/unstage, commit, branches, fetch/pull/push, history.
public sealed class SourceControlPage : CodePage
{
  private readonly GitClient git;
  private readonly Dictionary<string, GitStatusResult> statuses = [];
  private readonly Dictionary<string, string> drafts = [];
  private (string RootKey, GitFile File)? selected;
  private GitDiffResult? diff;
  private string? diffError;
  private bool history;
  private IReadOnlyList<GitCommitInfo>? commits;
  private IReadOnlyList<GitBranchRef>? branches;
  private string? busy;

  public SourceControlPage(ICodePageHost host, GitClient git) : base(host, "Source control", 380) { this.git = git; }

  // Every project's branch and change count shows on its header, even collapsed.
  protected override async Task OnShownAsync()
  {
    foreach (var root in RootList.ToArray())
      try { statuses[root.Key] = await git.StatusAsync(root.Folder); UpdateSummary(root); }
      catch (Exception ex) when (ex is ArgumentException or IOException) { }
    if (Active is not null) await LoadActiveExtrasAsync();
  }
  protected override void OnActiveChanged() { branches = null; commits = null; _ = LoadActiveExtrasAsync(); }
  private async Task LoadActiveExtrasAsync()
  {
    if (Active is null || statuses.GetValueOrDefault(Active.Key)?.Repo is null) { branches = null; commits = null; ShowDetail(); return; }
    var root = Active;
    try
    {
      var list = await git.BranchesAsync(root.Folder);
      var log = history ? await git.LogAsync(root.Folder) : null;
      if (Active?.Key != root.Key) return;
      branches = list; commits = log;
    }
    catch (GitCommandException ex) { ShowProblem(ex.Message); }
    ShowDetail();
  }

  protected override UIElement GroupSummary(CodeRoot root)
  {
    var repo = statuses.GetValueOrDefault(root.Key)?.Repo;
    if (repo is null) return new TextBlock();
    var parts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
    parts.Children.Add(CodeUi.Words(repo.Branch.Label, 11, true, wrap: false));
    if (repo.Branch.Ahead > 0) { var up = CodeUi.Words("↑" + repo.Branch.Ahead, 11, true); ToolTipService.SetToolTip(up, repo.Branch.Ahead + " commit(s) to push"); parts.Children.Add(up); }
    if (repo.Branch.Behind > 0) { var down = CodeUi.Words("↓" + repo.Branch.Behind, 11, true); ToolTipService.SetToolTip(down, repo.Branch.Behind + " commit(s) to pull"); parts.Children.Add(down); }
    if (repo.ChangeCount > 0) parts.Children.Add(Badge(repo.ChangeCount.ToString(System.Globalization.CultureInfo.InvariantCulture)));
    return parts;
  }
  private static Border Badge(string text) => new()
  {
    Child = new TextBlock { Text = text, FontSize = 11 }, Padding = new Thickness(6, 0, 6, 1), CornerRadius = new CornerRadius(8),
    Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"], VerticalAlignment = VerticalAlignment.Center
  };

  protected override async Task FillAsync(CodeRoot root, StackPanel content)
  {
    var status = await git.StatusAsync(root.Folder);
    statuses[root.Key] = status; UpdateSummary(root);
    content.Children.Clear();
    if (status.Repo is not { } repo)
    {
      var view = GitRules.Unavailable(status);
      var title = CodeUi.Words(view.Title, 13); title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
      content.Children.Add(title); content.Children.Add(CodeUi.Words(view.Message, 12, true));
      if (view.CanInit) content.Children.Add(CodeUi.Action("Create a repository", async () => { await GuardAsync(async () => { await git.InitAsync(root.Folder); await RefreshRootAsync(root); }); }));
      if (status.Reason == GitUnavailableReason.GitMissing) content.Children.Add(CodeUi.Action("Get Git for Windows", () => Host.OpenInBrowserAsync("https://git-scm.com/download/win")));
      return;
    }
    if (repo.Clean) { content.Children.Add(CodeUi.Words("No changes. Everything is committed on " + repo.Branch.Label + ".", 12, true)); }
    foreach (var group in GitRules.Groups(repo))
    {
      var label = CodeUi.Words(group.Label.ToUpperInvariant(), 11, true, wrap: false); label.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
      var count = Badge(group.Files.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));
      var paths = group.Files.Select(f => f.Path).ToArray();
      UIElement bulk = group.Key == GitFileGroup.Staged
        ? CodeUi.IconAction("", "Unstage all", () => ChangeAsync(root, () => git.UnstageAsync(root.Folder, paths)))
        : CodeUi.IconAction("", "Stage all " + group.Label.ToLowerInvariant(), () => ChangeAsync(root, () => git.StageAsync(root.Folder, paths)));
      var header = CodeUi.Columns((label, CodeUi.Star), (count, CodeUi.Auto), (bulk, CodeUi.Auto)); header.Margin = new Thickness(0, 6, 0, 0);
      content.Children.Add(header);
      foreach (var file in group.Files.Take(GitRules.MaxRowsPerGroup)) content.Children.Add(FileRow(root, file, group.Key));
      if (group.Files.Count > GitRules.MaxRowsPerGroup) content.Children.Add(CodeUi.Words(group.Files.Count - GitRules.MaxRowsPerGroup + " more not shown", 11, true));
    }
    if (Active?.Key == root.Key && selected is null && GitRules.FirstChoice(GitRules.Groups(repo)) is { } first)
    {
      var file = GitRules.Groups(repo).SelectMany(g => g.Files).First(f => f.Path == first);
      await SelectAsync(root, file);
    }
    if (Active?.Key == root.Key) await LoadActiveExtrasAsync();
  }
  private FrameworkElement FileRow(CodeRoot root, GitFile file, GitFileGroup group)
  {
    var name = CodeUi.Words(GitRules.BaseName(file.Path), 13, wrap: false);
    var detail = CodeUi.Words(GitRules.RowDetail(file), 11, true, wrap: false);
    var names = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 }; names.Children.Add(name); names.Children.Add(detail);
    var counts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    if (file.Binary) counts.Children.Add(CodeUi.Words("bin", 11, true));
    if (file.Insertions is > 0) { var add = CodeUi.Words("+" + file.Insertions, 11); add.Foreground = CodeUi.Brush(0x2E, 0xA0, 0x43); counts.Children.Add(add); }
    if (file.Deletions is > 0) { var del = CodeUi.Words("−" + file.Deletions, 11); del.Foreground = CodeUi.Brush(0xD1, 0x24, 0x2F); counts.Children.Add(del); }
    var kind = CodeUi.Words(GitRules.ChangeLabel(file.Kind, file.Code)[..1], 11, true);
    ToolTipService.SetToolTip(kind, GitRules.ChangeLabel(file.Kind, file.Code));
    UIElement toggle = group == GitFileGroup.Staged
      ? CodeUi.IconAction("", "Unstage " + file.Path, () => ChangeAsync(root, () => git.UnstageAsync(root.Folder, [file.Path])))
      : CodeUi.IconAction("", "Stage " + file.Path, () => ChangeAsync(root, () => git.StageAsync(root.Folder, [file.Path])));
    var cells = CodeUi.Columns((names, CodeUi.Star), (counts, CodeUi.Auto), (kind, CodeUi.Auto), (toggle, CodeUi.Auto));
    var isSelected = selected is { } s && s.RootKey == root.Key && s.File.Id == file.Id;
    var row = CodeUi.Row(cells, GitRules.RowTitle(file), isSelected);
    row.Click += async (_, _) => { history = false; MakeActive(root); await SelectAsync(root, file); };
    var menu = new MenuFlyout();
    void Add(string text, Func<Task> run) { var item = new MenuFlyoutItem { Text = text }; item.Click += async (_, _) => await GuardAsync(run); menu.Items.Add(item); }
    var full = Path.Combine(statuses[root.Key].Repo!.Root, file.Path.Replace('/', Path.DirectorySeparatorChar));
    Add("Show in Explorer", () => { CodeUi.Reveal(full); return Task.CompletedTask; });
    Add("Copy path", () => { CodeUi.Copy(full); Host.Notice("Path copied."); return Task.CompletedTask; });
    Add("Open with default app", () => CodeUi.OpenWithDefaultAppAsync(full));
    row.ContextFlyout = menu;
    return row;
  }
  private async Task ChangeAsync(CodeRoot root, Func<Task> change)
  {
    await GuardAsync(async () => { ClearProblem(); await change(); await RefreshRootAsync(root); });
  }
  private async Task RefreshRootAsync(CodeRoot root)
  {
    selected = selected is { } s && s.RootKey == root.Key ? null : selected; diff = null;
    Rebuild(focusActive: false);
    await Task.CompletedTask;
  }
  private async Task SelectAsync(CodeRoot root, GitFile file)
  {
    selected = (root.Key, file); diff = null; diffError = null; ShowDetail();
    if (GitRules.NoDiffReason(file) is not null) return;
    try { diff = await git.DiffAsync(root.Folder, file.Path, file.Group); }
    catch (Exception ex) when (ex is GitCommandException or ArgumentException) { diffError = ex.Message; }
    if (selected is { } now && now.File.Id == file.Id) ShowDetail();
  }

  protected override void ShowDetail()
  {
    if (Active is null) { Detail.Child = null; return; }
    var root = Active;
    var repo = statuses.GetValueOrDefault(root.Key)?.Repo;
    var panel = new Grid { RowSpacing = 10 };
    panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
    if (repo is null)
    {
      Detail.Child = CodeUi.Card(CodeUi.Words(statuses.ContainsKey(root.Key) ? GitRules.Unavailable(statuses[root.Key]).Message : "Reading " + root.Name + "…", muted: true)); return;
    }
    panel.Children.Add(BranchBar(root, repo));
    var commitBox = CommitBox(root, repo); SetRow(commitBox, 1); panel.Children.Add(commitBox);
    var view = history ? HistoryView() : DiffView(root);
    SetRow(view, 2); panel.Children.Add(view);
    Detail.Child = panel;
  }
  private FrameworkElement BranchBar(CodeRoot root, GitRepoStatus repo)
  {
    var picture = Host.Picture(root, 20);
    var name = CodeUi.Words(root.Name, 15, wrap: false); name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    var branch = new ComboBox { MinWidth = 180, PlaceholderText = repo.Branch.Label };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(branch, "Branch"); ToolTipService.SetToolTip(branch, "Switch branch");
    var locals = branches?.Where(b => !b.Remote).Select(b => b.Name).ToList() ?? (repo.Branch.Name is { } current ? [current] : []);
    branch.ItemsSource = locals; branch.SelectedItem = locals.FirstOrDefault(b => b == repo.Branch.Name);
    branch.SelectionChanged += async (_, _) =>
    {
      if (branch.SelectedItem is string target && target != repo.Branch.Name) await RunAsync(root, "Switching to " + target + "…", () => git.SwitchAsync(root.Folder, target, false));
    };
    var create = CodeUi.IconAction("", "New branch…", () => NewBranchAsync(root));
    var fetch = CodeUi.Action("Fetch", () => RunAsync(root, "Fetching…", () => git.FetchAsync(root.Folder)), glyph: "");
    var pull = CodeUi.Action(repo.Branch.Behind > 0 ? "Pull ↓" + repo.Branch.Behind : "Pull", () => RunAsync(root, "Pulling…", () => git.PullAsync(root.Folder)), glyph: "");
    var push = CodeUi.Action(repo.Branch.Ahead > 0 ? "Push ↑" + repo.Branch.Ahead : "Push", () => RunAsync(root, "Pushing…", () => git.PushAsync(root.Folder)), glyph: "");
    var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
    var changes = CodeUi.Row(CodeUi.Words("Changes", 12), "Changes", !history); changes.Click += (_, _) => { history = false; ShowDetail(); };
    var log = CodeUi.Row(CodeUi.Words("History", 12), "History", history); log.Click += async (_, _) => { history = true; ShowDetail(); await LoadActiveExtrasAsync(); };
    tabs.Children.Add(changes); tabs.Children.Add(log);
    var status = CodeUi.Words(busy ?? (repo.Branch.Upstream is { } up ? "Tracking " + up : "Not linked to a remote branch"), 11, true, wrap: false);
    var top = CodeUi.Columns((picture, CodeUi.Auto), (name, CodeUi.Auto), (branch, CodeUi.Auto), (create, CodeUi.Auto), (status, CodeUi.Star), (fetch, CodeUi.Auto), (pull, CodeUi.Auto), (push, CodeUi.Auto));
    var stack = CodeUi.Stack(6); stack.Children.Add(top); stack.Children.Add(tabs);
    return stack;
  }
  private FrameworkElement CommitBox(CodeRoot root, GitRepoStatus repo)
  {
    var message = new TextBox { PlaceholderText = repo.Staged.Count == 0 ? "Stage changes, then write a commit message" : "Commit message (Ctrl+Enter to commit)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 56, MaxHeight = 140, Text = drafts.GetValueOrDefault(root.Key) ?? "" };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(message, "Commit message");
    message.TextChanged += (_, _) => drafts[root.Key] = message.Text;
    async Task Commit()
    {
      await RunAsync(root, "Committing…", async () => { var id = await git.CommitAsync(root.Folder, message.Text); drafts.Remove(root.Key); Host.Notice("Committed " + id + "."); });
    }
    var commit = CodeUi.Action(repo.Staged.Count == 0 ? "Commit" : "Commit " + repo.Staged.Count + (repo.Staged.Count == 1 ? " file" : " files"), Commit, primary: true, glyph: "");
    commit.IsEnabled = repo.Staged.Count > 0; commit.VerticalAlignment = VerticalAlignment.Bottom;
    var enter = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Enter, Modifiers = Windows.System.VirtualKeyModifiers.Control, ScopeOwner = message };
    enter.Invoked += async (_, args) => { args.Handled = true; if (repo.Staged.Count > 0) await Commit(); };
    message.KeyboardAccelerators.Add(enter);
    return CodeUi.Columns((message, CodeUi.Star), (commit, CodeUi.Auto));
  }
  private FrameworkElement DiffView(CodeRoot root)
  {
    if (selected is not { } current || current.RootKey != root.Key) return CodeUi.Card(CodeUi.Words("Choose a changed file to see what changed.", muted: true));
    var file = current.File;
    var head = CodeUi.Stack(0);
    var title = CodeUi.Words(GitRules.Describe(file), 14, wrap: false); title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    head.Children.Add(title); head.Children.Add(CodeUi.Words(GitRules.DiffMeta(file, file.Group), 12, true));
    var stack = CodeUi.Stack(6); stack.Children.Add(head);
    if (GitRules.NoDiffReason(file) is { } reason) stack.Children.Add(CodeUi.Words(reason, 12, true));
    else if (diffError is not null) { stack.Children.Add(CodeUi.Words(diffError, 12, true)); stack.Children.Add(CodeUi.Action("Try again", () => SelectAsync(root, file))); }
    else if (diff is null) stack.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 });
    else if (diff.Note is not null) stack.Children.Add(CodeUi.Words(diff.Note, 12, true));
    else
    {
      var lines = new StackPanel();
      foreach (var line in diff.Lines.Where(l => l.Kind != GitDiffLineKind.Meta))
      {
        (string prefix, SolidColorBrush? background, double opacity) = line.Kind switch
        {
          GitDiffLineKind.Add => ("+", CodeUi.Brush(0x2E, 0xA0, 0x43, 0x30), 1.0), GitDiffLineKind.Del => ("−", CodeUi.Brush(0xD1, 0x24, 0x2F, 0x30), 1.0),
          GitDiffLineKind.Hunk => ("", CodeUi.Brush(0x80, 0x80, 0x80, 0x20), 0.7), _ => (" ", null, 0.85)
        };
        var text = new TextBlock { Text = prefix + " " + line.Text, FontFamily = CodeUi.Mono, FontSize = 12, Opacity = opacity, TextWrapping = TextWrapping.NoWrap, IsTextSelectionEnabled = true };
        lines.Children.Add(new Border { Child = text, Background = background, Padding = new Thickness(6, 0, 6, 0) });
      }
      if (diff.Hidden > 0) lines.Children.Add(CodeUi.Words(GitRules.MoreLines(diff.Hidden), 12, true));
      stack.Children.Add(new ScrollViewer { Content = lines, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
    if (file.Group != GitFileGroup.Staged) actions.Children.Add(CodeUi.Action("Stage", () => ChangeAsync(root, () => git.StageAsync(root.Folder, [file.Path])), glyph: ""));
    else actions.Children.Add(CodeUi.Action("Unstage", () => ChangeAsync(root, () => git.UnstageAsync(root.Folder, [file.Path])), glyph: ""));
    stack.Children.Insert(1, actions);
    var card = CodeUi.Card(stack, 12); card.VerticalAlignment = VerticalAlignment.Stretch; return card;
  }
  private FrameworkElement HistoryView()
  {
    var list = CodeUi.Stack(2);
    if (commits is null) list.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 });
    else if (commits.Count == 0) list.Children.Add(CodeUi.Words("No commits yet.", 12, true));
    else foreach (var commit in commits)
      {
        var oid = new TextBlock { Text = commit.Short, FontFamily = CodeUi.Mono, FontSize = 12, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
        var subject = CodeUi.Words(commit.Subject, 13, wrap: false);
        var who = CodeUi.Words(commit.Author + " · " + GitHubRules.FormatAge(commit.When, DateTimeOffset.UtcNow), 11, true, wrap: false);
        var row = CodeUi.Row(CodeUi.Columns((oid, CodeUi.Auto), (subject, CodeUi.Star), (who, CodeUi.Auto)), commit.Subject, false);
        var menu = new MenuFlyout(); var copy = new MenuFlyoutItem { Text = "Copy commit id" }; copy.Click += (_, _) => { CodeUi.Copy(commit.Oid); Host.Notice("Commit id copied."); }; menu.Items.Add(copy);
        row.ContextFlyout = menu; row.Click += (_, _) => row.IsChecked = false;
        list.Children.Add(row);
      }
    var card = CodeUi.Card(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 12); card.VerticalAlignment = VerticalAlignment.Stretch; return card;
  }
  private async Task RunAsync(CodeRoot root, string doing, Func<Task> action)
  {
    busy = doing; ShowDetail(); ClearProblem();
    try { await action(); }
    catch (Exception ex) when (ex is GitCommandException or ArgumentException or InvalidOperationException or IOException) { ShowProblem(ex.Message); }
    finally { busy = null; }
    await RefreshRootAsync(root);
  }
  private async Task NewBranchAsync(CodeRoot root)
  {
    var name = new TextBox { PlaceholderText = "feature/my-change", Header = "Branch name" };
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "New branch in " + root.Name, Content = name, PrimaryButtonText = "Create and switch", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    await RunAsync(root, "Creating " + name.Text.Trim() + "…", () => git.SwitchAsync(root.Folder, name.Text, true));
  }
}
